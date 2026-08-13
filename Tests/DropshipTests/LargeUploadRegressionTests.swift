import Foundation
import XCTest
@testable import Dropship

final class SSHProcessRunnerRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    func testUploadDrainsLargeStderrWithoutDeadlocking() async throws {
        let fixture = try UploadFixture(script: """
        i=0
        while [ "$i" -lt 10000 ]; do
          printf '{"type":"progress","bytes":%s}\n' "$i" >&2
          i=$((i + 1))
        done
        cat >/dev/null
        """)
        defer { fixture.remove() }

        let runner = SSHProcessRunner(sshExecutableURL: fixture.scriptURL)
        try await runner.streamUpload(
            server: fixture.server,
            command: "ignored",
            source: fixture.sourceURL,
            offset: 0,
            cancellation: TransferCancellation(),
            progress: { _ in }
        )
    }

    func testUploadTurnsEarlyChildExitIntoErrorInsteadOfTerminatingApp() async throws {
        let fixture = try UploadFixture(script: "exit 23")
        defer { fixture.remove() }

        let runner = SSHProcessRunner(sshExecutableURL: fixture.scriptURL)
        do {
            try await runner.streamUpload(
                server: fixture.server,
                command: "ignored",
                source: fixture.sourceURL,
                offset: 0,
                cancellation: TransferCancellation(),
                progress: { _ in }
            )
            XCTFail("Expected the closed child-process pipe to fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }
}

final class RemoteFileMovePlanTests: XCTestCase {
    private let serverID = UUID()

    func testBuildsTargetInsideChosenDirectory() throws {
        let payload = makePayload(path: "/root/archive.zip", name: "archive.zip")
        let plan = try RemoteFileMovePlan.make(
            payload: payload,
            targetDirectory: "/root/projects",
            selectedServerID: serverID
        )

        XCTAssertEqual(plan.sourcePath, "/root/archive.zip")
        XCTAssertEqual(plan.targetPath, "/root/projects/archive.zip")
    }

    func testInternalDragURLRoundTripsWithoutBecomingAFileURL() throws {
        let payload = makePayload(
            path: "/root/工程项目/大文件.zip",
            name: "大文件.zip",
            isDirectory: false
        )

        XCTAssertFalse(payload.dragURL.isFileURL)
        XCTAssertEqual(RemoteFileDragPayload(dragURL: payload.dragURL), payload)
        XCTAssertTrue(payload.itemProvider().registeredTypeIdentifiers.contains("public.url"))
        XCTAssertFalse(payload.itemProvider().registeredTypeIdentifiers.contains("public.file-url"))
    }

    func testRejectsPayloadFromAnotherServer() {
        let payload = RemoteFileDragPayload(
            serverID: UUID(),
            path: "/root/archive.zip",
            name: "archive.zip",
            isDirectory: false
        )
        XCTAssertThrowsError(try RemoteFileMovePlan.make(
            payload: payload,
            targetDirectory: "/root/projects",
            selectedServerID: serverID
        )) { error in
            XCTAssertEqual(error as? RemoteFileMoveError, .differentServer)
        }
    }

    func testRejectsMovingEntryToItsCurrentDirectory() {
        let payload = makePayload(path: "/root/archive.zip", name: "archive.zip")
        XCTAssertThrowsError(try RemoteFileMovePlan.make(
            payload: payload,
            targetDirectory: "/root",
            selectedServerID: serverID
        )) { error in
            XCTAssertEqual(error as? RemoteFileMoveError, .alreadyInDirectory)
        }
    }

    func testRejectsMovingDirectoryIntoItsOwnSubtree() {
        let payload = makePayload(
            path: "/root/projects",
            name: "projects",
            isDirectory: true
        )
        XCTAssertThrowsError(try RemoteFileMovePlan.make(
            payload: payload,
            targetDirectory: "/root/projects/nested",
            selectedServerID: serverID
        )) { error in
            XCTAssertEqual(error as? RemoteFileMoveError, .directoryInsideItself)
        }
    }

    private func makePayload(
        path: String,
        name: String,
        isDirectory: Bool = false
    ) -> RemoteFileDragPayload {
        RemoteFileDragPayload(
            serverID: serverID,
            path: path,
            name: name,
            isDirectory: isDirectory
        )
    }
}

@MainActor
final class RemoteInitialDirectoryTests: XCTestCase {
    func testUsesRemoteHomeWhenNoInitialPathIsConfigured() async throws {
        let service = HomeDirectoryTransport(home: "/home/claude")
        let viewModel = RemoteFileViewModel()
        let server = ServerConfig(
            alias: "tencent-claude",
            hostname: "example.com",
            username: "claude"
        )

        viewModel.loadInitialDirectory(
            server: server,
            service: service,
            showHidden: false
        )
        try await waitUntil { viewModel.path == "/home/claude" }
        viewModel.load(server: server, service: service, showHidden: false)
        await fulfillment(of: [service.listed], timeout: 2)

        XCTAssertEqual(viewModel.path, "/home/claude")
        XCTAssertEqual(service.listedPaths, ["/home/claude"])
    }

    func testConfiguredInitialPathTakesPriorityOverRemoteHome() async throws {
        let service = HomeDirectoryTransport(home: "/home/claude")
        let viewModel = RemoteFileViewModel()
        let server = ServerConfig(
            alias: "custom",
            hostname: "example.com",
            username: "claude",
            defaultRemotePath: "/srv/projects"
        )

        viewModel.loadInitialDirectory(
            server: server,
            service: service,
            showHidden: false
        )
        try await waitUntil { viewModel.path == "/srv/projects" }
        viewModel.load(server: server, service: service, showHidden: false)
        await fulfillment(of: [service.listed], timeout: 2)

        XCTAssertEqual(viewModel.path, "/srv/projects")
        XCTAssertEqual(service.listedPaths, ["/srv/projects"])
        XCTAssertEqual(service.homeDirectoryCallCount, 0)
    }

    func testTransferErrorExposesItsMessageToTheUI() {
        let error = TransferError(code: "EACCES", message: "permission denied")
        XCTAssertEqual(error.localizedDescription, "permission denied")
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return XCTFail("Timed out waiting for initial remote directory")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
final class TransferQueueCompressionRegressionTests: XCTestCase {
    func testOrdinaryFileUploadDoesNotAdvertiseGzipForRawBytes() async throws {
        let transport = RecordingTransport()
        let queue = TransferQueue(service: transport)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.txt")
        try Data(repeating: 0x41, count: 1_048_576).write(to: source)

        queue.enqueueUpload(
            localURLs: [source],
            to: RecordingTransport.server,
            remoteDir: "/tmp",
            policy: .overwrite
        )

        await fulfillment(of: [transport.uploaded], timeout: 3)
        XCTAssertEqual(transport.compressionValues, [false])
    }

    func testDirectoryUploadCreatesRemoteParentOnceBeforeConcurrentFiles() async throws {
        let transport = DirectoryRecordingTransport()
        let queue = TransferQueue(service: transport)
        queue.maxConcurrent = 2
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0x41]).write(to: directory.appendingPathComponent("one.txt"))
        try Data([0x42]).write(to: directory.appendingPathComponent("two.txt"))

        queue.enqueueUpload(
            localURLs: [directory],
            to: DirectoryRecordingTransport.server,
            remoteDir: "/root",
            policy: .overwrite
        )

        await fulfillment(of: [transport.uploaded], timeout: 3)
        XCTAssertEqual(transport.createdDirectories, ["/root/\(directory.lastPathComponent)"])
        XCTAssertTrue(transport.uploadedAfterDirectoryCreation)
    }

    func testFailedUploadUsesPersistedPartSizeInsteadOfSentBytes() async throws {
        let transport = FailingAfterProgressTransport()
        let queue = TransferQueue(service: transport)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0x41, count: 1_024).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        queue.enqueueUpload(
            localURLs: [source],
            to: FailingAfterProgressTransport.server,
            remoteDir: "/missing",
            policy: .overwrite
        )

        await fulfillment(of: [transport.failed], timeout: 3)
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let task = queue.tasks.first else {
            return XCTFail("Expected failed transfer task")
        }
        guard case .failed = task.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertEqual(task.transferredBytes, 0)
        XCTAssertEqual(queue.transferredBytes, 0)
        XCTAssertEqual(queue.visibleTasks.first?.transferredBytes, 0)
    }
}

@MainActor
final class TransferQueueScalingRegressionTests: XCTestCase {
    func testLargeQueuePublishesBoundedVisibleTasksAndIncrementalSummary() async throws {
        let transport = SuspendedTransport()
        let queue = TransferQueue(service: transport)
        queue.maxConcurrent = 1
        let fixture = try ManyFilesFixture(count: 10_000, fileSize: 3)
        defer { fixture.remove() }

        queue.enqueueUpload(
            localURLs: [fixture.directory],
            to: SuspendedTransport.server,
            remoteDir: "/tmp",
            policy: .overwrite
        )

        try await waitUntil(timeout: 10) { queue.taskCount == fixture.files.count }
        XCTAssertEqual(queue.tasks.count, 10_000)
        XCTAssertLessThanOrEqual(queue.visibleTasks.count, 200)
        XCTAssertEqual(queue.totalBytes, 30_000)
        XCTAssertEqual(queue.activeCount, 1)

        let firstID = try XCTUnwrap(queue.tasks.first?.id)
        queue.cancel(firstID)
        XCTAssertEqual(queue.finishedCount, 1)
        queue.removeTask(firstID)
        XCTAssertEqual(queue.taskCount, 9_999)
        XCTAssertEqual(queue.totalBytes, 29_997)
        XCTAssertEqual(queue.finishedCount, 0)

        let lastID = try XCTUnwrap(queue.tasks.last?.id)
        queue.cancel(lastID)
        queue.removeTask(lastID)
        XCTAssertEqual(queue.taskCount, 9_998)
        XCTAssertEqual(queue.totalBytes, 29_994)
    }

    func testProgressSnapshotsAreThrottledAndFinalCompletionIsNotLost() async throws {
        let transport = BurstProgressTransport()
        let queue = TransferQueue(service: transport)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0x41, count: 1_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let initialRevision = queue.snapshotRevision
        queue.enqueueUpload(
            localURLs: [source],
            to: BurstProgressTransport.server,
            remoteDir: "/tmp",
            policy: .overwrite
        )

        try await waitUntil(timeout: 3) { queue.transferredBytes == 500 }
        XCTAssertLessThan(queue.snapshotRevision - initialRevision, 20)

        try await waitUntil(timeout: 3) { queue.completedCount == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertLessThan(queue.snapshotRevision - initialRevision, 30)
        XCTAssertEqual(queue.transferredBytes, 1_000)
        XCTAssertEqual(queue.visibleTasks.first?.transferredBytes, 1_000)
        XCTAssertEqual(queue.finishedTransferRevision, 1)
    }

    func testCancelAllStopsRunningAndQueuedTasks() async throws {
        let transport = SuspendedTransport()
        let queue = TransferQueue(service: transport)
        queue.maxConcurrent = 1
        let fixture = try ManyFilesFixture(count: 50, fileSize: 3)
        defer { fixture.remove() }

        queue.enqueueUpload(
            localURLs: [fixture.directory],
            to: SuspendedTransport.server,
            remoteDir: "/tmp",
            policy: .overwrite
        )
        try await waitUntil(timeout: 3) { queue.taskCount == 50 && queue.activeCount == 1 }

        queue.cancelAll()
        try await waitUntil(timeout: 3) { queue.activeCount == 0 }

        XCTAssertFalse(queue.hasCancellableTasks)
        XCTAssertTrue(queue.tasks.allSatisfy {
            if case .cancelled = $0.state { return true }
            return false
        })
    }

    func testCancelAllStopsDirectoryScanningBeforeItPublishesEverything() async throws {
        let transport = SuspendedTransport()
        let queue = TransferQueue(service: transport)
        let fixture = try ManyFilesFixture(count: 5_000, fileSize: 1)
        defer { fixture.remove() }

        queue.enqueueUpload(
            localURLs: [fixture.directory],
            to: SuspendedTransport.server,
            remoteDir: "/tmp",
            policy: .overwrite
        )
        XCTAssertTrue(queue.hasCancellableTasks)
        queue.cancelAll()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(queue.hasCancellableTasks)
        XCTAssertEqual(queue.taskCount, 0)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for queue state")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct UploadFixture {
    let directory: URL
    let scriptURL: URL
    let sourceURL: URL
    let server = ServerConfig(alias: "fake-ssh", hostname: "unused", username: "")

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scriptURL = directory.appendingPathComponent("fake-ssh.sh")
        sourceURL = directory.appendingPathComponent("large.bin")
        try "#!/bin/sh\n\(script)\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try Data(repeating: 0x5A, count: 4 * 1_048_576).write(to: sourceURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class RecordingTransport: FileTransport, @unchecked Sendable {
    static let server = ServerConfig(alias: "test", hostname: "unused", username: "")
    let uploaded = XCTestExpectation(description: "upload called")
    private let stateQueue = DispatchQueue(label: "DropshipTests.RecordingTransport")
    private var recordedCompression: [Bool] = []

    var compressionValues: [Bool] {
        stateQueue.sync { recordedCompression }
    }

    func connect(_ server: ServerConfig) async throws -> TransportMode { .agent }
    func disconnect(_ serverID: UUID) async {}
    func list(_ server: ServerConfig, path: String, showHidden: Bool) async throws -> [RemoteEntry] { [] }
    func stat(_ server: ServerConfig, path: String) async throws -> RemoteEntry {
        throw TransferError(code: "ENOENT", message: "not found")
    }
    func makeDirectory(_ server: ServerConfig, path: String) async throws {}
    func remove(_ server: ServerConfig, path: String, recursive: Bool) async throws {}
    func move(_ server: ServerConfig, from: String, to: String) async throws {}
    func chmod(_ server: ServerConfig, path: String, mode: String) async throws {}
    func homeDirectory(_ server: ServerConfig) async throws -> String { "/tmp" }
    func diskSpace(_ server: ServerConfig, path: String) async throws -> (total: Int64, free: Int64) { (1, 1) }
    func hash(_ server: ServerConfig, path: String) async throws -> (String, Int64)? { nil }

    func upload(
        _ server: ServerConfig,
        local: URL,
        remote: String,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        stateQueue.sync { recordedCompression.append(compress) }
        progress(Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        uploaded.fulfill()
    }

    func download(
        _ server: ServerConfig,
        remote: String,
        local: URL,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {}
}

private final class HomeDirectoryTransport: TransportStub, @unchecked Sendable {
    let listed = XCTestExpectation(description: "initial directory listed")
    private let lock = NSLock()
    private let home: String
    private var paths: [String] = []
    private var homeCalls = 0

    init(home: String) {
        self.home = home
    }

    var listedPaths: [String] { lock.withLock { paths } }
    var homeDirectoryCallCount: Int { lock.withLock { homeCalls } }

    override func homeDirectory(_ server: ServerConfig) async throws -> String {
        lock.withLock { homeCalls += 1 }
        return home
    }

    override func list(
        _ server: ServerConfig,
        path: String,
        showHidden: Bool
    ) async throws -> [RemoteEntry] {
        lock.withLock { paths.append(path) }
        listed.fulfill()
        return []
    }
}

private final class DirectoryRecordingTransport: TransportStub, @unchecked Sendable {
    let uploaded = XCTestExpectation(description: "both uploads called")
    private let lock = NSLock()
    private var directories: [String] = []
    private var uploadsAfterCreation = true

    override init() {
        uploaded.expectedFulfillmentCount = 2
    }

    var createdDirectories: [String] {
        lock.withLock { directories }
    }

    var uploadedAfterDirectoryCreation: Bool {
        lock.withLock { uploadsAfterCreation }
    }

    override func makeDirectory(_ server: ServerConfig, path: String) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        lock.withLock { directories.append(path) }
    }

    override func upload(
        _ server: ServerConfig,
        local: URL,
        remote: String,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        lock.withLock {
            if directories.isEmpty { uploadsAfterCreation = false }
        }
        uploaded.fulfill()
    }
}

private final class FailingAfterProgressTransport: TransportStub, @unchecked Sendable {
    let failed = XCTestExpectation(description: "upload failed after progress")

    override func upload(
        _ server: ServerConfig,
        local: URL,
        remote: String,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let size = Int64(try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        progress(size)
        failed.fulfill()
        throw TransferError(code: "ENOENT", message: "remote parent missing")
    }
}

private struct ManyFilesFixture {
    let directory: URL
    let files: [URL]

    init(count: Int, fileSize: Int) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = Data(repeating: 0x58, count: fileSize)
        var created: [URL] = []
        created.reserveCapacity(count)
        for index in 0..<count {
            let url = directory.appendingPathComponent("file-\(index).txt")
            try contents.write(to: url)
            created.append(url)
        }
        files = created
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private class TransportStub: FileTransport, @unchecked Sendable {
    static let server = ServerConfig(alias: "test", hostname: "unused", username: "")

    func connect(_ server: ServerConfig) async throws -> TransportMode { .agent }
    func disconnect(_ serverID: UUID) async {}
    func list(_ server: ServerConfig, path: String, showHidden: Bool) async throws -> [RemoteEntry] { [] }
    func stat(_ server: ServerConfig, path: String) async throws -> RemoteEntry {
        throw TransferError(code: "ENOENT", message: "not found")
    }
    func makeDirectory(_ server: ServerConfig, path: String) async throws {}
    func remove(_ server: ServerConfig, path: String, recursive: Bool) async throws {}
    func move(_ server: ServerConfig, from: String, to: String) async throws {}
    func chmod(_ server: ServerConfig, path: String, mode: String) async throws {}
    func homeDirectory(_ server: ServerConfig) async throws -> String { "/tmp" }
    func diskSpace(_ server: ServerConfig, path: String) async throws -> (total: Int64, free: Int64) { (1, 1) }
    func hash(_ server: ServerConfig, path: String) async throws -> (String, Int64)? { nil }

    func upload(
        _ server: ServerConfig,
        local: URL,
        remote: String,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {}

    func download(
        _ server: ServerConfig,
        remote: String,
        local: URL,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {}
}

private final class SuspendedTransport: TransportStub, @unchecked Sendable {
    override func upload(
        _ server: ServerConfig,
        local: URL,
        remote: String,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        while !cancellation.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }
}

private final class BurstProgressTransport: TransportStub, @unchecked Sendable {
    override func upload(
        _ server: ServerConfig,
        local: URL,
        remote: String,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        for bytes in 1...500 { progress(Int64(bytes)) }
        try await Task.sleep(nanoseconds: 350_000_000)
        for bytes in 501...1_000 { progress(Int64(bytes)) }
    }
}
