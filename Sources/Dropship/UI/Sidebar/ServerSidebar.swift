import SwiftUI
import AppKit

// ============================================================
// 服务器侧边栏：列出所有服务器、连接状态、右键菜单、底部操作按钮。
// ============================================================

struct ServerSidebar: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var store: ServerStore
    @ObservedObject private var tunnels: TunnelService
    @State private var editingServer: ServerConfig?
    @State private var showingAddSheet = false
    @State private var importCandidates: [ServerConfig]?
    @State private var showImportSheet = false

    init(store: ServerStore, tunnels: TunnelService) {
        self.store = store
        self.tunnels = tunnels
    }

    var body: some View {
        List(selection: $env.selectedServerID) {
            Section {
                ForEach(store.servers) { server in
                    ServerRow(
                        server: server,
                        state: store.connectionState(of: server.id),
                        tunnel: tunnels.state(of: server.id)
                    )
                        .tag(server.id)
                        .contextMenu {
                            contextMenu(for: server)
                        }
                }
            } header: {
                Text("服务器").font(.headline)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .sheet(isPresented: $showingAddSheet) {
            ServerFormSheet(mode: .add) { newServer in
                store.add(newServer)
            }
        }
        .sheet(item: $editingServer) { server in
            ServerFormSheet(mode: .edit(server)) { updated in
                store.update(updated)
            }
        }
        .sheet(isPresented: $showImportSheet) {
            if let candidates = importCandidates {
                ImportSSHConfigSheet(candidates: candidates) { chosen in
                    for c in chosen { store.add(c) }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for server: ServerConfig) -> some View {
        let state = store.connectionState(of: server.id)
        switch state {
        case .disconnected, .failed:
            Button {
                env.toggleConnection(server.id)
            } label: {
                Label("连接", systemImage: "link")
            }
        case .connecting:
            Button(role: .destructive) {
                store.setState(.disconnected, for: server.id)
            } label: {
                Label("取消连接", systemImage: "xmark")
            }
        case .connected:
            Button {
                env.toggleConnection(server.id)
            } label: {
                Label("断开", systemImage: "link.badge.plus")
            }
        }
        Divider()
        tunnelMenu(for: server)
        Divider()
        Button {
            editingServer = server
        } label: {
            Label("编辑…", systemImage: "pencil")
        }
        Button {
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(server.hostname, forType: .string)
            #endif
        } label: {
            Label("拷贝主机地址", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) {
            store.remove(server.id)
        } label: {
            Label("删除", systemImage: "trash")
        }
        .disabled(server.source == .sshConfig)
    }

    /// 反向收件隧道的开关与便捷命令。这是让服务器上的 agent 把文件推回 Mac 的入口。
    @ViewBuilder
    private func tunnelMenu(for server: ServerConfig) -> some View {
        let enabled = tunnels.isEnabled(server.id)
        Button {
            env.toggleTunnel(server.id)
        } label: {
            Label(
                enabled ? "关闭收件隧道" : "开启收件隧道",
                systemImage: enabled ? "arrow.down.circle.fill" : "arrow.down.circle"
            )
        }

        if case .active(let remotePort) = tunnels.state(of: server.id) {
            Button {
                copyToPasteboard(TunnelService.sendCommand)
            } label: {
                Label("拷贝服务器端推送命令", systemImage: "terminal")
            }
            Text("服务器 127.0.0.1:\(remotePort) → 本机收件箱")
        }

        Button {
            #if canImport(AppKit)
            _ = NSWorkspace.shared.open(tunnels.inboxDirectory)
            #endif
        } label: {
            Label("打开收件箱目录", systemImage: "tray.and.arrow.down")
        }
    }

    private func copyToPasteboard(_ value: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    importCandidates = (try? store.parseSSHConfig()) ?? []
                    showImportSheet = true
                } label: {
                    Label("从 SSH 导入", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showingAddSheet = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(.regularMaterial)
    }
}

// MARK: - 单行服务器

private struct ServerRow: View {
    let server: ServerConfig
    let state: ConnectionState
    let tunnel: TunnelState

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if server.source == .sshConfig {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("来自 ~/.ssh/config")
                    }
                    tunnelBadge
                }
                subtitle
                tunnelSubtitle
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// 隧道开着才显示。用向下的箭头区别于上传方向。
    @ViewBuilder
    private var tunnelBadge: some View {
        switch tunnel {
        case .disabled:
            EmptyView()
        case .starting:
            Image(systemName: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("收件隧道建立中…")
        case .active(let remotePort):
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
                .help("收件隧道已通 · 服务器 127.0.0.1:\(remotePort)")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption2)
                .foregroundStyle(Color.red)
                .help("收件隧道未连通")
        }
    }

    @ViewBuilder
    private var tunnelSubtitle: some View {
        switch tunnel {
        case .disabled:
            EmptyView()
        case .starting:
            Text("收件隧道建立中…")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .active(let remotePort):
            Text("收件隧道 · 服务器端口 \(remotePort)")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
        case .failed(let message):
            Text("收件隧道：\(message)")
                .font(.caption2)
                .foregroundStyle(Color.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch state {
        case .disconnected:
            Circle().fill(.secondary).frame(width: 9, height: 9)
        case .connecting:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .connected(let transport):
            Circle()
                .fill(Color.green)
                .frame(width: 9, height: 9)
                .help("已连接 · \(transport == .agent ? "Agent 通道" : "SFTP 降级")")
        case .failed:
            Circle().fill(Color.red).frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch state {
        case .disconnected:
            Text(server.hostname)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting:
            Text("连接中…")
                .font(.caption)
                .foregroundStyle(.orange)
        case .connected(let transport):
            HStack(spacing: 4) {
                Image(systemName: transport == .agent ? "bolt.fill" : "tortoise")
                    .font(.caption2)
                Text(transport == .agent ? "Agent" : "SFTP 降级")
            }
            .font(.caption)
            .foregroundStyle(transport == .agent ? Color.green : Color.orange)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(Color.red)
                .lineLimit(1)
        }
    }
}
