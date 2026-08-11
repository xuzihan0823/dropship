import Foundation

@MainActor
final class TransferQueue: TransferQueueService, ObservableObject {
    @Published private(set) var tasks: [TransferTask] = []
    var maxConcurrent: Int = 2 {
        didSet {
            if maxConcurrent < 1 { maxConcurrent = 1 }
            startPending()
        }
    }

    private let service: FileTransport
    private var servers: [UUID: ServerConfig] = [:]
    private var policies: [UUID: ConflictPolicy] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var cancellations: [UUID: TransferCancellation] = [:]
    private var speedSamples: [UUID: [(Date, Int64)]] = [:]
    private var automaticRetries: [UUID: Int] = [:]

    init(service: FileTransport = RemoteFileServiceImpl()) {
        self.service = service
    }

    func enqueueUpload(
        localURLs: [URL],
        to server: ServerConfig,
        remoteDir: String,
        policy: ConflictPolicy
    ) {
        servers[server.id] = server
        for url in localURLs {
            enqueueUploadURL(url, server: server, remoteDir: remoteDir, policy: policy)
        }
        startPending()
    }

    func enqueueDownload(
        entries: [RemoteEntry],
        from server: ServerConfig,
        localDir: URL,
        policy: ConflictPolicy
    ) {
        servers[server.id] = server
        Task {
            for entry in entries {
                await expandDownload(
                    entry,
                    server: server,
                    localURL: localDir.appendingPathComponent(entry.name),
                    policy: policy
                )
            }
            startPending()
        }
    }

    func pause(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        cancellations[taskID]?.cancel()
        jobs[taskID]?.cancel()
        tasks[index].state = .paused
    }

    func resume(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              tasks[index].state == .paused else { return }
        tasks[index].state = .queued
        startPending()
    }

    func cancel(_ taskID: UUID) {
        cancellations[taskID]?.cancel()
        jobs[taskID]?.cancel()
        if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[index].state = .cancelled
            tasks[index].finishedAt = Date()
        }
    }

    func retry(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              case .failed = tasks[index].state else { return }
        tasks[index].state = .queued
        tasks[index].finishedAt = nil
        startPending()
    }

    /// 从列表中移除单个已结束的任务（UI 上每行的「移除」）。
    /// 仍在进行的任务需先 cancel，避免移除后后台仍在传输。
    func removeTask(_ taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        switch task.state {
        case .transferring, .preparing, .verifying:
            cancel(taskID)
        default:
            break
        }
        tasks.removeAll { $0.id == taskID }
    }

    func clearFinished() {
        tasks.removeAll {
            switch $0.state {
            case .completed, .skipped, .cancelled:
                return true
            default:
                return false
            }
        }
    }

    private func enqueueUploadURL(
        _ url: URL,
        server: ServerConfig,
        remoteDir: String,
        policy: ConflictPolicy
    ) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            let childRemoteDirectory = joinRemote(remoteDir, url.lastPathComponent)
            let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
            )
            for child in children ?? [] {
                enqueueUploadURL(
                    child,
                    server: server,
                    remoteDir: childRemoteDirectory,
                    policy: policy
                )
            }
            return
        }

        let task = TransferTask(
            serverID: server.id,
            direction: .upload,
            localURL: url,
            remotePath: joinRemote(remoteDir, url.lastPathComponent),
            filename: url.lastPathComponent,
            totalBytes: Int64(values?.fileSize ?? 0)
        )
        tasks.append(task)
        policies[task.id] = policy
    }

    private func expandDownload(
        _ entry: RemoteEntry,
        server: ServerConfig,
        localURL: URL,
        policy: ConflictPolicy
    ) async {
        if entry.isDir {
            do {
                let children = try await service.list(
                    server,
                    path: entry.path,
                    showHidden: true
                )
                for child in children {
                    await expandDownload(
                        child,
                        server: server,
                        localURL: localURL.appendingPathComponent(child.name),
                        policy: policy
                    )
                }
            } catch {
                let marker = TransferTask(
                    serverID: server.id,
                    direction: .download,
                    localURL: localURL,
                    remotePath: entry.path,
                    filename: entry.name,
                    state: .failed(transferError(from: error))
                )
                tasks.append(marker)
            }
            return
        }

        let task = TransferTask(
            serverID: server.id,
            direction: .download,
            localURL: localURL,
            remotePath: entry.path,
            filename: entry.name,
            totalBytes: entry.size
        )
        tasks.append(task)
        policies[task.id] = policy
    }

    private func startPending() {
        removeFinishedJobs()
        while jobs.count < maxConcurrent,
              let index = tasks.firstIndex(where: { $0.state == .queued }) {
            let transfer = tasks[index]
            guard let server = servers[transfer.serverID] else {
                tasks[index].state = .failed(TransferError(
                    code: "EINTERNAL",
                    message: "Server configuration is unavailable"
                ))
                continue
            }
            let cancellation = TransferCancellation()
            cancellations[transfer.id] = cancellation
            tasks[index].state = .preparing
            tasks[index].startedAt = tasks[index].startedAt ?? Date()
            jobs[transfer.id] = Task { [weak self] in
                await self?.run(
                    transferID: transfer.id,
                    server: server,
                    cancellation: cancellation
                )
            }
        }
    }

    private func run(
        transferID: UUID,
        server: ServerConfig,
        cancellation: TransferCancellation
    ) async {
        guard var transfer = tasks.first(where: { $0.id == transferID }) else { return }
        do {
            let policy = policies[transferID] ?? .ask
            transfer = try await resolveConflict(transfer, server: server, policy: policy)
            replaceTask(transfer)
            guard transfer.state != .skipped else {
                finish(transferID, state: .skipped)
                completeJob(transferID)
                return
            }

            if transfer.direction == .upload,
               let remoteHash = try await service.hash(server, path: transfer.remotePath),
               remoteHash.1 == transfer.totalBytes,
               let localHash = try localSHA256(transfer.localURL),
               localHash == remoteHash.0 {
                finish(transferID, state: .skipped)
                completeJob(transferID)
                return
            }

            setState(transferID, .transferring)
            let compress = shouldCompress(transfer.filename)
            let offset = transfer.transferredBytes
            let progress: @Sendable (Int64) -> Void = { [weak self] bytes in
                Task { @MainActor in self?.updateProgress(transferID, bytes: bytes) }
            }

            if transfer.direction == .upload {
                try await service.upload(
                    server,
                    local: transfer.localURL,
                    remote: transfer.remotePath,
                    offset: offset,
                    compress: compress,
                    cancellation: cancellation,
                    progress: progress
                )
            } else {
                try await service.download(
                    server,
                    remote: transfer.remotePath,
                    local: transfer.localURL,
                    offset: offset,
                    compress: compress,
                    cancellation: cancellation,
                    progress: progress
                )
            }
            finish(transferID, state: .completed)
        } catch {
            if let current = tasks.first(where: { $0.id == transferID }),
               current.state == .paused || current.state == .cancelled {
                completeJob(transferID)
                return
            }
            let mappedError = transferError(from: error)
            if mappedError.code == "ESIZE", automaticRetries[transferID, default: 0] < 3 {
                automaticRetries[transferID, default: 0] += 1
                if let index = tasks.firstIndex(where: { $0.id == transferID }) {
                    tasks[index].transferredBytes = await resumableRemoteOffset(
                        for: tasks[index],
                        server: server
                    )
                    tasks[index].state = .queued
                }
                completeJob(transferID)
                return
            }
            finish(transferID, state: .failed(mappedError))
        }
        completeJob(transferID)
    }

    private func resumableRemoteOffset(
        for task: TransferTask,
        server: ServerConfig
    ) async -> Int64 {
        guard task.direction == .upload else { return task.transferredBytes }
        let partPath = task.remotePath + ".dropship-part"
        guard let entry = try? await service.stat(server, path: partPath) else { return 0 }
        return min(entry.size, task.totalBytes)
    }

    private func resolveConflict(
        _ task: TransferTask,
        server: ServerConfig,
        policy: ConflictPolicy
    ) async throws -> TransferTask {
        var resolved = task
        let exists: Bool
        if task.direction == .upload {
            exists = (try? await service.stat(server, path: task.remotePath)) != nil
        } else {
            exists = FileManager.default.fileExists(atPath: task.localURL.path)
        }
        guard exists else { return resolved }

        switch policy {
        case .overwrite:
            if task.direction == .download {
                try? FileManager.default.removeItem(at: task.localURL)
                resolved.transferredBytes = 0
            }
        case .skip:
            resolved.state = .skipped
        case .ask:
            throw TransferError(code: "EEXIST", message: "Destination already exists")
        case .rename:
            if task.direction == .upload {
                resolved = try await renamedRemoteTask(task, server: server)
            } else {
                resolved = renamedLocalTask(task)
            }
        }
        return resolved
    }

    private func renamedRemoteTask(
        _ task: TransferTask,
        server: ServerConfig
    ) async throws -> TransferTask {
        var result = task
        let path = NSString(string: task.remotePath)
        let directory = path.deletingLastPathComponent
        let extensionName = path.pathExtension
        let base = path.deletingPathExtension
        for suffix in 1...9_999 {
            let filename = extensionName.isEmpty
                ? "\(base)-\(suffix)"
                : "\(base)-\(suffix).\(extensionName)"
            let candidate = joinRemote(directory, filename)
            if (try? await service.stat(server, path: candidate)) == nil {
                result = TransferTask(
                    id: task.id,
                    serverID: task.serverID,
                    direction: task.direction,
                    localURL: task.localURL,
                    remotePath: candidate,
                    filename: NSString(string: candidate).lastPathComponent,
                    totalBytes: task.totalBytes,
                    transferredBytes: task.transferredBytes,
                    state: task.state,
                    startedAt: task.startedAt,
                    finishedAt: task.finishedAt,
                    speed: task.speed
                )
                return result
            }
        }
        throw TransferError(code: "EEXIST", message: "No available renamed destination")
    }

    private func renamedLocalTask(_ task: TransferTask) -> TransferTask {
        let directory = task.localURL.deletingLastPathComponent()
        let extensionName = task.localURL.pathExtension
        let base = task.localURL.deletingPathExtension().lastPathComponent
        var candidate = task.localURL
        for suffix in 1...9_999 {
            let filename = extensionName.isEmpty
                ? "\(base)-\(suffix)"
                : "\(base)-\(suffix).\(extensionName)"
            candidate = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: candidate.path) { break }
        }
        return TransferTask(
            id: task.id,
            serverID: task.serverID,
            direction: task.direction,
            localURL: candidate,
            remotePath: task.remotePath,
            filename: candidate.lastPathComponent,
            totalBytes: task.totalBytes,
            transferredBytes: task.transferredBytes,
            state: task.state,
            startedAt: task.startedAt,
            finishedAt: task.finishedAt,
            speed: task.speed
        )
    }

    private func shouldCompress(_ filename: String) -> Bool {
        let compressedExtensions: Set<String> = [
            "zip", "gz", "bz2", "xz", "7z", "rar", "zst",
            "jpg", "jpeg", "png", "gif", "webp", "avif", "heic",
            "mp4", "mov", "mkv", "avi", "mp3", "aac", "flac", "pdf"
        ]
        return !compressedExtensions.contains(
            NSString(string: filename).pathExtension.lowercased()
        )
    }

    private func localSHA256(_ url: URL) throws -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \ .isWhitespace)
            .first
            .map(String.init)
    }

    private func updateProgress(_ taskID: UUID, bytes: Int64) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].transferredBytes = bytes
        let now = Date()
        var samples = speedSamples[taskID] ?? []
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.0) > 5 }
        speedSamples[taskID] = samples
        if let first = samples.first {
            let duration = now.timeIntervalSince(first.0)
            if duration > 0.2 {
                tasks[index].speed = Double(bytes - first.1) / duration
            }
        }
    }

    private func replaceTask(_ task: TransferTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
    }

    private func setState(_ taskID: UUID, _ state: TransferState) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].state = state
    }

    private func finish(_ taskID: UUID, state: TransferState) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].state = state
        tasks[index].finishedAt = Date()
        tasks[index].speed = 0
    }

    private func completeJob(_ taskID: UUID) {
        jobs.removeValue(forKey: taskID)
        cancellations.removeValue(forKey: taskID)
        speedSamples.removeValue(forKey: taskID)
        if let task = tasks.first(where: { $0.id == taskID }) {
            switch task.state {
            case .completed, .skipped, .cancelled:
                automaticRetries.removeValue(forKey: taskID)
            default:
                break
            }
        }
        startPending()
    }

    private func removeFinishedJobs() {
        jobs = jobs.filter { taskID, _ in
            guard let task = tasks.first(where: { $0.id == taskID }) else { return false }
            switch task.state {
            case .completed, .skipped, .failed, .cancelled, .paused:
                return false
            default:
                return true
            }
        }
    }

    private func joinRemote(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/\(name)" }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

final class FilePromiseResolverImpl: FilePromiseResolver {
    private let service: FileTransport

    init(service: FileTransport = RemoteFileServiceImpl()) {
        self.service = service
    }

    func fulfillPromise(
        entry: RemoteEntry,
        server: ServerConfig,
        destination: URL,
        completion: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                try await service.download(
                    server,
                    remote: entry.path,
                    local: destination,
                    offset: 0,
                    compress: false,
                    cancellation: TransferCancellation(),
                    progress: { _ in }
                )
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}
