# Dropship · 开发进度

Mac 与服务器之间的拖拽式文件互传工具。macOS 原生 SwiftUI 应用。

**项目位置**：`~/Desktop/dropship`

---

## 当前状态

**阶段**：v0.2 并行开发中
**最后更新**：2026-08-10

## 已完成（主控）

### 地基验证（全部实测通过）

| 验证项 | 结果 |
|---|---|
| SPM → `.app` bundle → GUI 启动 | ✅ 通过，全程无 Xcode 项目文件 |
| SSH stdio 二进制安全性 | ✅ 10MB 随机字节往返 MD5 一致，可用裸二进制协议 |
| 服务器连通性 | tencent-dev ✅ / aliyun02 ✅ / tokyo-server ❌ 连接被拒 |
| **拖出 Finder（承诺式拖拽）** | ✅ **纯 SwiftUI 可实现，无需 NSFilePromiseProvider** |

#### 拖出 Finder 验证详情（原最高风险项，已解除）

原本担心"拖拽开始时文件还在服务器上"必须下探到 AppKit 的 `NSFilePromiseProvider`。
实测证明 SwiftUI 的 `Transferable` + 异步 `FileRepresentation` 已经支持延迟供给：

```
20:45:07  ▶ 导出回调触发    ← 用户松手瞬间系统才回调
20:45:09  ✔ 下载完成交付    ← 延迟 2 秒模拟网络下载
结果：文件落到 Finder 目标目录，5200 字节，中文文件名完好
```

关键写法：`FileRepresentation(exportedContentType:)` 的 exporting 闭包内 `await` 真实下载，
完成后返回 `SentTransferredFile(url)`。闭包是 static 上下文，需单例中转定位下载服务。

验证代码保留在 `/tmp/dragtest`（临时，非项目文件）。

#### agent 部署链路验证（两台真机通过）

```sh
ssh <host> 'mkdir -p ~/.local/share/dropship'
ssh <host> 'cat > ~/.local/share/dropship/agent' < <本地二进制>
ssh <host> 'chmod 0755 ~/.local/share/dropship/agent'
ssh <host> '~/.local/share/dropship/agent --version'
```

| 服务器 | 账号 | 结果 |
|---|---|---|
| aliyun02 | ankangxu（非 root） | ✅ `/home/ankangxu/.local/share/dropship` 755 可执行 |
| tencent-dev | root | ✅ `/root/.local/share/dropship/agent` 755 可执行 |

两台文件系统均为 ext4 `rw,relatime`，**无 `noexec` 限制**。测试残留已清理。

## 质量记录

### Go agent 真机验证通过（2026-08-10）

1001 行，`go build` + `go vet` 零警告。二进制静态链接、stripped，amd64 2.5M / arm64 2.4M。

补做了 agent 未覆盖的一环：**交叉编译产物在真实 Linux 上运行**（其自测全部在 macOS/darwin）。

在 tencent-dev（root/x86_64）实测：

| 项 | 结果 |
|---|---|
| 部署 + `--version` | ✅ dropship-agent 1.0.0 |
| `hello` | ✅ arch=amd64, os=linux, protocol=1 |
| `list` / `space` | ✅ 5 项正确、39.3GB/27.6GB |
| 上传 `--recv` | ✅ MD5 与本地一致 |
| 下载 `--send` | ✅ MD5 与本地一致 |
| gzip 压缩往返 | ✅ MD5 一致 |
| blake3 | ✅ 上下行 hash 吻合，秒传基础可用 |

响应乱序返回但 `id` 正确对应，并发处理生效。

### 🔴 重大缺陷发现：传输截断会静默摧毁服务器原文件

agent 负责人在报告中主动提出疑虑，实测确认**风险成立且后果严重**。

构造场景：服务器上放一个重要文件，传输中途关闭 stdin（模拟 SSH 断线）。

```
原文件 MD5:        905237b6...（重要数据）
截断传输后:
  agent stderr:    {"type":"done","bytes":2621440,...}
  退出码:           0
  目标文件 MD5:     5a301564...  ← 原文件被 2.5MB 半截数据覆盖
```

**原文件丢失，agent 报告成功，客户端认定上传完成。**

根因：SSH 断线使 stdin 提前 EOF，agent 无法区分"正常传完"与"被截断"。

**已修改协议**（`docs/PROTOCOL.md` 2.2 节 / 第 4 节）：

1. `--expect-size` 由可选改为**必需**，未提供时 agent 须以 `EPROTO` 拒绝执行
2. stdin 结束后必须先校验字节数，不符即判定截断
3. 校验失败保留 `.part`、**不得 rename**、非零码退出
4. 新增错误码 `ESIZE`，客户端应对方式为自动续传重试

文件大小在客户端零成本已知，强制传入由 agent 做最后防线。

### Core 层第一版退回返工（2026-08-10）

第一版产出 359 行，报告声称完成但实际含致命缺陷，已要求返工：

| 问题 | 后果 |
|---|---|
| `TransferQueue.run()` 中 `if direction == .upload` 无 `else` 分支 | **下载什么都不做却标记 `.completed`**，UI 显示成功而磁盘无文件 |
| 上传传入 `ServerConfig(hostname:"", username:"")` | 连不上任何服务器，上传必然失败 |
| `Bootstrapper` 无上传逻辑，仅探测 | agent 永远不部署，Go agent 那条线产出作废 |
| `AgentTransport.connect()` 等 `--stdio` 退出 | stdio 会阻塞等 stdin，直接挂死 |
| `control()` 每次新起进程且不读响应 | 违背长驻控制会话设计，错误无法感知 |
| `list`/`stat`/`hash` 未实现 | 秒传不可能工作 |
| `retry(id)` 忽略传入 id | 重试会重试错任务 |

保留 `SSHProcess.swift`（ControlMaster、取消锁、alias 复用 ssh config 均正确）。

**教训**：验收必须要求贴真实命令输出，只看 `swift build` 通过毫无意义。

### 真机网络实测（决定了设计优先级）

| 指标 | 实测值 |
|---|---|
| 上行 Mac → 服务器 | **2.27 MB/s** ← 瓶颈所在 |
| 下行 服务器 → Mac | 6.22 MB/s |
| gzip 压缩收益（文本） | 约 2.7 倍 |

**结论**：上传是主场景却也是瓶颈，因此秒传、断点续传、智能压缩的优先级高于原始吞吐优化。

### 已定契约（不可擅改）

- `docs/PROTOCOL.md` — Go agent 与 Swift 客户端的接口约定
- `Sources/Dropship/Core/Contracts/Models.swift` — 共享数据模型
- `Sources/Dropship/Core/Contracts/Services.swift` — Core 对 UI 暴露的接口

### 已建骨架

- `Package.swift`（SPM，Swift 5 语言模式）
- `scripts/build-app.sh`（编译 + 组装 bundle + ad-hoc 签名）
- `Sources/Dropship/DropshipApp.swift`（应用入口）

## 架构

```
Mac 客户端 (SwiftUI)
    │
    ├── UI 层        三栏布局 + 拖拽 + 传输队列面板
    ├── Core 层      SSH 会话 / agent 引导 / 传输队列 / ssh config 解析
    │
    └──/usr/bin/ssh──> 服务器: ~/.local/share/dropship/agent
                       stdio 通信，不监听端口，鉴权由 SSH 承担
                       不可用时自动降级为 sftp
```

**关键决策**

1. **不用 Tauri，用原生 SwiftUI** — 拖出 Finder 需要 `NSFilePromiseProvider`，原生直接可用
2. **不用 `.xcodeproj`，用 SPM** — 纯文本，多人/多 agent 并行编辑不冲突
3. **agent 走 SSH stdio，不监听端口** — 免鉴权、免防火墙、免端口管理
4. **agent 装 `~/.local/share/`，不装 `/usr/local/bin`** — 目标服务器存在非 root 账号，装系统目录会要 sudo
5. **必须保留 SFTP 降级路径** — agent 出任何问题都不能让 app 不可用

## 分工

| 线 | 范围 | 目录所有权 |
|---|---|---|
| A · Go agent | 服务器端二进制 | `agent/**` |
| B · Swift Core | SSH、引导、传输、队列 | `Sources/Dropship/Core/**`（Contracts 除外） |
| C · SwiftUI 界面 | 三栏布局、拖拽、队列面板 | `Sources/Dropship/UI/**` |

主控负责：契约维护、集成、真机验证。

## 构建

```bash
./scripts/build-app.sh          # debug
./scripts/build-app.sh release  # release
open build/Dropship.app
```

## 待办

- [ ] A · Go agent 实现
- [ ] B · Swift Core 实现
- [ ] C · SwiftUI 界面实现
- [ ] 集成与真机验证（tencent-dev root / aliyun02 非 root）
- [ ] 拖出 Finder 的 `NSFilePromiseProvider` 验证
