import SwiftUI
import Combine

// ============================================================
// 应用环境：UI 层的服务容器。
//
// 已接入真实 Core：SSH 会话、agent 自动部署、传输队列。
// 连接编排放在这里 —— ServerStore 只存状态，实际连接由
// RemoteFileServiceImpl 完成，两者由本类协调。
// ============================================================

@MainActor
final class AppEnvironment: ObservableObject {
    let serverStore: ServerStore
    let remoteFiles: RemoteFileServiceImpl
    let transferQueue: TransferQueue
    /// 反向收件隧道：服务器往 Mac 推文件的通路，每台服务器一个开关。
    let tunnels: TunnelService

    /// 当前选中的服务器。nil 表示未选中。
    @Published var selectedServerID: UUID?
    /// 是否显示隐藏文件。
    @Published var showHiddenFiles: Bool = false
    /// 传输队列面板是否展开。
    @Published var transferPanelExpanded: Bool = true

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let store = ServerStore()
        let remote = RemoteFileServiceImpl()
        let queue = TransferQueue(service: remote)
        self.serverStore = store
        self.remoteFiles = remote
        self.transferQueue = queue
        self.tunnels = TunnelService()

        // 首次启动且本地无配置时，从 ~/.ssh/config 导入实验用服务器。
        // 只导入这一台，避免误连其它机器。
        if store.servers.isEmpty {
            if let parsed = try? store.parseSSHConfig(),
               let target = parsed.first(where: {
                   $0.hostname == "106.54.40.65" && $0.username == "root"
               }) {
                store.add(target)
                try? store.save()
            }
        }
        self.selectedServerID = store.servers.first?.id

        // Server changes affect several computed environment properties.
        // TransferQueuePanel observes the queue directly; forwarding every
        // progress tick here would redraw both file browsers as well.
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// 当前选中的 ServerConfig，未选中时为 nil。
    var selectedServer: ServerConfig? {
        guard let id = selectedServerID else { return nil }
        return serverStore.servers.first { $0.id == id }
    }

    /// 当前选中服务器的连接状态。
    var selectedConnectionState: ConnectionState {
        guard let id = selectedServerID else { return .disconnected }
        return serverStore.connectionState(of: id)
    }

    /// 连接 / 断开。连接过程包含 agent 探测与自动部署，失败时自动降级为 SFTP。
    func toggleConnection(_ id: UUID) {
        guard let server = serverStore.servers.first(where: { $0.id == id }) else { return }

        switch serverStore.connectionState(of: id) {
        case .connecting:
            return  // 进行中，忽略重复点击

        case .connected:
            // 先停隧道再断连接：此刻 SSH 主连接还在，能顺手把服务器上的
            // inbox.env 删掉，不留一份指向死端口的配置。
            tunnels.suspend(id)
            serverStore.setState(.disconnected, for: id)
            Task { await remoteFiles.disconnect(id) }

        case .disconnected, .failed:
            serverStore.setState(.connecting, for: id)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let mode = try await self.remoteFiles.connect(server)
                    self.serverStore.setState(.connected(transport: mode), for: id)
                    // 开关记着是开的就把隧道拉起来
                    self.tunnels.resumeIfEnabled(server)
                } catch {
                    self.serverStore.setState(.failed(Self.describe(error)), for: id)
                }
            }
        }
    }

    /// 把底层错误转成一句能看懂的话。
    static func describe(_ error: Error) -> String {
        if let t = error as? TransferError {
            return t.message.isEmpty ? t.code : t.message
        }
        return error.localizedDescription
    }

    /// 拨动某台服务器的反向收件隧道。
    ///
    /// 隧道自己起独立的 ssh 连接，不依赖上面的"已连接"状态，
    /// 所以没连上也能开 —— 只要 SSH 能登录就行。
    func toggleTunnel(_ id: UUID) {
        guard let server = serverStore.servers.first(where: { $0.id == id }) else { return }
        tunnels.setEnabled(!tunnels.isEnabled(id), for: server)
    }

    private var didAutoConnect = false

    /// 启动后自动连接当前选中的服务器，只触发一次。
    /// 已连接或正在连接时不重复发起。
    func autoConnectIfNeeded() {
        guard !didAutoConnect, let id = selectedServerID else { return }
        didAutoConnect = true
        if case .disconnected = serverStore.connectionState(of: id) {
            toggleConnection(id)
        }
    }
}
