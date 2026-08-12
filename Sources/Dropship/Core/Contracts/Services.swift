import Foundation

// ============================================================
// 契约文件 · 由主控维护
//
// Core 层负责实现这些接口，UI 层只对着接口编程。
// 双方并行开发的边界就在这里，不要绕过接口直接依赖具体实现。
// ============================================================

// MARK: - 远程文件操作

/// 远程文件系统操作。实现方需在内部处理 agent / sftp 通道选择与自动降级。
public protocol RemoteFileService: AnyObject {
    /// 建立连接并完成 agent 引导，返回实际生效的通道。
    /// 若 agent 部署失败，必须降级为 .sftp 而不是抛错。
    func connect(_ server: ServerConfig) async throws -> TransportMode

    func disconnect(_ serverID: UUID) async

    func list(_ server: ServerConfig, path: String, showHidden: Bool) async throws -> [RemoteEntry]

    func stat(_ server: ServerConfig, path: String) async throws -> RemoteEntry

    func makeDirectory(_ server: ServerConfig, path: String) async throws

    /// recursive 为 false 时删除非空目录应抛出错误，由 UI 询问后重试。
    func remove(_ server: ServerConfig, path: String, recursive: Bool) async throws

    func move(_ server: ServerConfig, from: String, to: String) async throws

    func chmod(_ server: ServerConfig, path: String, mode: String) async throws

    /// 用户家目录绝对路径，用于确定初始浏览位置。
    func homeDirectory(_ server: ServerConfig) async throws -> String

    /// 返回 (总字节, 可用字节)。
    func diskSpace(_ server: ServerConfig, path: String) async throws -> (total: Int64, free: Int64)
}

// MARK: - 传输队列

/// 传输队列。tasks 保留完整任务历史，实现可另外提供有界的 UI 快照。
@MainActor
public protocol TransferQueueService: AnyObject {
    /// 当前全部任务，含已完成。
    var tasks: [TransferTask] { get }

    /// 同时进行的传输数上限。考虑到上行带宽有限，默认 2。
    var maxConcurrent: Int { get set }

    /// 拖拽上传入口。localURLs 可能包含目录，实现方需自行递归展开。
    func enqueueUpload(
        localURLs: [URL],
        to server: ServerConfig,
        remoteDir: String,
        policy: ConflictPolicy
    )

    /// 下载入口。entries 可能包含目录，实现方需自行递归展开。
    func enqueueDownload(
        entries: [RemoteEntry],
        from server: ServerConfig,
        localDir: URL,
        policy: ConflictPolicy
    )

    func pause(_ taskID: UUID)
    func resume(_ taskID: UUID)
    func cancel(_ taskID: UUID)
    /// 取消当前队列中所有未结束任务，并停止仍在进行的目录扫描。
    func cancelAll()
    func retry(_ taskID: UUID)

    /// 清除已完成/已跳过/已取消的任务，保留失败项。
    func clearFinished()
}

// MARK: - 服务器管理

@MainActor
public protocol ServerStoreService: AnyObject {
    var servers: [ServerConfig] { get }

    /// 解析 ~/.ssh/config 并返回可导入的条目（不自动落库，由 UI 让用户确认）。
    func parseSSHConfig() throws -> [ServerConfig]

    func add(_ server: ServerConfig)
    func update(_ server: ServerConfig)
    func remove(_ serverID: UUID)

    func connectionState(of serverID: UUID) -> ConnectionState

    /// 持久化到磁盘。
    func save() throws
}

// MARK: - 拖出支持

/// 从远程面板往 Finder 拖文件时，AppKit 需要一个能按需取回文件的入口。
/// 由 Core 实现，UI 的 NSFilePromiseProvider 委托调用。
public protocol FilePromiseResolver: AnyObject {
    /// 将远程文件下载到指定本地 URL。用于承诺式拖拽。
    /// 必须在 completion 中回调，失败时传入错误。
    func fulfillPromise(
        entry: RemoteEntry,
        server: ServerConfig,
        destination: URL,
        completion: @escaping (Error?) -> Void
    )
}
