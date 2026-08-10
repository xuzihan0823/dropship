# Dropship Agent 协议契约 v1

本文件是 **Go agent** 与 **Swift 客户端** 之间的唯一接口约定。
两侧独立实现，任何一侧偏离本文件都视为 bug。修改本文件必须同步通知两侧负责人。

---

## 0. 设计前提（来自真机实测，勿推翻）

在目标网络环境实测（Mac ↔ 腾讯云上海）：

| 指标 | 实测值 | 设计含义 |
|---|---|---|
| 上行带宽 | 2.27 MB/s | **上传是瓶颈**，秒传/续传/压缩优先级高于一切 |
| 下行带宽 | 6.22 MB/s | 下载压力较小 |
| gzip 压缩收益（文本） | 约 2.7 倍 | 对可压缩内容默认开压缩 |
| SSH stdio 管道 | **二进制安全**（10MB 随机字节 MD5 一致） | 数据通道走裸二进制，**禁止 base64** |

## 1. 总体形态

agent 是一个**无守护进程、不监听端口**的单文件二进制。
客户端通过系统 `ssh` 启动它，用标准输入输出通信：

```
Mac 客户端 ──/usr/bin/ssh──> ~/.local/share/dropship/agent <模式参数>
                              stdin/stdout = 数据与命令通道
                              stderr       = 进度与日志通道
```

鉴权完全由 SSH 承担，agent 自身**不做任何鉴权**，也不得实现任何网络监听。

### 为什么不用单一长连接做多路复用

每个任务开独立 ssh 会话，底层 TCP 由 SSH 的 `ControlMaster` 复用。
这样避免自己实现多路复用，且**单个传输失败不影响其他任务**。协议因此可以极简。

## 2. 三种运行模式

### 2.1 控制模式 `agent --stdio`

处理元数据操作。协议为 **NDJSON**（每行一个 JSON 对象，`\n` 分隔，UTF-8）。
长期驻留，直到 stdin 关闭。

请求：
```json
{"id":"<客户端生成的唯一串>","op":"<操作名>","args":{...}}
```

成功响应：
```json
{"id":"<原样回传>","ok":true,"data":{...}}
```

失败响应：
```json
{"id":"<原样回传>","ok":false,"error":{"code":"<机器码>","message":"<人类可读>"}}
```

**要求**：请求可乱序到达，响应必须带回对应 `id`；agent 应能并发处理，不得因单个慢操作阻塞后续请求。

#### 操作清单

| op | args | data 返回 |
|---|---|---|
| `hello` | `{}` | `{"version":"1.0.0","protocol":1,"arch":"amd64","os":"linux","home":"/root"}` |
| `list` | `{"path":"/root","showHidden":false}` | `{"entries":[Entry...]}` |
| `stat` | `{"path":"/root/a.txt"}` | `{"entry":Entry}` |
| `mkdir` | `{"path":"/root/新目录","parents":true}` | `{}` |
| `remove` | `{"path":"/root/x","recursive":false}` | `{}` |
| `move` | `{"from":"/a","to":"/b"}` | `{}` |
| `chmod` | `{"path":"/a","mode":"0644"}` | `{}` |
| `hash` | `{"path":"/a","algo":"blake3"}` | `{"hash":"<hex>","size":12345}` |
| `space` | `{"path":"/root"}` | `{"totalBytes":N,"freeBytes":N}` |
| `realpath` | `{"path":"~/x"}` | `{"path":"/root/x"}` |

`Entry` 结构（字段名严格一致）：
```json
{
  "name": "a.txt",
  "path": "/root/a.txt",
  "isDir": false,
  "isSymlink": false,
  "symlinkTarget": "",
  "size": 12345,
  "mode": "0644",
  "modTime": 1786360000,
  "owner": "root",
  "group": "root"
}
```

`modTime` 为 Unix 秒。`list` 不递归。符号链接**不自动跟随**，`isDir` 反映链接本身。

### 2.2 接收模式 `agent --recv`（上传：Mac → 服务器）

```
agent --recv --path <目标绝对路径> [--offset N] [--compress gzip] [--expect-size N] [--expect-hash <hex>]
```

行为：
1. 从 **stdin 读取裸二进制**（若 `--compress gzip` 则先解压）
2. 写入 `<目标路径>.dropship-part` 临时文件；`--offset N` 表示从第 N 字节续写
3. stdin 正常结束后，若给了 `--expect-hash` 则校验，通过后**原子 rename** 为目标路径
4. 校验失败：保留 `.part` 文件，以非零码退出，stderr 输出错误 JSON

**要求**：必须先写临时文件再 rename。**禁止**直接写目标路径——传输中断会毁掉服务器上的原文件。

### 2.3 发送模式 `agent --send`（下载：服务器 → Mac）

```
agent --send --path <源绝对路径> [--offset N] [--compress gzip]
```

从 `--offset` 开始把文件内容写到 **stdout 裸二进制**（`--compress gzip` 则压缩后输出）。

## 3. 进度上报（stderr 通道）

数据模式下，agent 每 **200ms 或每 1MB**（先到者）向 **stderr** 写一行 JSON：

```json
{"type":"progress","bytes":1048576,"total":52428800}
```

结束时写一行：
```json
{"type":"done","bytes":52428800,"hash":"<hex>","durationMs":23000}
```

出错时写一行：
```json
{"type":"error","code":"ENOSPC","message":"设备空间不足"}
```

**要求**：stdout **只能**有文件数据，任何日志/进度混入 stdout 都会损坏文件。这是最容易犯且后果最严重的错误。

## 4. 错误码

客户端依据 `code` 决定重试或提示，必须使用下列稳定值：

| code | 含义 | 客户端行为 |
|---|---|---|
| `ENOENT` | 路径不存在 | 提示，不重试 |
| `EACCES` | 权限不足 | 提示，不重试 |
| `EEXIST` | 已存在 | 询问覆盖 |
| `ENOSPC` | 空间不足 | 提示，不重试 |
| `EISDIR` / `ENOTDIR` | 类型不符 | 提示，不重试 |
| `EHASH` | 哈希校验失败 | 自动重传一次 |
| `EPROTO` | 协议错误 | 报 bug |
| `EINTERNAL` | 内部错误 | 附日志 |

## 5. 部署约定

| 项 | 值 |
|---|---|
| 安装路径 | `$HOME/.local/share/dropship/agent` |
| 权限 | `0755` |
| 版本探测 | `agent --version` → stdout 输出 `dropship-agent <semver>` 后退出 0 |

**必须装在用户目录，禁止 `/usr/local/bin`。** 目标服务器中已确认存在非 root 账号
（`aliyun02` 为 `ankangxu`），装系统目录会要求 sudo，直接导致连接失败。

支持架构：`linux/amd64`、`linux/arm64`。客户端通过 `uname -m` 探测后上传对应二进制。

## 6. 对 agent 的硬性要求

1. **零外部依赖**：静态编译，`CGO_ENABLED=0`，不依赖目标机 glibc 版本
2. **体积**：单架构 strip 后 < 8MB（`-ldflags="-s -w"`）
3. **内存**：传输 10GB 文件时常驻内存不得超过 32MB（**必须流式处理，禁止整个文件读入内存**）
4. **不写日志文件**：不得在服务器上产生任何日志或临时残留（`.part` 文件除外）
5. **信号处理**：收到 SIGTERM/SIGPIPE 时干净退出，保留 `.part` 以便续传
6. **哈希算法**：blake3（比 sha256 快数倍，上行受限场景下不应让 CPU 成为新瓶颈）
