import Foundation
import SwiftUI

// ============================================================
// Mock 服务：UI 层自带，让 SwiftUI 开发不依赖 Core 实现。
//
// 实现三个契约协议，返回假数据。数据要像真的：
// - 多台服务器（已连接 agent / 已连接 sftp 降级 / 连接中 / 失败 / 未连接）
// - 几十个文件（目录、归档、代码、文档、图片、视频、音频…）
// - 传输任务覆盖所有状态（排队 / 准备 / 传输中 / 校验 / 完成 / 秒传 / 暂停 / 失败 / 取消）
// - 传输中任务会随时间推进进度，界面看起来是活的。
// ============================================================

// MARK: - MockServerStore

@MainActor
final class MockServerStore: ObservableObject, @unchecked Sendable {
    @Published var servers: [ServerConfig]
    @Published var states: [UUID: ConnectionState]

    init() {
        // 实验用单台服务器。其余演示服务器已移除，避免误连。
        let tencent = ServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            alias: "tencent-dev",
            displayName: "腾讯云开发机",
            hostname: "106.54.40.65",
            port: 22,
            username: "root",
            identityFile: "/Users/mac/Desktop/密钥/shanghai.pem",
            proxyJump: nil,
            source: .sshConfig,
            defaultRemotePath: "/root",
            favorites: ["/root", "/var/log", "/etc"]
        )

        self.servers = [tencent]
        self.states = [
            tencent.id: .connected(transport: .agent),
        ]
    }

    func state(of id: UUID) -> ConnectionState {
        states[id] ?? .disconnected
    }

    /// 模拟一次切换：未连接 -> 连接中 -> 已连接 / 失败。
    func toggleConnection(_ id: UUID) {
        let current = state(of: id)
        switch current {
        case .disconnected, .failed:
            states[id] = .connecting
            let serverID = id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self else { return }
                // 模拟：随机决定是否成功（仅作演示）
                if Bool.random() || serverID == UUID(uuidString: "00000000-0000-0000-0000-000000000001")! {
                    self.states[serverID] = .connected(transport: .agent)
                } else {
                    self.states[serverID] = .failed("握手超时")
                }
            }
        case .connecting, .connected:
            states[id] = .disconnected
        }
    }

    func setState(_ state: ConnectionState, for id: UUID) {
        states[id] = state
    }
}

extension MockServerStore: ServerStoreService {
    nonisolated func parseSSHConfig() throws -> [ServerConfig] {
        // 模拟从 ssh config 解析出来、但还没入库的条目
        return [
            ServerConfig(
                alias: "production",
                displayName: "生产服务器",
                hostname: "prod.example.com",
                port: 22,
                username: "deploy",
                source: .sshConfig
            ),
            ServerConfig(
                alias: "staging",
                displayName: "预发环境",
                hostname: "staging.example.com",
                port: 2222,
                username: "deploy",
                source: .sshConfig
            ),
        ]
    }

    func add(_ server: ServerConfig) {
        servers.append(server)
        states[server.id] = .disconnected
    }

    func update(_ server: ServerConfig) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        }
    }

    func remove(_ serverID: UUID) {
        servers.removeAll { $0.id == serverID }
        states.removeValue(forKey: serverID)
    }

    func connectionState(of serverID: UUID) -> ConnectionState {
        state(of: serverID)
    }

    func save() throws {
        // 模拟：仅打印
    }
}

// MARK: - MockRemoteFileService

actor MockRemoteFileStore {
    /// 每个路径对应的假目录内容。
    private(set) var listings: [String: [RemoteEntry]] = [:]

    func snapshot() -> [String: [RemoteEntry]] { listings }
    func set(_ path: String, _ entries: [RemoteEntry]) { listings[path] = entries }
    func remove(_ path: String) { listings.removeValue(forKey: path) }
    func rename(from: String, to: String) {
        if let entries = listings[from] {
            listings.removeValue(forKey: from)
            listings[to] = entries
        }
    }
}

final class MockRemoteFileService: RemoteFileService, @unchecked Sendable {
    private let store = MockRemoteFileStore()
    private let clock = ContinuousClock()

    init() {
        Task { await seed() }
    }

    private func seed() async {
        let now = Date()
        let min = 60.0
        let hour = 3600.0
        let day = 86400.0

        let tencentRoot: [RemoteEntry] = [
            entry("logs", isDir: true, size: 0, mode: "0755", mod: now - 10*min),
            entry("app", isDir: true, size: 0, mode: "0755", mod: now - 2*hour),
            entry("backups", isDir: true, size: 0, mode: "0750", mod: now - 3*day),
            entry(".ssh", isDir: true, size: 0, mode: "0700", mod: now - 30*day),
            entry(".bashrc", isDir: false, size: 1_200, mode: "0644", mod: now - 30*day),
            entry("app.tar.gz", isDir: false, size: 58_720_256, mode: "0644", mod: now - 25*min),
            entry("deploy.sh", isDir: false, size: 3_412, mode: "0755", mod: now - 1*hour),
            entry("docker-compose.yml", isDir: false, size: 2_880, mode: "0644", mod: now - 1*day),
            entry("README.md", isDir: false, size: 8_192, mode: "0644", mod: now - 5*day),
            entry("config.json", isDir: false, size: 512, mode: "0640", mod: now - 6*hour),
            entry("photo_2024.jpg", isDir: false, size: 4_200_000, mode: "0644", mod: now - 12*day),
            entry("demo.mp4", isDir: false, size: 156_000_000, mode: "0644", mod: now - 4*day),
            entry("presentation.pptx", isDir: false, size: 18_300_000, mode: "0644", mod: now - 7*day),
            entry("budget.xlsx", isDir: false, size: 92_000, mode: "0644", mod: now - 14*day),
            entry("song.mp3", isDir: false, size: 7_800_000, mode: "0644", mod: now - 20*day),
            entry("data.csv", isDir: false, size: 1_540_000, mode: "0644", mod: now - 8*hour),
            entry("system.log", isDir: false, size: 2_100_000, mode: "0644", mod: now - 5*min),
            entry("archive.zip", isDir: false, size: 312_000_000, mode: "0644", mod: now - 60*day),
            entry("main.go", isDir: false, size: 8_440, mode: "0644", mod: now - 40*min),
            entry("handler.py", isDir: false, size: 14_200, mode: "0644", mod: now - 2*hour),
            entry("config.toml", isDir: false, size: 1_140, mode: "0644", mod: now - 1*day),
        ]
        await store.set("/root", tencentRoot)

        let logs: [RemoteEntry] = [
            entry("nginx", isDir: true, size: 0, mode: "0755", mod: now - 20*min),
            entry("app", isDir: true, size: 0, mode: "0755", mod: now - 5*min),
            entry("access.log", isDir: false, size: 84_000_000, mode: "0644", mod: now - 2*min),
            entry("error.log", isDir: false, size: 12_000_000, mode: "0644", mod: now - 1*min),
            entry("slow.log", isDir: false, size: 1_200_000, mode: "0644", mod: now - 30*min),
            entry("rotation.log.1", isDir: false, size: 88_000_000, mode: "0644", mod: now - 1*day),
        ]
        await store.set("/root/logs", logs)

        let nginxLogs: [RemoteEntry] = [
            entry("access.log", isDir: false, size: 210_000_000, mode: "0644", mod: now - 30),
            entry("error.log", isDir: false, size: 4_800_000, mode: "0644", mod: now - 90),
            entry("ssl_access.log", isDir: false, size: 18_000_000, mode: "0644", mod: now - 120),
        ]
        await store.set("/root/logs/nginx", nginxLogs)

        let appDir: [RemoteEntry] = [
            entry("bin", isDir: true, size: 0, mode: "0755", mod: now - 1*hour),
            entry("conf", isDir: true, size: 0, mode: "0755", mod: now - 2*hour),
            entry("static", isDir: true, size: 0, mode: "0755", mod: now - 4*hour),
            entry("templates", isDir: true, size: 0, mode: "0755", mod: now - 4*hour),
            entry("release-notes.txt", isDir: false, size: 12_400, mode: "0644", mod: now - 1*hour),
            entry("version.json", isDir: false, size: 640, mode: "0644", mod: now - 1*hour),
        ]
        await store.set("/root/app", appDir)

        let etc: [RemoteEntry] = [
            entry("nginx", isDir: true, size: 0, mode: "0755", mod: now - 5*day),
            entry("systemd", isDir: true, size: 0, mode: "0755", mod: now - 5*day),
            entry("ssh", isDir: true, size: 0, mode: "0755", mod: now - 30*day),
            entry("hosts", isDir: false, size: 412, mode: "0644", mod: now - 5*day),
            entry("hostname", isDir: false, size: 18, mode: "0644", mod: now - 30*day),
        ]
        await store.set("/etc", etc)

        let home: [RemoteEntry] = [
            entry("projects", isDir: true, size: 0, mode: "0755", mod: now - 1*hour),
            entry(".cache", isDir: true, size: 0, mode: "0755", mod: now - 30*min),
            entry("script.sh", isDir: false, size: 1_200, mode: "0755", mod: now - 1*hour),
        ]
        await store.set("/", home)
        await store.set("/home/ubuntu", home)

        // GPU 机的 /data
        let data: [RemoteEntry] = [
            entry("checkpoints", isDir: true, size: 0, mode: "0755", mod: now - 10*min),
            entry("datasets", isDir: true, size: 0, mode: "0755", mod: now - 1*day),
            entry("tensorboard", isDir: true, size: 0, mode: "0755", mod: now - 2*hour),
            entry("train.log", isDir: false, size: 4_200_000, mode: "0644", mod: now - 1*min),
            entry("model_v3.pt", isDir: false, size: 1_400_000_000, mode: "0644", mod: now - 10*min),
            entry("model_v2.pt", isDir: false, size: 1_380_000_000, mode: "0644", mod: now - 2*day),
            entry("config.yaml", isDir: false, size: 2_400, mode: "0644", mod: now - 1*day),
            entry("metrics.csv", isDir: false, size: 88_000, mode: "0644", mod: now - 5*min),
        ]
        await store.set("/data", data)
        await store.set("/home/trainer", data)
    }

    private func entry(_ name: String, isDir: Bool, size: Int64, mode: String, mod: Date) -> RemoteEntry {
        let path = "/root/" + name
        return RemoteEntry(
            name: name, path: path, isDir: isDir, size: size,
            mode: mode, modTime: mod, owner: "root", group: "root"
        )
    }

    func connect(_ server: ServerConfig) async throws -> TransportMode {
        try await Task.sleep(nanoseconds: 400_000_000)
        if server.alias == "tokyo-server" {
            throw NSError(domain: "mock", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection refused"])
        }
        return .agent
    }

    func disconnect(_ serverID: UUID) async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func list(_ server: ServerConfig, path: String, showHidden: Bool) async throws -> [RemoteEntry] {
        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 220_000_000)
        let snapshot = await store.snapshot()
        var entries: [RemoteEntry]
        if let cached = snapshot[path] {
            entries = cached
        } else {
            // 未知路径返回空但合法
            entries = []
        }
        // 按目录优先、名字排序
        entries.sort { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if !showHidden {
            entries.removeAll { $0.name.hasPrefix(".") }
        }
        // 给条目补正 path：把基路径替换为当前 path，让面包屑能正确拼接
        let base = path.hasSuffix("/") ? path : path + "/"
        entries = entries.map { e in
            var c = e
            c.path = base + e.name
            return c
        }
        return entries
    }

    func stat(_ server: ServerConfig, path: String) async throws -> RemoteEntry {
        try await Task.sleep(nanoseconds: 100_000_000)
        let name = (path as NSString).lastPathComponent
        return RemoteEntry(
            name: name, path: path, isDir: false, size: 0,
            mode: "0644", modTime: Date()
        )
    }

    func makeDirectory(_ server: ServerConfig, path: String) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let new = RemoteEntry(
            name: name, path: path, isDir: true, size: 0,
            mode: "0755", modTime: Date(), owner: "root", group: "root"
        )
        await store.set(path, [])
        let snap = await store.snapshot()
        if var siblings = snap[parent] {
            siblings.append(new)
            await store.set(parent, siblings)
        } else {
            await store.set(parent, [new])
        }
    }

    func remove(_ server: ServerConfig, path: String, recursive: Bool) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        await store.remove(path)
        let parent = (path as NSString).deletingLastPathComponent
        let snap = await store.snapshot()
        if var siblings = snap[parent] {
            siblings.removeAll { $0.path == path }
            await store.set(parent, siblings)
        }
    }

    func move(_ server: ServerConfig, from: String, to: String) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        await store.rename(from: from, to: to)
    }

    func chmod(_ server: ServerConfig, path: String, mode: String) async throws {
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    func homeDirectory(_ server: ServerConfig) async throws -> String {
        try await Task.sleep(nanoseconds: 50_000_000)
        return server.defaultRemotePath ?? "/root"
    }

    func diskSpace(_ server: ServerConfig, path: String) async throws -> (total: Int64, free: Int64) {
        try await Task.sleep(nanoseconds: 80_000_000)
        return (total: 500_000_000_000, free: 120_000_000_000)
    }
}

// MARK: - MockTransferQueue

@MainActor
final class MockTransferQueue: ObservableObject, @unchecked Sendable {
    @Published var tasks: [TransferTask] = []
    var maxConcurrent: Int = 2
    private var tickTimer: Timer?
    private var taskStep: [UUID: Int64] = [:]

    init() {
        seed()
        startTicking()
    }

    deinit {
        tickTimer?.invalidate()
    }

    private func seed() {
        let now = Date()
        let tencentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let aliyunID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let transferring = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!,
            serverID: tencentID,
            direction: .upload,
            localURL: URL(fileURLWithPath: "/Users/me/Downloads/app.tar.gz"),
            remotePath: "/root/app.tar.gz",
            filename: "app.tar.gz",
            totalBytes: 58_720_256,
            transferredBytes: 48_000_000,
            state: .transferring,
            startedAt: now - 25,
            speed: 1_200_000
        )
        let downloading = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!,
            serverID: tencentID,
            direction: .download,
            localURL: URL(fileURLWithPath: "/Users/me/Downloads/access.log"),
            remotePath: "/root/logs/nginx/access.log",
            filename: "access.log",
            totalBytes: 210_000_000,
            transferredBytes: 35_000_000,
            state: .transferring,
            startedAt: now - 12,
            speed: 6_000_000
        )
        let queued1 = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!,
            serverID: tencentID,
            direction: .upload,
            localURL: URL(fileURLWithPath: "/Users/me/Movies/demo.mp4"),
            remotePath: "/root/demo.mp4",
            filename: "demo.mp4",
            totalBytes: 156_000_000,
            state: .queued
        )
        let queued2 = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000004")!,
            serverID: tencentID,
            direction: .download,
            localURL: URL(fileURLWithPath: "/Users/me/Downloads/model_v3.pt"),
            remotePath: "/data/model_v3.pt",
            filename: "model_v3.pt",
            totalBytes: 1_400_000_000,
            state: .queued
        )
        let verifying = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000005")!,
            serverID: tencentID,
            direction: .upload,
            localURL: URL(fileURLWithPath: "/Users/me/Documents/budget.xlsx"),
            remotePath: "/root/budget.xlsx",
            filename: "budget.xlsx",
            totalBytes: 92_000,
            transferredBytes: 92_000,
            state: .verifying,
            startedAt: now - 8
        )
        let completed = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000006")!,
            serverID: tencentID,
            direction: .download,
            localURL: URL(fileURLWithPath: "/Users/me/Downloads/system.log"),
            remotePath: "/root/system.log",
            filename: "system.log",
            totalBytes: 2_100_000,
            transferredBytes: 2_100_000,
            state: .completed,
            startedAt: now - 300,
            finishedAt: now - 280,
            speed: 0
        )
        let skipped = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000007")!,
            serverID: aliyunID,
            direction: .upload,
            localURL: URL(fileURLWithPath: "/Users/me/Documents/README.md"),
            remotePath: "/root/README.md",
            filename: "README.md",
            totalBytes: 8_192,
            transferredBytes: 8_192,
            state: .skipped,
            startedAt: now - 600,
            finishedAt: now - 599,
            speed: 0
        )
        let paused = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000008")!,
            serverID: tencentID,
            direction: .download,
            localURL: URL(fileURLWithPath: "/Users/me/Downloads/song.mp3"),
            remotePath: "/root/song.mp3",
            filename: "song.mp3",
            totalBytes: 7_800_000,
            transferredBytes: 2_400_000,
            state: .paused,
            startedAt: now - 1200,
            speed: 0
        )
        let failed = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000009")!,
            serverID: tencentID,
            direction: .upload,
            localURL: URL(fileURLWithPath: "/Users/me/Desktop/photo.jpg"),
            remotePath: "/root/photo_2024.jpg",
            filename: "photo_2024.jpg",
            totalBytes: 4_200_000,
            transferredBytes: 1_800_000,
            state: .failed(TransferError(code: "EIO", message: "远端写入失败：磁盘空间不足", retryable: true)),
            startedAt: now - 900,
            speed: 0
        )
        let cancelled = TransferTask(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000010")!,
            serverID: aliyunID,
            direction: .upload,
            localURL: URL(fileURLWithPath: "/Users/me/Downloads/presentation.pptx"),
            remotePath: "/root/presentation.pptx",
            filename: "presentation.pptx",
            totalBytes: 18_300_000,
            transferredBytes: 3_000_000,
            state: .cancelled,
            startedAt: now - 2000,
            finishedAt: now - 1990,
            speed: 0
        )

        tasks = [
            transferring, downloading, queued1, queued2,
            verifying, completed, skipped, paused, failed, cancelled
        ]
        taskStep[transferring.id] = 48_000_000
        taskStep[downloading.id] = 35_000_000
    }

    private func startTicking() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func tick() {
        var didChange = false
        for i in tasks.indices {
            let task = tasks[i]
            guard case .transferring = task.state else { continue }
            let step = taskStep[task.id] ?? task.transferredBytes
            let inc = Int64(task.speed * 1.0)
            let next = min(step + inc, task.totalBytes)
            taskStep[task.id] = next
            tasks[i].transferredBytes = next
            if next >= task.totalBytes {
                tasks[i].state = .verifying
                tasks[i].speed = 0
            }
            didChange = true
        }
        // 验证中的任务 3 秒后完成
        for i in tasks.indices {
            if case .verifying = tasks[i].state {
                if let started = tasks[i].startedAt {
                    if Date().timeIntervalSince(started) > 30 {
                        tasks[i].state = .completed
                        tasks[i].finishedAt = Date()
                        didChange = true
                    }
                }
            }
        }
        if didChange {
            objectWillChange.send()
        }
    }
}

extension MockTransferQueue: TransferQueueService {
    func enqueueUpload(
        localURLs: [URL],
        to server: ServerConfig,
        remoteDir: String,
        policy: ConflictPolicy
    ) {
        for url in localURLs {
            let name = url.lastPathComponent
            let task = TransferTask(
                serverID: server.id,
                direction: .upload,
                localURL: url,
                remotePath: (remoteDir as NSString).appendingPathComponent(name),
                filename: name,
                totalBytes: Int64.random(in: 100_000...50_000_000),
                state: .queued,
                speed: 0
            )
            tasks.insert(task, at: 0)
            // 1 秒后转为传输中
            let id = task.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self else { return }
                if let idx = self.tasks.firstIndex(where: { $0.id == id }) {
                    self.tasks[idx].state = .transferring
                    self.tasks[idx].startedAt = Date()
                    self.tasks[idx].speed = Double.random(in: 800_000...3_000_000)
                    self.taskStep[id] = 0
                    self.objectWillChange.send()
                }
            }
        }
        objectWillChange.send()
    }

    func enqueueDownload(
        entries: [RemoteEntry],
        from server: ServerConfig,
        localDir: URL,
        policy: ConflictPolicy
    ) {
        for e in entries {
            let task = TransferTask(
                serverID: server.id,
                direction: .download,
                localURL: localDir.appendingPathComponent(e.name),
                remotePath: e.path,
                filename: e.name,
                totalBytes: e.isDir ? Int64.random(in: 1_000_000...100_000_000) : e.size,
                state: .queued,
                speed: 0
            )
            tasks.insert(task, at: 0)
            let id = task.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self else { return }
                if let idx = self.tasks.firstIndex(where: { $0.id == id }) {
                    self.tasks[idx].state = .transferring
                    self.tasks[idx].startedAt = Date()
                    self.tasks[idx].speed = Double.random(in: 800_000...6_000_000)
                    self.taskStep[id] = 0
                    self.objectWillChange.send()
                }
            }
        }
        objectWillChange.send()
    }

    func pause(_ taskID: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[idx].state = .paused
            tasks[idx].speed = 0
            objectWillChange.send()
        }
    }

    func resume(_ taskID: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[idx].state = .transferring
            tasks[idx].speed = Double.random(in: 800_000...3_000_000)
            taskStep[taskID] = tasks[idx].transferredBytes
            objectWillChange.send()
        }
    }

    func cancel(_ taskID: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[idx].state = .cancelled
            tasks[idx].speed = 0
            tasks[idx].finishedAt = Date()
            objectWillChange.send()
        }
    }

    func cancelAll() {
        let now = Date()
        for idx in tasks.indices {
            switch tasks[idx].state {
            case .queued, .preparing, .transferring, .verifying, .awaitingDecision, .paused:
                tasks[idx].state = .cancelled
                tasks[idx].speed = 0
                tasks[idx].finishedAt = now
            case .completed, .skipped, .failed, .cancelled:
                break
            }
        }
        objectWillChange.send()
    }

    func retry(_ taskID: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[idx].state = .queued
            tasks[idx].speed = 0
            let id = taskID
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self else { return }
                if let idx = self.tasks.firstIndex(where: { $0.id == id }) {
                    self.tasks[idx].state = .transferring
                    self.tasks[idx].speed = Double.random(in: 800_000...3_000_000)
                    self.taskStep[id] = self.tasks[idx].transferredBytes
                    self.objectWillChange.send()
                }
            }
            objectWillChange.send()
        }
    }

    func clearFinished() {
        tasks.removeAll { t in
            switch t.state {
            case .completed, .skipped, .cancelled: return true
            default: return false
            }
        }
        objectWillChange.send()
    }
}
