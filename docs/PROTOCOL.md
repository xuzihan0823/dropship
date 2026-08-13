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
| `hello` | `{}` | `{"version":"1.0.1","protocol":1,"arch":"amd64","os":"linux","home":"/root"}` |
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
agent --recv --path <目标绝对路径> --expect-size N [--offset N] [--compress gzip] [--expect-hash <hex>]
```

行为：
1. 从 **stdin 读取裸二进制**（若 `--compress gzip` 则先解压）
2. 写入 `<目标路径>.dropship-part` 临时文件；`--offset N` 表示从第 N 字节续写
3. stdin 结束后**必须校验实际写入字节数是否等于 `--expect-size`**，不等则判定为传输被截断
4. 字节数校验通过后，若给了 `--expect-hash` 则再校验哈希
5. 全部校验通过才**原子 rename** 为目标路径
6. 任一校验失败：**保留 `.part` 文件，不得 rename**，以非零码退出，stderr 输出错误 JSON

**`--expect-size` 是必需参数。** 未提供时 agent 必须以 `EPROTO` 拒绝执行，不得默认放行。

> **为什么强制**：真机实测确认，SSH 断线会让 stdin 提前 EOF，agent 无法区分"正常传完"和"被截断"。
> 实测中一个 2.5MB 的半截文件成功覆盖了服务器上的原文件，agent 报告 `done` 且退出码为 0。
> 文件大小在客户端是零成本已知的，因此强制传入，由 agent 做最后一道防线。

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
| `ESIZE` | 收到字节数与 `--expect-size` 不符（传输被截断） | 自动续传重试 |
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

---

## 7. 反向收件隧道（服务器 → Mac 主动推送）

第 1–6 节描述的都是 **Mac 发起**的通路。本节是反过来的那条：让服务器上的进程
（尤其是跑在服务器上的 AI agent）主动把文件推回 Mac。

Go agent **不参与**这条通路，本节不对 agent 提任何要求。

### 7.1 为什么要有隧道

Mac 在 NAT 后面，没有公网地址，服务器无法主动连进来。因此通路仍然由 Mac 发起：

```
Mac: Dropship.app 内置收件端点 (127.0.0.1:<localPort>，仅回环)
      ▲
      │ ssh -N -R 0:127.0.0.1:<localPort>     ← 由 Mac 发起并常驻
      │
服务器: 127.0.0.1:<remotePort>  ←── curl ←── 服务器上的 agent
```

`remotePort` 由服务器的 sshd 动态分配，ssh 客户端从 stderr 的
`Allocated port <N> for remote forward` 中解析。**每次重连都可能变**，所以
客户端每次隧道建立成功都会重写一遍服务器上的 `inbox.env`。

`ssh -R` 默认只在服务器的回环地址绑定（`GatewayPorts no`），公网碰不到这个端口。

### 7.2 服务器端的两个文件

隧道开启时由 Mac 写入，关闭时删除。目录与 agent 相同：

| 路径 | 权限 | 内容 |
|---|---|---|
| `$HOME/.local/share/dropship/inbox.env` | `0600` | `DROPSHIP_INBOX_URL` + `DROPSHIP_INBOX_TOKEN` |
| `$HOME/.local/share/dropship/dropship-send` | `0755` | curl 包装脚本 |

于是服务器上的调用方只需要一行：

```sh
~/.local/share/dropship/dropship-send ./build/report.pdf
~/.local/share/dropship/dropship-send ./logs/          # 目录自动打包成 logs.tar.gz
```

脚本不存在即表示隧道没开，它会直接报错退出，不会静默失败。

### 7.3 收件端点契约

```
PUT /upload HTTP/1.1
Authorization: Bearer <token>
X-Dropship-Name: <base64(UTF-8 文件名)>
Content-Length: <N>

<裸二进制，N 字节>
```

| 项 | 约定 |
|---|---|
| 方法 | 只接受 `PUT` / `POST`，其余 405 |
| 鉴权 | `Authorization: Bearer <token>`，定长时间比对，失败 401。**每台服务器一把 token**，token 即身份 |
| 文件名 | 优先 `X-Dropship-Name`（base64，避开空格与中文在请求行里被切断）；缺失时退回请求路径的最后一段 |
| 长度 | **必须**带 `Content-Length`。`Transfer-Encoding: chunked` 一律 411 —— 目录请先打包成文件再传 |
| `Expect: 100-continue` | 服务端会先回 `HTTP/1.1 100 Continue`。curl 对 >1KB 的 PUT body 默认发这个头，不回它每次白等 1 秒 |
| 连接 | 不支持 keep-alive，响应后即关闭 |

成功：
```json
{"ok":true,"name":"report.pdf","bytes":52428800}
```

失败：
```json
{"ok":false,"code":"ESIZE","message":"..."}
```

### 7.4 落地规则

Mac 默认收件目录为 `~/Downloads/Dropship`。用户可以在 App 的「收件箱」分页选择其他
本机文件夹，路径与隧道开关一起持久化在 `tunnels.json`；切换时，已开启的隧道会自动
重建并改用新目录。调用方也可以在构造 `TunnelService` 时显式传入 `inboxDirectory`。

1. 流式写入 `<收件箱>/.incoming/<uuid>.part`，全程不整文件进内存
2. 收到的字节数**必须**等于 `Content-Length`，不等即判定截断
3. 校验通过才**原子 rename** 进收件箱；不通过则**保留 `.part`、绝不 rename**
4. 文件名一律压成单段裸名：先百分号解码，再取最后一段，再清掉残留分隔符。
   `PUT /../../../../etc/passwd` 只会落成收件箱里的 `passwd`
5. 同名不覆盖，自动 `name-1.ext`
6. 未完成的 `.part` 保留 7 天，之后在下次启动时清理
7. 收件目录在 Finder 中被删除后，下一次上传会先自动重建目录与 `.incoming`

> 第 2、3 条与 2.2 节 `--recv` 的规矩是同一条：那次半截文件覆盖掉服务器原文件的
> 事故，根因就是"没校验字节数就 rename"。收件方向必须守同样的底线。

### 7.5 错误码

复用第 4 节的稳定值，HTTP 状态码只是外壳：

| HTTP | code | 含义 |
|---|---|---|
| 401 | `EACCES` | token 无效，或隧道已关闭 |
| 405 / 411 / 431 | `EPROTO` | 方法、长度声明或请求头不合约定 |
| 413 | `EPROTO` | 超过单文件上限（8 GiB） |
| 400 | `ESIZE` | 收到字节数与 `Content-Length` 不符，已保留 `.part` |
| 507 | `ENOSPC` | Mac 磁盘空间不足 |
| 500 | `EINTERNAL` | 写盘或落地失败 |

### 7.6 安全边界（明确写下来，不要事后惊讶）

- 收件端点**只绑 127.0.0.1**，不经过任何真实网卡，因此也不会触发 macOS 应用防火墙弹窗
- 服务器上**不存放任何能登录 Mac 的凭据**。拿到 token 的人只能**写**，且只能写进收件箱那一个目录，读不到 Mac 上的任何东西，也拿不到执行权限
- 反过来说：服务器上任何能读 `inbox.env` 的用户（含 root）都能往你的收件箱塞文件。这是本方案的已知边界
- 关闭开关会同时作废 token、杀掉 ssh 进程、删掉服务器上的两个文件，三重失效
