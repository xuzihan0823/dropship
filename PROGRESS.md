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

### 新增：反向收件隧道，服务器可以主动把文件推回 Mac（2026-08-12）

在此之前 Dropship 是单向发起的：Mac 主动 ssh 出去，服务器没有任何办法把文件送回来。
跑在服务器上的 AI agent 产出构建产物或报告后，只能等人回到 Mac 上手动下载。

现在每台服务器多了一个**收件隧道开关**。打开后：

```
Mac: Dropship.app 内置收件端点 (127.0.0.1:随机端口，仅回环)
      ▲  ssh -N -R 0:127.0.0.1:<本地端口>   ← Mac 发起并常驻，断了按退避重连
服务器: 127.0.0.1:<远端口>  ←── curl ←── 服务器上的 agent
```

服务器那头的用法就一行，脚本由 App 在隧道建立时自动写入：

```sh
~/.local/share/dropship/dropship-send ./build/report.pdf
~/.local/share/dropship/dropship-send ./logs/          # 目录自动打包成 logs.tar.gz
```

推回来的文件默认落在 `~/Downloads/Dropship`，同时出现在底部面板新增的「收件箱」分页里。

**为什么不直接把 Mac 的 sshd 反向转发出去**（远程登录本来就开着，scp 一步到位）：
那需要把一把能登录 Mac 的私钥放到服务器上，服务器被入侵就等于 Mac 被入侵。
选了 App 内置收件端点后，服务器上**不存放任何能登录 Mac 的凭据**，拿到 token 的人
只能**写**、且只能写进收件箱那一个目录，读不到 Mac 上的任何东西。

关键实现点：

| 点 | 处理 |
|---|---|
| 远端口每次重连都变 | 从 ssh stderr 解析 `Allocated port N for remote forward`，每次 active 都重写服务器上的 `inbox.env` |
| 隧道生命周期 | 刻意**不复用** ControlMaster 共享连接（`ControlPath=none`）。挂在共享 master 上的话，master 何时退出不归我们管，还可能在服务器留下没人用的转发端口 |
| ssh 参数覆盖顺序 | ssh 取每个参数**首次出现**的值，所以覆盖项必须排在 `sshArguments` 的基础参数**前面**，否则 `ControlPath=none` 会被忽略 |
| 转发建不起来 | `ExitOnForwardFailure=yes`。服务器 sshd 关了 `AllowTcpForwarding` 时要立刻报错，不能留一个"连上了但其实没通"的假象 |
| 密码提示 | `BatchMode=yes`。常驻进程卡在看不见的密码提示上，表现为永远"建立中" |
| 截断防护 | 收到字节数必须等于 `Content-Length`，不等则**保留 `.part`、绝不 rename** —— 与 PROTOCOL.md 2.2 那次事故同一条底线 |
| 路径穿越 | 先百分号解码再取 lastPathComponent（顺序反了 `%2F` 会解出新分隔符），`PUT /../../../../etc/passwd` 只会落成收件箱里的 `passwd` |
| `Expect: 100-continue` | 必须先回 100。curl 对 >1KB 的 PUT body 默认发这个头，不回它每次传输白等 1 秒 |
| ServerConfig 没加字段 | 它已 Codable 落盘在 servers.json，合成 decode 遇到缺失的非可选 key 会 throw，`ServerStore` 那句 `try?` 会静默把服务器列表清空。开关状态另存 `tunnels.json` |

新增文件：`Core/Tunnel/{InboxServer,ReverseTunnel,TunnelService}.swift`、
`Tests/DropshipTests/InboxTunnelTests.swift`；契约见 `docs/PROTOCOL.md` 第 7 节。
收件箱仍走 TunnelService 自己的轻量数组，只在 UI 上与 `TransferQueue` 并排呈现；本分支
同时合入 8 月 12 日会话中已经验证的大文件、超大目录队列、目录上传、空文件、停止全部和
目录行精准拖放修复。

自动验证覆盖：鉴权（缺 token / 错 token / token 已作废）、截断保留 `.part`、
路径穿越展平、重名不覆盖、chunked 拒绝、100-continue、ssh 端口解析、
参数覆盖顺序、ssh 立即退出触发退避重连。

Mac 本机验证（2026-08-13）：`swift test` 共 30 项通过，`go test ./...` 通过，
`./scripts/build-app.sh` 成功生成并签名 `.app`，同时嵌入 linux/amd64 与 linux/arm64 agent。
基线中 `ReverseTunnel` 无法在长驻 SSH 运行期间收到动态端口的问题也已修复，并由 active
状态测试覆盖。2026-08-13 已在 `tencent-claude` 真机执行 `dropship-send`，Mac 成功收件，
远端与本地 SHA-256 一致；随后默认收件目录由 `~/Desktop/Dropship` 调整为
`~/Downloads/Dropship`，并增加默认路径回归测试。重启新构建后再次从 `tencent-claude`
推送测试文件，文件仅落入新目录、未落入旧目录，大小与 SHA-256 一致，App 收件箱列表
也正确显示该记录。旧目录中的现有文件未迁移或删除。

收件箱分页新增当前路径与「修改位置…」入口，使用 macOS 原生文件夹选择面板。自定义
位置持久化在 `tunnels.json`，切换时已开启的隧道会自动重建；旧版只有 `enabled` 字段的
配置仍可读取。若用户在 Finder 中删除当前收件目录，下一次回传会自动重建目录和
`.incoming` 后继续收件。

真机删除重建验证：将 App 临时指向隔离目录并建立 `tencent-claude` 隧道，随后把该目录
移入废纸篓模拟用户删除；服务器执行 `dropship-send` 后，同一路径及 `.incoming` 自动
重建，76 字节测试文件成功落地，远端与本地 SHA-256 一致。验证后已恢复正式路径
`~/Downloads/Dropship`，测试目录与产物均移入废纸篓。

### 非 root 账号远程目录加载修复（2026-08-13）

远程面板原先在未设置 `defaultRemotePath` 时固定打开 `/root`，导致 `tencent-claude`
（登录用户 `claude`，家目录 `/home/claude`）刷新时收到 `EACCES`。现在连接后通过 agent
查询当前用户家目录；显式配置的 `defaultRemotePath` 仍优先。`TransferError` 同时实现
`LocalizedError`，权限等业务错误会显示真实 message，不再显示 `Dropship.TransferError error 1`。
新增非 root 初始目录、显式路径优先和错误展示回归测试。

真机界面验证：重启应用后选择并连接 `tencent-claude`，远端面包屑正确进入
`/home/claude`，目录列表成功显示 `shared`、`projects`、`repair_repo.sh`；隧道状态及
关闭按钮正常。`swift test` 共 33 项通过，`go test ./...` 通过。

### 大文件拖入远程区域卡死/退出修复（2026-08-12）

现象是普通大文件拖入服务器区域后先卡住再退出，但 `.zip` 等压缩包可正常上传。
代码路径确认存在两个叠加问题：

1. 队列对普通扩展名传入 `compress=true`，`AgentTransport` 因此追加 `--compress gzip`，
   但 `SSHProcessRunner` 实际仍发送原始字节。远端 agent 会立刻以 gzip 格式错误退出；
   `.zip` 在免压缩列表中，因此不触发这条错误路径。
2. 流式传输只在子进程结束后读取 `stderr`，而 agent 会持续向 `stderr` 输出进度。
   大文件传输可填满管道缓冲，导致 ssh 与客户端互相等待。

修复：在客户端实现对称的流式 gzip 编解码前关闭传输压缩协商；上传和下载期间持续排空
子进程管道，只保留最多 1 MiB 的错误尾部；保留应用入口的 `SIGPIPE` 忽略作为断管防护。

自动验证：`swift test` 3 项通过，覆盖大量 stderr、子进程提前退出、普通文件禁用伪 gzip；
`swift build`、`./scripts/build-app.sh` 和 `go test ./...` 通过。Finder 拖拽实机复现按用户要求留给用户执行。

### 超大目录队列 CPU 优化（2026-08-12）

对 32,337 个文件的 `node_modules` 上传诊断确认，CPU 热点来自完整任务数组的频繁发布、
SwiftUI 对数万行的重复遍历/构建，以及每次进度回调都进入主线程。第一阶段优化保留原有
“每文件一次传输”的协议不变：目录扫描按 250 个任务分批发布，任务 ID 使用索引表和待处理
队列，摘要计数增量维护；UI 最多渲染 200 个任务，并用完成版本号刷新文件面板；进度回调在
进入主线程前合并到每 100ms 一次，队列变化不再通过 AppEnvironment 广播给整个界面。

新增 10,000 文件压力回归和 1,000 次突发进度回归，验证可见任务上限、摘要/索引一致性、
进度节流和最终完成状态。真实大目录拖拽和 CPU 复测仍按用户要求由用户执行。

### 目录上传缺少远端父目录修复（2026-08-12）

目录上传原先只递归生成文件任务，没有先创建对应的远端目录，导致 agent 打开
`<目标>.dropship-part` 时返回 `no such file or directory`。现改为每个上传任务在冲突检查和
传输前确保远端父目录存在；同一服务器和目录的并发任务共享一次 `mkdir -p`，队列空闲后
清除缓存。失败任务会读取远端 `.dropship-part` 的实际大小作为已传输字节，避免本地已写入
SSH 管道后仍显示误导性的 100%。新增远端目录创建去重和失败进度回落回归测试。

### 空文件与全队列中断修复（2026-08-12）

agent 原先用 `expect-size == 0` 判断参数缺失，导致合法的 0 字节文件被拒绝。现单独记录参数
是否出现，并把 agent 版本提升为 1.0.1，使客户端下次连接时自动部署新二进制。传输队列新增
“停止全部”：同时终止当前 SSH 传输、取消排队/暂停任务，并停止尚在后台进行的目录扫描；
已完成和失败历史保留。

### 文件夹行精准拖放（2026-08-12）

本地和远程文件表此前只在整张 Table 上注册投放，已有的坐标落点代理没有挂入视图树，导致
拖到目录行仍落入当前目录。现为两侧的目录 `TableRow` 直接注册 macOS 原生
`dropDestination`，由 NSTableView 负责排序、滚动后的准确行命中与高亮；投放到空白区域仍
使用当前目录，普通文件行不作为目录目标。

补齐服务器列表自身的拖拽源：远程条目使用应用内部 `dropship-remote://` URL 载荷，不伪装成
本地文件 URL；本机文件与远程条目共用目录行唯一的 `URL.dropDestination`，回调后再分类为
上传或同服务器 `move`。这是因为 SwiftUI TableRow 叠加两个不同类型的 `dropDestination` 时
运行中只会注册一个目标。移动会拒绝跨服务器、原目录、目录自身/子目录以及目标同名冲突。
远程面板原先还在整块面板外层额外注册 `.onDrop`，会先于目录行接管事件并固定上传到当前
目录；现已移除，空白区域和目录行都只由共用 `FileTableView` 处理，与本地面板保持一致。

### 真实接入完成，端到端可用（2026-08-11）

UI 已彻底摘除 Mock，接入真实 Core。在 106.54.40.65（root）实测：

| 环节 | 结果 |
|---|---|
| ssh config 解析 | ✅ 5 台全部正确，中文路径与 `~` 均展开 |
| agent 自动部署 | ✅ 干净环境下自动装到 `/root/.local/share/dropship/agent` 755 |
| 生效通道 | ✅ `agent`（二进制缺失时自动降级 `sftp`，两条路径均实测） |
| 真实 list | ✅ 远程面板显示 `/root` 真实内容 |
| 3MB 上传下载往返 | ✅ **MD5 完全一致** |
| 磁盘空间 / stat / remove | ✅ 全部真实生效 |

#### 接线时补上的 Core 缺口

`ServerStore` 与 `TransferQueue` 原本**不是 ObservableObject**，SwiftUI 无法观察其变化，
直接替换会导致界面永不刷新。已补 `ObservableObject` + `@Published`，并新增：

- `ServerStore.setState(_:for:)` — 供 AppEnvironment 写入连接状态
- `TransferQueue.removeTask(_:)` — `tasks` 改为 `private(set)` 后 UI 需要的移除入口

连接编排放在 `AppEnvironment`：ServerStore 只存状态，实际连接由 RemoteFileServiceImpl 完成。

#### 两个排查耗时较久的问题

1. **`ByteCountFormatter` 缺 `.useBytes`** — 411 字节的文件显示成 `0 KB`
2. **窗口启动后不出现** — `sample` 抓主线程栈发现卡在 `NSPersistentUIRestorer`，
   是反复 `pkill` 强杀导致 macOS 窗口状态恢复记录损坏。已在 Info.plist 设
   `NSQuitAlwaysKeepsWindows = false` 从源头关闭该机制。
   排查中一度误判为 SSH 阻塞主线程，实际 `run()` 已正确派发到后台队列。

### SwiftUI 界面完成并修复 3 个集成缺陷（2026-08-10）

2767 行，`swift build` 零错误零警告。深浅色模式均已截图验证，界面按 macOS 原生规范渲染。

界面线因 GLM 模型限额中断在截图前，剩余验证与修复由主控接手。启动时连续崩溃两次，均已定位修复：

| 缺陷 | 位置 | 后果 |
|---|---|---|
| 对空数组调用 `removeFirst()` | `Breadcrumbs.pathSegments()` | **启动必崩**。该行结果被 `_ =` 丢弃且变量之后未再使用，是完全多余的代码，但路径为 `/` 时数组为空必然触发断言。远程面板初始即为根目录 |
| 漏注入 `EnvironmentObject` | `RootView` → `ServerSidebar` | **启动必崩**。同级另三个面板都注入了，唯独侧边栏遗漏。已改为在根部统一注入 |
| `ByteCountFormatter` 把 0 渲染成 "Zero KB" | `Formatters.byteSize` | 传输队列里 0 字节任务显示 "Zero KB / 156 MB"，看着像坏了。已设 `allowsNonnumericFormatting = false` |

已验证可用：服务器侧边栏（含 Agent/SFTP 降级状态区分、连接失败原因显示）、双文件面板、
面包屑、文件类型图标、传输队列（进度/速度/ETA/状态）、深浅色适配。

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

- [x] A · Go agent 实现（真机验证通过，含截断防护）
- [x] C · SwiftUI 界面实现（深浅色截图验证通过）
- [x] 拖出 Finder 的承诺式拖拽验证（纯 SwiftUI 可行）
- [ ] B · Swift Core 实现（返工中）
- [ ] 集成：Core 接入真实传输，替换 UI 的 Mock
- [ ] 端到端真机验证（tencent-dev root / aliyun02 非 root）

## 模型可用性备注

GLM 于 2026-08-10 达到限额，A 线与 C 线（均为 GLM）中断。
**agent 模型在 spawn 后不可更改**，因此处理方式为停止该 agent、由主控或其他模型接手，
而非"通知其换模型"。两条线的产出均已保全并完成验证。
