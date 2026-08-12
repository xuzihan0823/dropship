import Foundation
import Combine

@MainActor
final class TransferQueue: TransferQueueService, ObservableObject {
    /// The complete task history remains available through the service contract.
    /// It is deliberately not @Published: progress updates are throttled below so
    /// a 30k-file queue does not force SwiftUI to diff the full array per callback.
    private(set) var tasks: [TransferTask] = []

    /// UI-facing projection. The queue can retain an arbitrary number of tasks,
    /// while the panel only renders a bounded number of useful rows.
    private(set) var visibleTasks: [TransferTask] = []
    private(set) var activeCount = 0
    private(set) var completedCount = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var transferredBytes: Int64 = 0
    private(set) var finishedTransferRevision = 0
    private(set) var finishedCount = 0
    private(set) var cancellableCount = 0
    private(set) var taskCount = 0
    var hasCancellableTasks: Bool { cancellableCount > 0 || !activeEnqueueIDs.isEmpty }
    /// A single published revision drives the UI snapshot. All other queue
    /// aggregates are plain stored properties updated before this changes.
    @Published private(set) var snapshotRevision = 0

    private let visibleTaskLimit = 200
    private var visibleTaskIDs: [UUID] = []
    private var visibleTaskIDSet: Set<UUID> = []
    private var taskIndexes: [UUID: Int] = [:]
    private var pendingTaskIDs: [UUID] = []
    private var pendingCursor = 0
    private var pendingTaskIDSet: Set<UUID> = []
    private var pendingProgressPublish = false
    private var progressPublishTask: Task<Void, Never>?
    private var lastSnapshotPublish = Date.distantPast
    private nonisolated let progressCoalescer = TransferProgressCoalescer()
    private var enqueueJobs: [UUID: Task<Void, Never>] = [:]
    private var activeEnqueueIDs: Set<UUID> = []
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
    private var preparedRemoteDirectories: Set<RemoteDirectoryKey> = []
    private var remoteDirectoryJobs: [RemoteDirectoryKey: Task<Void, Error>] = [:]

    init(service: FileTransport = RemoteFileServiceImpl()) {
        self.service = service
    }

    deinit {
        progressPublishTask?.cancel()
    }

    func enqueueUpload(
        localURLs: [URL],
        to server: ServerConfig,
        remoteDir: String,
        policy: ConflictPolicy
    ) {
        servers[server.id] = server
        let queue = self
        let enqueueID = UUID()
        activeEnqueueIDs.insert(enqueueID)
        requestSnapshot(immediate: true)
        enqueueJobs[enqueueID] = Task.detached {
            defer {
                Task { @MainActor in queue.finishEnqueue(enqueueID) }
            }
            var batch: [TransferTask] = []
            let batchSize = 250

            func flush() async {
                guard !Task.isCancelled, !batch.isEmpty else { return }
                let pending = batch
                batch.removeAll(keepingCapacity: true)
                await MainActor.run {
                    guard queue.activeEnqueueIDs.contains(enqueueID) else { return }
                    queue.appendTasks(pending, policies: Dictionary(uniqueKeysWithValues: pending.map { ($0.id, policy) }))
                    queue.startPending()
                }
            }

            func walk(_ url: URL, remoteDirectory: String) async {
                guard !Task.isCancelled else { return }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    let childRemoteDirectory = Self.joinRemote(remoteDirectory, url.lastPathComponent)
                    let children = try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                        options: [.skipsPackageDescendants]
                    )
                    for child in children ?? [] {
                        guard !Task.isCancelled else { return }
                        await walk(child, remoteDirectory: childRemoteDirectory)
                    }
                    return
                }

                let task = TransferTask(
                    serverID: server.id,
                    direction: .upload,
                    localURL: url,
                    remotePath: Self.joinRemote(remoteDirectory, url.lastPathComponent),
                    filename: url.lastPathComponent,
                    totalBytes: Int64(values?.fileSize ?? 0)
                )
                batch.append(task)
                if batch.count >= batchSize { await flush() }
            }

            for url in localURLs {
                guard !Task.isCancelled else { return }
                await walk(url, remoteDirectory: remoteDir)
            }
            await flush()
        }
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
            publishSnapshot()
            startPending()
        }
    }

    func pause(_ taskID: UUID) {
        guard let index = taskIndexes[taskID] else { return }
        cancellations[taskID]?.cancel()
        jobs[taskID]?.cancel()
        updateTask(at: index) { $0.state = .paused }
        requestSnapshot(immediate: true)
    }

    func resume(_ taskID: UUID) {
        guard let index = taskIndexes[taskID],
              tasks[index].state == .paused else { return }
        updateTask(at: index) { $0.state = .queued }
        requestSnapshot(immediate: true)
        startPending()
    }

    func cancel(_ taskID: UUID) {
        cancellations[taskID]?.cancel()
        jobs[taskID]?.cancel()
        if let index = taskIndexes[taskID] {
            updateTask(at: index) {
                $0.state = .cancelled
                $0.finishedAt = Date()
            }
            requestSnapshot(immediate: true)
        }
    }

    func cancelAll() {
        activeEnqueueIDs.removeAll(keepingCapacity: true)
        for job in enqueueJobs.values { job.cancel() }
        enqueueJobs.removeAll()
        for cancellation in cancellations.values { cancellation.cancel() }
        for job in jobs.values { job.cancel() }

        let now = Date()
        for index in tasks.indices {
            switch tasks[index].state {
            case .queued, .preparing, .transferring, .verifying, .paused:
                updateTask(at: index) {
                    $0.state = .cancelled
                    $0.finishedAt = now
                    $0.speed = 0
                }
            case .completed, .skipped, .failed, .cancelled:
                break
            }
        }
        pendingTaskIDs.removeAll(keepingCapacity: true)
        pendingTaskIDSet.removeAll(keepingCapacity: true)
        pendingCursor = 0
        preparedRemoteDirectories.removeAll(keepingCapacity: true)
        for job in remoteDirectoryJobs.values { job.cancel() }
        remoteDirectoryJobs.removeAll(keepingCapacity: true)
        requestSnapshot(immediate: true)
    }

    private func finishEnqueue(_ enqueueID: UUID) {
        activeEnqueueIDs.remove(enqueueID)
        enqueueJobs.removeValue(forKey: enqueueID)
        requestSnapshot(immediate: true)
    }

    func retry(_ taskID: UUID) {
        guard let index = taskIndexes[taskID],
              case .failed = tasks[index].state else { return }
        updateTask(at: index) {
            $0.state = .queued
            $0.finishedAt = nil
        }
        requestSnapshot(immediate: true)
        startPending()
    }

    /// 从列表中移除单个已结束的任务（UI 上每行的「移除」）。
    /// 仍在进行的任务需先 cancel，避免移除后后台仍在传输。
    func removeTask(_ taskID: UUID) {
        guard let index = taskIndexes[taskID] else { return }
        let task = tasks[index]
        switch task.state {
        case .transferring, .preparing, .verifying:
            cancel(taskID)
        default:
            break
        }
        removeTask(at: index)
    }

    func clearFinished() {
        let removedIDs = Set(tasks.lazy.filter { self.isFinished($0.state) }.map(\.id))
        guard !removedIDs.isEmpty else { return }

        tasks.removeAll { removedIDs.contains($0.id) }
        for taskID in removedIDs {
            policies.removeValue(forKey: taskID)
            pendingTaskIDSet.remove(taskID)
            visibleTaskIDSet.remove(taskID)
        }
        visibleTaskIDs.removeAll { removedIDs.contains($0) }
        rebuildIndexesAndSummary()
        publishSnapshot()
    }

    private func appendTasks(
        _ newTasks: [TransferTask],
        policies newPolicies: [UUID: ConflictPolicy],
        publish: Bool = true
    ) {
        guard !newTasks.isEmpty else { return }
        for task in newTasks {
            let index = tasks.count
            tasks.append(task)
            taskIndexes[task.id] = index
            if let policy = newPolicies[task.id] { policies[task.id] = policy }
            applyTaskDelta(from: nil, to: task)
            if task.state == .queued { enqueuePending(task.id) }
            refreshVisibleTask(task.id)
        }
        taskCount = tasks.count
        if publish { requestSnapshot() }
    }

    private func appendTask(_ task: TransferTask, publish: Bool = true) {
        appendTasks([task], policies: [:], publish: publish)
    }

    private func updateTask(at index: Int, _ mutate: (inout TransferTask) -> Void) {
        guard tasks.indices.contains(index) else { return }
        let oldTask = tasks[index]
        var newTask = oldTask
        mutate(&newTask)
        tasks[index] = newTask
        applyTaskDelta(from: oldTask, to: newTask)
        if newTask.state == .queued { enqueuePending(newTask.id) }
        refreshVisibleTask(newTask.id)
    }

    private func applyTaskDelta(from oldTask: TransferTask?, to newTask: TransferTask?) {
        if let oldTask {
            totalBytes -= oldTask.totalBytes
            transferredBytes -= oldTask.transferredBytes
            if isActive(oldTask.state) { activeCount -= 1 }
            if isCompleted(oldTask.state) { completedCount -= 1 }
            if isFinished(oldTask.state) { finishedCount -= 1 }
            if isCancellable(oldTask.state) { cancellableCount -= 1 }
        }
        if let newTask {
            totalBytes += newTask.totalBytes
            transferredBytes += newTask.transferredBytes
            if isActive(newTask.state) { activeCount += 1 }
            if isCompleted(newTask.state) { completedCount += 1 }
            if isFinished(newTask.state) { finishedCount += 1 }
            if isCancellable(newTask.state) { cancellableCount += 1 }
            if isCompleted(newTask.state), oldTask.map({ !isCompleted($0.state) }) ?? true {
                finishedTransferRevision &+= 1
            }
        }
    }

    private func refreshVisibleTask(_ taskID: UUID) {
        guard let index = taskIndexes[taskID], tasks.indices.contains(index) else { return }
        let task = tasks[index]
        let shouldInclude = visibleTaskIDSet.contains(taskID)
            || visibleTaskIDs.count < visibleTaskLimit
            || isActive(task.state)
            || isFailed(task.state)
            || isCompleted(task.state)
        if shouldInclude && visibleTaskIDSet.insert(taskID).inserted {
            visibleTaskIDs.append(taskID)
        }
        guard visibleTaskIDs.count > visibleTaskLimit else { return }
        while visibleTaskIDs.count > visibleTaskLimit {
            guard let removable = visibleTaskIDs.firstIndex(where: { id in
                guard let removableIndex = taskIndexes[id], tasks.indices.contains(removableIndex) else { return true }
                return !isActive(tasks[removableIndex].state)
            }) else { break }
            visibleTaskIDSet.remove(visibleTaskIDs.remove(at: removable))
        }
    }

    private func publishSnapshot() {
        visibleTasks = visibleTaskIDs.compactMap {
            guard let index = taskIndexes[$0], tasks.indices.contains(index) else { return nil }
            return tasks[index]
        }
        taskCount = tasks.count
        snapshotRevision &+= 1
        lastSnapshotPublish = Date()
    }

    private func requestSnapshot(immediate: Bool = false) {
        if immediate {
            pendingProgressPublish = false
            progressPublishTask?.cancel()
            progressPublishTask = nil
            publishSnapshot()
            return
        }
        guard !pendingProgressPublish else { return }
        let delay = max(0, 0.1 - Date().timeIntervalSince(lastSnapshotPublish))
        pendingProgressPublish = true
        if delay == 0 {
            pendingProgressPublish = false
            publishSnapshot()
            return
        }
        progressPublishTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingProgressPublish = false
            self.publishSnapshot()
        }
    }

    private func removeTask(at index: Int) {
        guard tasks.indices.contains(index) else { return }
        let removed = tasks.remove(at: index)
        applyTaskDelta(from: removed, to: nil)
        taskIndexes.removeValue(forKey: removed.id)
        policies.removeValue(forKey: removed.id)
        pendingTaskIDSet.remove(removed.id)
        visibleTaskIDSet.remove(removed.id)
        visibleTaskIDs.removeAll { $0 == removed.id }
        for shiftedIndex in index..<tasks.count {
            taskIndexes[tasks[shiftedIndex].id] = shiftedIndex
        }
        requestSnapshot(immediate: true)
    }

    private func rebuildIndexesAndSummary() {
        taskIndexes.removeAll(keepingCapacity: true)
        activeCount = 0
        completedCount = 0
        finishedCount = 0
        cancellableCount = 0
        totalBytes = 0
        transferredBytes = 0
        for (index, task) in tasks.enumerated() {
            taskIndexes[task.id] = index
            totalBytes += task.totalBytes
            transferredBytes += task.transferredBytes
            if isActive(task.state) { activeCount += 1 }
            if isCompleted(task.state) { completedCount += 1 }
            if isFinished(task.state) { finishedCount += 1 }
            if isCancellable(task.state) { cancellableCount += 1 }
        }
        taskCount = tasks.count
    }

    private func isActive(_ state: TransferState) -> Bool {
        switch state {
        case .transferring, .preparing, .verifying: return true
        default: return false
        }
    }

    private func isCompleted(_ state: TransferState) -> Bool {
        switch state {
        case .completed, .skipped: return true
        default: return false
        }
    }

    private func isFinished(_ state: TransferState) -> Bool {
        switch state {
        case .completed, .skipped, .cancelled: return true
        default: return false
        }
    }

    private func isFailed(_ state: TransferState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func isCancellable(_ state: TransferState) -> Bool {
        switch state {
        case .queued, .preparing, .transferring, .verifying, .paused: return true
        case .completed, .skipped, .failed, .cancelled: return false
        }
    }

    private func enqueuePending(_ taskID: UUID) {
        guard pendingTaskIDSet.insert(taskID).inserted else { return }
        pendingTaskIDs.append(taskID)
    }

    private func nextPendingTaskID() -> UUID? {
        while pendingCursor < pendingTaskIDs.count {
            let taskID = pendingTaskIDs[pendingCursor]
            pendingCursor += 1
            guard pendingTaskIDSet.remove(taskID) != nil else { continue }
            if pendingCursor > 1024, pendingCursor * 2 > pendingTaskIDs.count {
                pendingTaskIDs.removeFirst(pendingCursor)
                pendingCursor = 0
            }
            return taskID
        }
        pendingTaskIDs.removeAll(keepingCapacity: true)
        pendingCursor = 0
        return nil
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
                appendTask(marker, publish: false)
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
        appendTask(task, publish: false)
        policies[task.id] = policy
    }

    private func startPending() {
        removeFinishedJobs()
        while jobs.count < maxConcurrent {
            guard let transferID = nextPendingTaskID() else { break }
            guard let index = taskIndexes[transferID], tasks[index].state == .queued else { continue }
            let transfer = tasks[index]
            guard let server = servers[transfer.serverID] else {
                updateTask(at: index) { $0.state = .failed(TransferError(
                    code: "EINTERNAL",
                    message: "Server configuration is unavailable"
                )) }
                continue
            }
            let cancellation = TransferCancellation()
            cancellations[transfer.id] = cancellation
            updateTask(at: index) {
                $0.state = .preparing
                $0.startedAt = $0.startedAt ?? Date()
            }
            jobs[transfer.id] = Task { [weak self] in
                await self?.run(
                    transferID: transfer.id,
                    server: server,
                    cancellation: cancellation
                )
            }
        }
        requestSnapshot()
    }

    private func run(
        transferID: UUID,
        server: ServerConfig,
        cancellation: TransferCancellation
    ) async {
        guard let transferIndex = taskIndexes[transferID] else { return }
        var transfer = tasks[transferIndex]
        do {
            if transfer.direction == .upload {
                try await ensureRemoteParentDirectory(for: transfer, server: server)
            }
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
            // `--compress gzip` describes the bytes carried over SSH. The runner
            // currently streams raw file bytes, so advertising gzip makes the
            // agent reject ordinary files while pre-compressed files appear fine.
            // Keep transport compression off until both upload and download have
            // matching streaming gzip encode/decode support.
            let compress = false
            let offset = transfer.transferredBytes
            let progress: @Sendable (Int64) -> Void = { [weak self] bytes in
                guard let self else { return }
                self.progressCoalescer.submit(taskID: transferID, bytes: bytes) { [weak self] latestBytes in
                    Task { @MainActor in self?.updateProgress(transferID, bytes: latestBytes) }
                }
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
            if let currentIndex = taskIndexes[transferID],
               let current = tasks[safe: currentIndex],
               current.state == .paused || current.state == .cancelled {
                completeJob(transferID)
                return
            }
            let mappedError = transferError(from: error)
            if mappedError.code == "ESIZE", automaticRetries[transferID, default: 0] < 3 {
                automaticRetries[transferID, default: 0] += 1
                if let index = taskIndexes[transferID] {
                    let offset = await resumableRemoteOffset(
                        for: tasks[index],
                        server: server
                    )
                    updateTask(at: index) {
                        $0.transferredBytes = offset
                        $0.state = .queued
                    }
                    enqueuePending(transferID)
                }
                completeJob(transferID)
                return
            }
            let persistedBytes = await resumableOffset(for: transferID, server: server)
            finish(transferID, state: .failed(mappedError), transferredBytes: persistedBytes)
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

    private func resumableOffset(for taskID: UUID, server: ServerConfig) async -> Int64 {
        guard let index = taskIndexes[taskID] else { return 0 }
        let task = tasks[index]
        if task.direction == .upload {
            return await resumableRemoteOffset(for: task, server: server)
        }
        guard let size = try? task.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return min(Int64(size), task.totalBytes)
    }

    private func ensureRemoteParentDirectory(
        for task: TransferTask,
        server: ServerConfig
    ) async throws {
        let parent = NSString(string: task.remotePath).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else { return }
        let key = RemoteDirectoryKey(serverID: server.id, path: parent)
        if preparedRemoteDirectories.contains(key) { return }

        let job: Task<Void, Error>
        if let existing = remoteDirectoryJobs[key] {
            job = existing
        } else {
            let service = self.service
            job = Task { try await service.makeDirectory(server, path: parent) }
            remoteDirectoryJobs[key] = job
        }

        do {
            try await job.value
            preparedRemoteDirectories.insert(key)
            remoteDirectoryJobs.removeValue(forKey: key)
        } catch {
            remoteDirectoryJobs.removeValue(forKey: key)
            throw error
        }
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
            let candidate = Self.joinRemote(directory, filename)
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
        guard let index = taskIndexes[taskID] else { return }
        switch tasks[index].state {
        case .completed, .skipped, .failed, .cancelled: return
        default: break
        }
        let previousBytes = tasks[index].transferredBytes
        let clampedBytes = min(max(0, bytes), tasks[index].totalBytes > 0 ? tasks[index].totalBytes : bytes)
        tasks[index].transferredBytes = clampedBytes
        transferredBytes += clampedBytes - previousBytes
        let now = Date()
        var samples = speedSamples[taskID] ?? []
        samples.append((now, clampedBytes))
        samples.removeAll { now.timeIntervalSince($0.0) > 5 }
        speedSamples[taskID] = samples
        if let first = samples.first {
            let duration = now.timeIntervalSince(first.0)
            if duration > 0.2 {
                tasks[index].speed = Double(clampedBytes - first.1) / duration
            }
        }
        refreshVisibleTask(taskID)
        requestSnapshot()
    }

    private func replaceTask(_ task: TransferTask) {
        guard let index = taskIndexes[task.id] else { return }
        updateTask(at: index) { $0 = task }
        requestSnapshot()
    }

    private func setState(_ taskID: UUID, _ state: TransferState) {
        guard let index = taskIndexes[taskID] else { return }
        updateTask(at: index) { $0.state = state }
        requestSnapshot()
    }

    private func finish(
        _ taskID: UUID,
        state: TransferState,
        transferredBytes: Int64? = nil
    ) {
        guard let index = taskIndexes[taskID] else { return }
        progressCoalescer.remove(taskID)
        updateTask(at: index) {
            $0.state = state
            $0.finishedAt = Date()
            $0.speed = 0
            if let transferredBytes {
                $0.transferredBytes = transferredBytes
            } else if state == .completed || state == .skipped {
                $0.transferredBytes = $0.totalBytes
            }
        }
        requestSnapshot()
    }

    private func completeJob(_ taskID: UUID) {
        progressCoalescer.remove(taskID)
        jobs.removeValue(forKey: taskID)
        cancellations.removeValue(forKey: taskID)
        speedSamples.removeValue(forKey: taskID)
        if let index = taskIndexes[taskID] {
            let task = tasks[index]
            switch task.state {
            case .completed, .skipped, .cancelled:
                automaticRetries.removeValue(forKey: taskID)
            default:
                break
            }
        }
        startPending()
        if jobs.isEmpty, pendingTaskIDSet.isEmpty {
            preparedRemoteDirectories.removeAll(keepingCapacity: true)
            remoteDirectoryJobs.removeAll(keepingCapacity: true)
        }
    }

    private func removeFinishedJobs() {
        jobs = jobs.filter { taskID, _ in
            guard let index = taskIndexes[taskID], let task = tasks[safe: index] else { return false }
            switch task.state {
            case .completed, .skipped, .failed, .cancelled, .paused:
                return false
            default:
                return true
            }
        }
    }

    private nonisolated static func joinRemote(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/\(name)" }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

private struct RemoteDirectoryKey: Hashable {
    let serverID: UUID
    let path: String
}

private final class TransferProgressCoalescer: @unchecked Sendable {
    private struct Pending {
        var bytes: Int64
        let deliver: @Sendable (Int64) -> Void
    }

    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var scheduled: Set<UUID> = []

    func submit(
        taskID: UUID,
        bytes: Int64,
        deliver: @escaping @Sendable (Int64) -> Void
    ) {
        lock.lock()
        pending[taskID] = Pending(bytes: bytes, deliver: deliver)
        let shouldSchedule = scheduled.insert(taskID).inserted
        lock.unlock()
        guard shouldSchedule else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.scheduled.remove(taskID)
            let latest = self.pending.removeValue(forKey: taskID)
            self.lock.unlock()
            latest?.deliver(latest?.bytes ?? 0)
        }
    }

    func remove(_ taskID: UUID) {
        lock.lock()
        pending.removeValue(forKey: taskID)
        scheduled.remove(taskID)
        lock.unlock()
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
