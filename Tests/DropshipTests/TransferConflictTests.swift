import XCTest
@testable import Dropship

@MainActor
final class TransferConflictTests: XCTestCase {
    func testAskConflictWaitsWithoutFailing() async throws {
        let fixture = try ConflictFixture(names: ["report.txt"])
        defer { fixture.remove() }
        let transport = ConflictTransport(existingPaths: ["/remote/report.txt"])
        let queue = TransferQueue(service: transport)

        queue.enqueueUpload(
            localURLs: fixture.files,
            to: fixture.server,
            remoteDir: "/remote",
            policy: .ask
        )

        try await waitUntil { queue.pendingConflicts.count == 1 }
        XCTAssertEqual(queue.tasks.first?.state, .awaitingDecision)
        XCTAssertFalse(queue.tasks.contains { if case .failed = $0.state { return true }; return false })
        XCTAssertEqual(queue.pendingConflicts.first?.destinationPath, "/remote/report.txt")
        XCTAssertEqual(queue.pendingConflicts.first?.destinationBytes, 99)
    }

    func testOverwriteResumesAndCompletes() async throws {
        let fixture = try ConflictFixture(names: ["report.txt"])
        defer { fixture.remove() }
        let transport = ConflictTransport(existingPaths: ["/remote/report.txt"])
        let queue = TransferQueue(service: transport)

        queue.enqueueUpload(localURLs: fixture.files, to: fixture.server, remoteDir: "/remote", policy: .ask)
        try await waitUntil { queue.pendingConflicts.first != nil }
        let id = try XCTUnwrap(queue.pendingConflicts.first?.taskID)
        queue.resolveConflict(id, with: .overwrite)

        try await waitUntil { queue.tasks.first?.state == .completed }
        XCTAssertEqual(transport.uploadedPaths, ["/remote/report.txt"])
        XCTAssertTrue(queue.pendingConflicts.isEmpty)
    }

    func testSkipMarksTaskSkipped() async throws {
        let fixture = try ConflictFixture(names: ["report.txt"])
        defer { fixture.remove() }
        let queue = TransferQueue(service: ConflictTransport(existingPaths: ["/remote/report.txt"]))

        queue.enqueueUpload(localURLs: fixture.files, to: fixture.server, remoteDir: "/remote", policy: .ask)
        try await waitUntil { queue.pendingConflicts.first != nil }
        queue.resolveConflict(try XCTUnwrap(queue.pendingConflicts.first?.taskID), with: .skip)

        try await waitUntil { queue.tasks.first?.state == .skipped }
        XCTAssertTrue(queue.pendingConflicts.isEmpty)
    }

    func testRenameUsesNumberedDestination() async throws {
        let fixture = try ConflictFixture(names: ["report.txt"])
        defer { fixture.remove() }
        let transport = ConflictTransport(existingPaths: ["/remote/report.txt"])
        let queue = TransferQueue(service: transport)

        queue.enqueueUpload(localURLs: fixture.files, to: fixture.server, remoteDir: "/remote", policy: .ask)
        try await waitUntil { queue.pendingConflicts.first != nil }
        queue.resolveConflict(try XCTUnwrap(queue.pendingConflicts.first?.taskID), with: .rename)

        try await waitUntil { queue.tasks.first?.state == .completed }
        XCTAssertEqual(queue.tasks.first?.remotePath, "/remote/report-1.txt")
        XCTAssertEqual(transport.uploadedPaths, ["/remote/report-1.txt"])
    }

    func testApplyToAllAutomaticallyResolvesLaterConflict() async throws {
        let fixture = try ConflictFixture(names: ["first.txt", "second.txt"])
        defer { fixture.remove() }
        let transport = ConflictTransport(
            existingPaths: ["/remote/first.txt", "/remote/second.txt"],
            heldUploadPaths: ["/remote/first.txt"]
        )
        let queue = TransferQueue(service: transport)
        queue.maxConcurrent = 1

        queue.enqueueUpload(localURLs: [fixture.files[0]], to: fixture.server, remoteDir: "/remote", policy: .ask)
        try await waitUntil { queue.pendingConflicts.first != nil }
        queue.resolveConflict(try XCTUnwrap(queue.pendingConflicts.first?.taskID), with: .overwrite, applyToAll: true)
        try await waitUntil { transport.uploadedPaths.contains("/remote/first.txt") }

        queue.enqueueUpload(localURLs: [fixture.files[1]], to: fixture.server, remoteDir: "/remote", policy: .ask)
        transport.releaseHeldUploads()

        try await waitUntil {
            queue.tasks.count == 2 && queue.tasks.allSatisfy { $0.state == .completed }
        }
        XCTAssertTrue(queue.pendingConflicts.isEmpty)
        XCTAssertEqual(Set(transport.uploadedPaths), ["/remote/first.txt", "/remote/second.txt"])
    }

    func testWaitingConflictDoesNotBlockUnrelatedTask() async throws {
        let fixture = try ConflictFixture(names: ["conflict.txt", "fresh.txt"])
        defer { fixture.remove() }
        let transport = ConflictTransport(existingPaths: ["/remote/conflict.txt"])
        let queue = TransferQueue(service: transport)
        queue.maxConcurrent = 1

        queue.enqueueUpload(localURLs: fixture.files, to: fixture.server, remoteDir: "/remote", policy: .ask)

        try await waitUntil {
            queue.pendingConflicts.count == 1
                && queue.tasks.first(where: { $0.filename == "fresh.txt" })?.state == .completed
        }
        XCTAssertEqual(
            queue.tasks.first(where: { $0.filename == "conflict.txt" })?.state,
            .awaitingDecision
        )
        XCTAssertEqual(transport.uploadedPaths, ["/remote/fresh.txt"])
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for transfer queue state")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct ConflictFixture {
    let directory: URL
    let files: [URL]
    let server = ServerConfig(alias: "conflict-test", hostname: "unused", username: "")

    init(names: [String]) throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        directory = fixtureDirectory
        files = try names.map { name in
            let url = fixtureDirectory.appendingPathComponent(name)
            try Data("new contents".utf8).write(to: url)
            return url
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ConflictTransport: FileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let existingPaths: Set<String>
    private let heldUploadPaths: Set<String>
    private var uploads: [String] = []
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []
    private var releasesHeldUploads = false

    init(existingPaths: Set<String>, heldUploadPaths: Set<String> = []) {
        self.existingPaths = existingPaths
        self.heldUploadPaths = heldUploadPaths
    }

    var uploadedPaths: [String] { lock.withLock { uploads } }

    func releaseHeldUploads() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            releasesHeldUploads = true
            defer { heldContinuations.removeAll() }
            return heldContinuations
        }
        continuations.forEach { $0.resume() }
    }

    func connect(_ server: ServerConfig) async throws -> TransportMode { .agent }
    func disconnect(_ serverID: UUID) async {}
    func list(_ server: ServerConfig, path: String, showHidden: Bool) async throws -> [RemoteEntry] { [] }

    func stat(_ server: ServerConfig, path: String) async throws -> RemoteEntry {
        guard existingPaths.contains(path) else {
            throw TransferError(code: "ENOENT", message: "not found")
        }
        return RemoteEntry(
            name: NSString(string: path).lastPathComponent,
            path: path,
            isDir: false,
            size: 99,
            mode: "0644",
            modTime: Date()
        )
    }

    func makeDirectory(_ server: ServerConfig, path: String) async throws {}
    func remove(_ server: ServerConfig, path: String, recursive: Bool) async throws {}
    func move(_ server: ServerConfig, from: String, to: String) async throws {}
    func chmod(_ server: ServerConfig, path: String, mode: String) async throws {}
    func homeDirectory(_ server: ServerConfig) async throws -> String { "/remote" }
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
        lock.withLock { uploads.append(remote) }
        if heldUploadPaths.contains(remote) {
            await withCheckedContinuation { continuation in
                let releaseImmediately = lock.withLock { () -> Bool in
                    if releasesHeldUploads { return true }
                    heldContinuations.append(continuation)
                    return false
                }
                if releaseImmediately { continuation.resume() }
            }
        }
        progress(Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
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
