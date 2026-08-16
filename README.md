# Dropship

Mac 与 Linux 服务器之间的拖拽式文件互传工具。macOS 原生 SwiftUI 应用，左边本地目录、右边服务器目录，拖过去就传。

底层只依赖 `ssh`——不需要在服务器上装守护进程、开额外端口或改防火墙。

**当前版本 0.2.0，要求 macOS 14+。**

---

## 安装

目前没有预编译版本，从源码构建：

```bash
git clone https://github.com/xuzihan0823/dropship.git
cd dropship
./scripts/build-app.sh
open build/Dropship.app
```

构建需要 Xcode（Swift 6 工具链）和 Go（用于编译 Linux agent）。

### Gatekeeper 提示

应用使用 ad-hoc 签名，**没有 Apple 开发者证书，也未经公证**。从别处下载的话 macOS 会拒绝打开，需要手动解除隔离：

```bash
xattr -dr com.apple.quarantine /path/to/Dropship.app
```

自己构建的产物不受此限制。

---

## 快速开始

1. 打开应用，点侧边栏底部**「从 SSH 导入」**，从 `~/.ssh/config` 选择服务器；也可以点「添加」手动填。
2. 选中服务器，点工具栏的连接按钮。
3. 左右面板之间拖文件即可传输。拖到目录行上会落进该目录，拖到空白处落到当前目录。

支持从 Finder 直接拖入，也支持把远程文件拖到 Finder（承诺式拖拽，拖出时才真正下载）。

---

## 两种传输模式（请务必读这一节）

### Agent 模式（默认）

连接时，Dropship 会**把一个 Go 编译的 agent 二进制上传到你的服务器并执行**。具体是：

| 项目 | 内容 |
|---|---|
| 上传什么 | Dropship agent，静态链接二进制，约 2.5MB |
| 传到哪 | `$HOME/.local/share/dropship/agent` |
| 权限 | `0755` |
| 是否执行 | **是**，每次传输和目录操作都会调用它 |
| 支持架构 | linux/amd64、linux/arm64 |

agent 的完整协议契约在 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)，源码在 [`agent/`](agent/)，随仓库一起构建，你可以自己审计和复现。

**为什么要这么做**：agent 提供了纯 SSH 命令做不到的保护——传输结束时校验字节数和哈希，校验通过才原子 rename。这直接防住了一类会毁数据的事故：SSH 断线导致的半截文件覆盖服务器上的原文件。

### SFTP 降级模式

**你可以拒绝部署 agent。** 在服务器编辑界面关闭「允许部署并执行 Dropship agent」即可，这个开关**按服务器独立**，关掉后 Dropship 不会向该服务器写入或执行任何二进制。

代价要说清楚：

- 更慢，且不支持传输压缩
- 传输后**只校验字节数，没有哈希校验**
- 目录列举依赖服务器上的 `find` / `stat`，兼容性不如 agent

修改开关后需要**断开并重新连接**才会生效。

当前模式会显示在侧边栏服务器名下方（⚡ Agent / 🐢 SFTP 降级）。

---

## 反向收件隧道

有时候你想从服务器**主动**把文件推回 Mac，而不是从 Mac 拉。打开某台服务器的收件隧道后，在服务器上执行：

```bash
~/.local/share/dropship/dropship-send <文件或目录>
```

文件会落到 Mac 的 `~/Downloads/Dropship`（可在设置中修改）。目录会自动打包成 `.tar.gz`。

隧道走 SSH 反向端口转发，只监听服务器的回环地址，不对外暴露端口。安全边界详见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md) §7.6。

---

## 已知限制

- 只支持 macOS 14+ 作为客户端
- 服务器端 agent 只提供 linux/amd64 与 linux/arm64；其它平台（BSD、其它架构）会自动降级到 SFTP 模式
- SFTP 降级模式下的续传只校验总字节数，不校验已有 `.part` 前半段的内容是否匹配
- 尚无自动更新与崩溃上报

---

## 开发

```bash
swift build          # 编译
swift test           # 运行测试
./scripts/build-app.sh   # 构建 .app bundle（含 Go agent）
```

开发进度、设计决策和历次缺陷的根因分析记录在 [`PROGRESS.md`](PROGRESS.md)。agent 协议契约在 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)，修改前请先读——里面有几条是真机实测教训换来的硬性要求。

---

## License

待定。
