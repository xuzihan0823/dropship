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
