import SwiftUI
import Combine

// ============================================================
// 应用环境：UI 层的服务容器。
//
// 当前实现默认用 Mock 服务驱动界面。Core 实现就绪后，
// 只需替换这里三个属性的构造，UI 代码无需改动。
// ============================================================

@MainActor
final class AppEnvironment: ObservableObject {
    let serverStore: MockServerStore
    let remoteFiles: MockRemoteFileService
    let transferQueue: MockTransferQueue

    /// 当前选中的服务器。nil 表示未选中。
    @Published var selectedServerID: UUID?
    /// 是否显示隐藏文件。
    @Published var showHiddenFiles: Bool = false
    /// 传输队列面板是否展开。
    @Published var transferPanelExpanded: Bool = true

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let store = MockServerStore()
        let queue = MockTransferQueue()
        let remote = MockRemoteFileService()
        self.serverStore = store
        self.remoteFiles = remote
        self.transferQueue = queue
        // 默认选中第一台已连接的服务器
        self.selectedServerID = store.servers.first?.id

        // 转发子对象的变化到自身，这样所有观察 env 的视图都能更新
        store.$servers
            .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
            .store(in: &cancellables)
        store.$states
            .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
            .store(in: &cancellables)
        queue.$tasks
            .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
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
}
