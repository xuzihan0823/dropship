import SwiftUI

// ============================================================
// 应用根视图：三栏 NavigationSplitView + 底部传输队列面板。
//
// 保持 RootView 类型名和无参数初始化不变，DropshipApp 直接调用。
// 默认用 Mock 服务驱动界面，Core 就绪后替换 AppEnvironment 即可。
// ============================================================

struct RootView: View {
    @StateObject private var env = AppEnvironment()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                ServerSidebar(store: env.serverStore, tunnels: env.tunnels)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } content: {
                LocalFilePanel(queue: env.transferQueue)
                    .environmentObject(env)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 420)
            } detail: {
                RemoteFilePanel(queue: env.transferQueue)
                    .environmentObject(env)
            }
            .navigationTitle(selectedTitle)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    if let server = env.selectedServer {
                        Button {
                            env.toggleConnection(server.id)
                        } label: {
                            Label(connectButtonTitle, systemImage: connectButtonIcon)
                        }
                        .help(connectButtonTitle)

                        Button {
                            env.toggleTunnel(server.id)
                        } label: {
                            Label(tunnelButtonTitle, systemImage: tunnelButtonIcon)
                        }
                        .help(tunnelButtonHelp)
                    }
                }
            }

            Divider()
            TransferQueuePanel(queue: env.transferQueue, tunnels: env.tunnels)
                .environmentObject(env)
                .frame(height: env.transferPanelExpanded ? 220 : 38)
        }
        // 统一在根部注入，避免某个子视图漏注入导致 EnvironmentObject 崩溃
        .environmentObject(env)
        .onAppear { env.autoConnectIfNeeded() }
    }

    private var selectedTitle: String {
        if let server = env.selectedServer {
            return server.displayName
        }
        return "Dropship"
    }

    private var connectButtonTitle: String {
        guard let _ = env.selectedServer else { return "" }
        switch env.selectedConnectionState {
        case .disconnected, .failed: return "连接"
        case .connecting: return "连接中…"
        case .connected: return "断开"
        }
    }

    private var connectButtonIcon: String {
        switch env.selectedConnectionState {
        case .disconnected, .failed: return "link"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "link.badge.plus"
        }
    }

    // MARK: - 收件隧道

    private var tunnelState: TunnelState {
        guard let server = env.selectedServer else { return .disabled }
        return env.tunnels.state(of: server.id)
    }

    private var tunnelButtonTitle: String {
        guard let server = env.selectedServer else { return "" }
        return env.tunnels.isEnabled(server.id) ? "关闭收件隧道" : "开启收件隧道"
    }

    private var tunnelButtonIcon: String {
        switch tunnelState {
        case .disabled: return "arrow.down.circle"
        case .starting: return "arrow.triangle.2.circlepath"
        case .active: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var tunnelButtonHelp: String {
        switch tunnelState {
        case .disabled:
            return "开启后服务器可以主动把文件推回这台 Mac"
        case .starting:
            return "收件隧道建立中…"
        case .active(let remotePort):
            return "已通 · 服务器上执行 \(TunnelService.sendCommand)（回环端口 \(remotePort)）"
        case .failed(let message):
            return "收件隧道：\(message)"
        }
    }
}

// MARK: - 预览

#Preview {
    RootView()
        .frame(width: 1200, height: 800)
}
