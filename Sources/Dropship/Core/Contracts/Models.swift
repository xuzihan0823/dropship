import Foundation

// ============================================================
// 契约文件 · 由主控维护
//
// UI 层与 Core 层共同依赖此文件。任何一方擅自修改都会破坏另一方的编译。
// 需要变更请向主控提出，不要直接改。
// ============================================================

// MARK: - 服务器配置

/// 一台服务器的连接配置。可来自 ~/.ssh/config 解析，也可手动添加。
public struct ServerConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// ssh config 中的 Host 别名，如 "tencent-dev"。手动添加时可自拟。
    public var alias: String
    /// 界面上显示的名字，默认等于 alias。
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var username: String
    /// 私钥路径，nil 表示交由 ssh 自行决定。
    public var identityFile: String?
    /// 跳板机（对应 ssh config 的 ProxyJump）。
    public var proxyJump: String?
    /// 配置来源，决定是否可编辑。
    public var source: Source
    /// 连接后默认打开的远程目录，nil 表示用户家目录。
    public var defaultRemotePath: String?
    /// 收藏的远程路径。
    public var favorites: [String]
    /// 是否允许把 Dropship agent 二进制上传到这台服务器并执行。
    /// 关闭后该服务器只走 SFTP 降级路径。
    public var allowAgentDeploy: Bool = true

    public enum Source: String, Codable, Sendable {
        case sshConfig   // 从 ~/.ssh/config 导入
        case manual      // 用户手动添加
    }

    public init(
        id: UUID = UUID(),
        alias: String,
        displayName: String? = nil,
        hostname: String,
        port: Int = 22,
        username: String,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        source: Source = .manual,
        defaultRemotePath: String? = nil,
        favorites: [String] = [],
        allowAgentDeploy: Bool = true
    ) {
        self.id = id
        self.alias = alias
        self.displayName = displayName ?? alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.source = source
        self.defaultRemotePath = defaultRemotePath
        self.favorites = favorites
        self.allowAgentDeploy = allowAgentDeploy
    }

    private enum CodingKeys: String, CodingKey {
        case id, alias, displayName, hostname, port, username
        case identityFile, proxyJump, source, defaultRemotePath, favorites
        case allowAgentDeploy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        alias = try container.decode(String.self, forKey: .alias)
        displayName = try container.decode(String.self, forKey: .displayName)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        proxyJump = try container.decodeIfPresent(String.self, forKey: .proxyJump)
        source = try container.decode(Source.self, forKey: .source)
        defaultRemotePath = try container.decodeIfPresent(String.self, forKey: .defaultRemotePath)
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites) ?? []
        allowAgentDeploy = try container.decodeIfPresent(Bool.self, forKey: .allowAgentDeploy) ?? true
    }
}

// MARK: - 远程文件条目

/// 远程目录中的一项。字段与 docs/PROTOCOL.md 的 Entry 一一对应。
public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var isDir: Bool
    public var isSymlink: Bool
    public var symlinkTarget: String?
    public var size: Int64
    /// 八进制权限字符串，如 "0644"。
    public var mode: String
    public var modTime: Date
    public var owner: String
    public var group: String

    public var id: String { path }

    public init(
        name: String, path: String, isDir: Bool, isSymlink: Bool = false,
        symlinkTarget: String? = nil, size: Int64, mode: String,
        modTime: Date, owner: String = "", group: String = ""
    ) {
        self.name = name
        self.path = path
        self.isDir = isDir
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.size = size
        self.mode = mode
        self.modTime = modTime
        self.owner = owner
        self.group = group
    }
}

// MARK: - 连接状态

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    /// 已连接，并标明实际生效的传输通道。
    case connected(transport: TransportMode)
    case failed(String)
}

/// 实际生效的传输通道。agent 不可用时自动降级为 sftp，功能不减但速度较低。
public enum TransportMode: String, Equatable, Sendable {
    case agent   // Go agent，支持秒传/续传/压缩
    case sftp    // 系统 sftp 降级通道
}

// MARK: - 传输任务

public enum TransferDirection: String, Sendable {
    case upload    // Mac → 服务器
    case download  // 服务器 → Mac
}

public enum TransferState: Equatable, Sendable {
    case queued
    case preparing      // 计算哈希 / 探测远端
    case transferring
    case verifying      // 校验哈希
    case awaitingDecision // 目标已存在，等待用户选择处理方式
    case completed
    case skipped        // 秒传命中，内容一致，无需传输
    case paused
    case failed(TransferError)
    case cancelled
}

public struct TransferError: Error, LocalizedError, Equatable, Sendable {
    /// 对应 docs/PROTOCOL.md 第 4 节的稳定错误码。
    public var code: String
    public var message: String
    /// 是否值得自动重试。
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public var errorDescription: String? {
        message.isEmpty ? code : message
    }
}

/// 一个传输任务。UI 只读，由 Core 更新。
public struct TransferTask: Identifiable, Sendable {
    public let id: UUID
    public let serverID: UUID
    public let direction: TransferDirection
    public let localURL: URL
    public let remotePath: String
    /// 显示用文件名。
    public let filename: String

    public var totalBytes: Int64
    public var transferredBytes: Int64
    public var state: TransferState
    public var startedAt: Date?
    public var finishedAt: Date?
    /// 瞬时速度，字节/秒。
    public var speed: Double

    public var progress: Double {
        totalBytes > 0 ? min(1.0, Double(transferredBytes) / Double(totalBytes)) : 0
    }

    /// 预计剩余秒数，无法估算时为 nil。
    public var eta: TimeInterval? {
        guard speed > 0, totalBytes > transferredBytes else { return nil }
        return Double(totalBytes - transferredBytes) / speed
    }

    public init(
        id: UUID = UUID(), serverID: UUID, direction: TransferDirection,
        localURL: URL, remotePath: String, filename: String,
        totalBytes: Int64 = 0, transferredBytes: Int64 = 0,
        state: TransferState = .queued, startedAt: Date? = nil,
        finishedAt: Date? = nil, speed: Double = 0
    ) {
        self.id = id
        self.serverID = serverID
        self.direction = direction
        self.localURL = localURL
        self.remotePath = remotePath
        self.filename = filename
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.speed = speed
    }
}

// MARK: - 覆盖策略

/// 目标已存在同名文件时的处理方式。
public enum ConflictPolicy: String, Sendable {
    case ask        // 询问用户
    case overwrite  // 直接覆盖
    case skip       // 跳过
    case rename     // 自动重命名为 name-1.ext
}

/// 一项等待用户选择处理方式的同名文件冲突。
public struct PendingTransferConflict: Identifiable, Equatable, Sendable {
    public let taskID: UUID
    public let filename: String
    public let destinationPath: String
    public let direction: TransferDirection
    public let sourceBytes: Int64
    public let destinationBytes: Int64?

    public var id: UUID { taskID }

    public init(
        taskID: UUID,
        filename: String,
        destinationPath: String,
        direction: TransferDirection,
        sourceBytes: Int64,
        destinationBytes: Int64?
    ) {
        self.taskID = taskID
        self.filename = filename
        self.destinationPath = destinationPath
        self.direction = direction
        self.sourceBytes = sourceBytes
        self.destinationBytes = destinationBytes
    }
}

// MARK: - 反向收件隧道

/// 一台服务器的反向隧道状态。
///
/// Mac 在 NAT 后面，服务器无法主动连进来，因此由 Mac 侧发起 `ssh -R`，
/// 把服务器的 `127.0.0.1:<remotePort>` 反向转发到 App 内置的收件端点。
public enum TunnelState: Equatable, Sendable {
    case disabled
    case starting
    /// 已建立。remotePort 是服务器上回环地址的端口，写进服务器的 inbox.env 供 agent 使用。
    case active(remotePort: Int)
    case failed(String)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

/// 服务器推回来的一个文件。由 TunnelService 维护，只增不改。
public struct InboxItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// 推送方。靠 token 区分，每台服务器一把。
    public let serverID: UUID
    public let filename: String
    public let url: URL
    public let bytes: Int64
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        serverID: UUID,
        filename: String,
        url: URL,
        bytes: Int64,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.filename = filename
        self.url = url
        self.bytes = bytes
        self.receivedAt = receivedAt
    }
}
