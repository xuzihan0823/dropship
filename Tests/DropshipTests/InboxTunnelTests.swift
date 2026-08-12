import Foundation
import Network
import XCTest
@testable import Dropship

// ============================================================
// 反向收件隧道的回归测试。
//
// 重点全在"别把坏数据当好数据"上：鉴权、截断、路径穿越、重名。
// 这几条是 PROTOCOL.md 2.2 那次事故（半截文件覆盖原文件）的同类风险。
// ============================================================

final class InboxServerTests: XCTestCase {
    private var directory: URL!
    private var server: InboxServer!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropship-inbox-\(UUID().uuidString)", isDirectory: true)
        server = InboxServer(inboxDirectory: directory)
    }

    override func tearDown() {
        server?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    // MARK: - 纯函数：文件名净化

    func testSanitizeFlattensPathTraversal() {
        XCTAssertEqual(InboxServer.sanitize("/../../../../etc/passwd"), "passwd")
        XCTAssertEqual(InboxServer.sanitize("/a/b/c/report.pdf"), "report.pdf")
        // 先解码再取 lastPathComponent —— 顺序反了 %2F 会解出新的分隔符
        XCTAssertEqual(InboxServer.sanitize("/%2E%2E%2F%2E%2E%2Fevil.sh"), "evil.sh")
        XCTAssertEqual(InboxServer.sanitize("/report.pdf?v=1#frag"), "report.pdf")
    }

    func testSanitizeRejectsEmptyAndHiddenNames() {
        XCTAssertEqual(InboxServer.sanitize("/"), "untitled")
        XCTAssertEqual(InboxServer.sanitize(""), "untitled")
        XCTAssertEqual(InboxServer.sanitize("/.."), "untitled")
        // 不让推送方在收件箱里造隐藏文件
        XCTAssertEqual(InboxServer.sanitize("/.bashrc"), "_.bashrc")
    }

    func testSanitizeTruncatesLongNamesKeepingExtension() {
        let long = String(repeating: "z", count: 400) + ".log"
        let result = InboxServer.sanitize("/" + long)
        XCTAssertLessThanOrEqual(result.utf8.count, 200)
        XCTAssertTrue(result.hasSuffix(".log"))
    }

    func testSanitizeKeepsChineseNames() {
        XCTAssertEqual(InboxServer.sanitize("/构建报告.tar.gz"), "构建报告.tar.gz")
    }

    // MARK: - 纯函数：重名

    func testAvailableURLDoesNotOverwrite() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("a.txt")
        try Data("原文件".utf8).write(to: first)

        let second = InboxServer.availableURL(in: directory, name: "a.txt")
        XCTAssertEqual(second.lastPathComponent, "a-1.txt")
        XCTAssertEqual(try Data(contentsOf: first), Data("原文件".utf8))
    }

    // MARK: - 端到端

    func testAcceptsAuthorizedUpload() async throws {
        let port = try await server.start()
        let serverID = UUID()
        let token = server.register(serverID)

        let delivered = Locked<InboxServer.Received?>(nil)
        let arrived = expectation(description: "onReceive")
        arrived.assertForOverFulfill = false
        server.onReceive = { received in
            delivered.value = received
            arrived.fulfill()
        }

        let payload = Data("hello dropship".utf8)
        let response = RawHTTPClient(port: port).perform(
            head: Self.head([
                "PUT /upload HTTP/1.1",
                "Host: 127.0.0.1",
                "Authorization: Bearer \(token)",
                "X-Dropship-Name: \(Data("报告.txt".utf8).base64EncodedString())",
                "Content-Length: \(payload.count)"
            ]),
            body: payload
        )

        await fulfillment(of: [arrived], timeout: 10)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 201"), response)

        let received = try XCTUnwrap(delivered.value)
        XCTAssertEqual(received.serverID, serverID)
        XCTAssertEqual(received.filename, "报告.txt")
        XCTAssertEqual(received.bytes, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: received.url), payload)
    }

    func testRejectsMissingAndWrongToken() async throws {
        let port = try await server.start()
        server.register(UUID())
        let payload = Data("nope".utf8)

        let noToken = RawHTTPClient(port: port).perform(
            head: Self.head([
                "PUT /x.txt HTTP/1.1",
                "Content-Length: \(payload.count)"
            ]),
            body: payload
        )
        XCTAssertTrue(noToken.hasPrefix("HTTP/1.1 401"), noToken)

        let wrongToken = RawHTTPClient(port: port).perform(
            head: Self.head([
                "PUT /x.txt HTTP/1.1",
                "Authorization: Bearer 00000000000000000000000000000000",
                "Content-Length: \(payload.count)"
            ]),
            body: payload
        )
        XCTAssertTrue(wrongToken.hasPrefix("HTTP/1.1 401"), wrongToken)

        // 鉴权失败不该在收件箱留下任何东西
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(entries.filter { $0 != ".incoming" }, [])
    }

    func testTruncatedBodyKeepsPartAndNeverLands() async throws {
        let port = try await server.start()
        let token = server.register(UUID())

        let arrived = expectation(description: "不应该收到任何文件")
        arrived.isInverted = true
        server.onReceive = { _ in arrived.fulfill() }

        // 声明 100 字节，只发 40 字节然后关掉发送端
        let response = RawHTTPClient(port: port).perform(
            head: Self.head([
                "PUT /important.bin HTTP/1.1",
                "Authorization: Bearer \(token)",
                "Content-Length: 100"
            ]),
            body: Data(repeating: 0x41, count: 40),
            halfCloseAfterBody: true
        )

        await fulfillment(of: [arrived], timeout: 3)
        XCTAssertTrue(response.contains("ESIZE"), response)

        // 收件箱里绝不能出现看起来完整的截断文件
        let landed = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(landed.contains("important.bin"))

        // .part 要留着，作为事故现场
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: server.stagingDirectory.path)) ?? []
        XCTAssertEqual(staged.filter { $0.hasSuffix(".part") }.count, 1)
    }

    func testAnswersExpect100ContinueBeforeBody() async throws {
        let port = try await server.start()
        let token = server.register(UUID())
        let payload = Data(repeating: 0x42, count: 2048)

        let arrived = expectation(description: "onReceive")
        arrived.assertForOverFulfill = false
        server.onReceive = { _ in arrived.fulfill() }

        // curl 对 >1KB 的 PUT body 默认发这个头。不回 100，它每次都白等 1 秒。
        let response = RawHTTPClient(port: port).perform(
            head: Self.head([
                "PUT /big.bin HTTP/1.1",
                "Authorization: Bearer \(token)",
                "Expect: 100-continue",
                "Content-Length: \(payload.count)"
            ]),
            body: payload
        )

        await fulfillment(of: [arrived], timeout: 10)
        XCTAssertTrue(response.contains("HTTP/1.1 100 Continue"), response)
        XCTAssertTrue(response.contains("HTTP/1.1 201"), response)
    }

    func testPathTraversalLandsInsideInbox() async throws {
        let port = try await server.start()
        let token = server.register(UUID())

        let delivered = Locked<InboxServer.Received?>(nil)
        let arrived = expectation(description: "onReceive")
        arrived.assertForOverFulfill = false
        server.onReceive = { received in
            delivered.value = received
            arrived.fulfill()
        }

        let payload = Data("pwned".utf8)
        _ = RawHTTPClient(port: port).perform(
            head: Self.head([
                "PUT /../../../../tmp/dropship-escape.txt HTTP/1.1",
                "Authorization: Bearer \(token)",
                "Content-Length: \(payload.count)"
            ]),
            body: payload
        )

        await fulfillment(of: [arrived], timeout: 10)
        let received = try XCTUnwrap(delivered.value)
        XCTAssertEqual(received.filename, "dropship-escape.txt")
        XCTAssertEqual(
            received.url.deletingLastPathComponent().standardizedFileURL,
            directory.standardizedFileURL
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/dropship-escape.txt"))
    }

    func testRejectsChunkedBody() async throws {
        let port = try await server.start()
        let token = server.register(UUID())

        let response = RawHTTPClient(port: port).perform(
            head: Self.head([
                "PUT /x.txt HTTP/1.1",
                "Authorization: Bearer \(token)",
                "Transfer-Encoding: chunked"
            ]),
            body: Data()
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 411"), response)
    }

    func testRevokedTokenStopsWorking() async throws {
        let port = try await server.start()
        let serverID = UUID()
        let token = server.register(serverID)
        server.unregister(serverID)

        let payload = Data("late".utf8)
        let response = RawHTTPClient(port: port).perform(
            head: Self.head([
                "PUT /late.txt HTTP/1.1",
                "Authorization: Bearer \(token)",
                "Content-Length: \(payload.count)"
            ]),
            body: payload
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"), response)
    }

    // MARK: - 工具

    private static func head(_ lines: [String]) -> String {
        lines.joined(separator: "\r\n") + "\r\n\r\n"
    }
}

// MARK: - 反向隧道

final class ReverseTunnelTests: XCTestCase {
    private let config = ServerConfig(alias: "demo", hostname: "example.com", username: "root")

    func testParsesAllocatedPortFromSSHStderr() {
        XCTAssertEqual(
            ReverseTunnel.allocatedPort(
                in: "Allocated port 45678 for remote forward to 127.0.0.1:51234"
            ),
            45678
        )
        XCTAssertNil(ReverseTunnel.allocatedPort(in: "debug1: Authentication succeeded"))
        XCTAssertNil(ReverseTunnel.allocatedPort(in: "Permission denied (publickey)."))
    }

    func testArgumentsRequestRemoteForwardAndOverrideControlMaster() {
        let tunnel = ReverseTunnel(server: config, localPort: 51234) { _ in }
        let arguments = tunnel.arguments()

        XCTAssertTrue(arguments.contains("-N"))
        XCTAssertTrue(arguments.contains("-R"))
        XCTAssertTrue(arguments.contains("0:127.0.0.1:51234"))
        XCTAssertTrue(arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertEqual(arguments.last, "root@example.com")

        // ssh 取每个参数首次出现的值：ControlPath=none 必须排在
        // SSHProcessRunner 那份共享 ControlPath 之前，否则隧道会挂到
        // 共享 master 上，生命周期就不归我们管了。
        let none = arguments.firstIndex(of: "ControlPath=none")
        let shared = arguments.firstIndex { $0.hasPrefix("ControlPath=/") }
        XCTAssertNotNil(none)
        XCTAssertNotNil(shared)
        if let none, let shared { XCTAssertLessThan(none, shared) }
    }

    func testReportsActiveWhenSSHAnnouncesAllocatedPort() throws {
        let fixture = try FakeSSHFixture(script: """
        echo "Allocated port 45678 for remote forward to 127.0.0.1:1" >&2
        sleep 30
        """)
        defer { fixture.remove() }

        let port = Locked<Int?>(nil)
        let active = expectation(description: "active")
        active.assertForOverFulfill = false
        let tunnel = ReverseTunnel(
            server: config,
            localPort: 1,
            sshExecutableURL: fixture.scriptURL
        ) { event in
            if case .active(let value) = event {
                port.value = value
                active.fulfill()
            }
        }

        tunnel.start()
        wait(for: [active], timeout: 15)
        tunnel.stop()

        XCTAssertEqual(port.value, 45678)
    }

    func testRetriesWhenSSHExitsImmediately() throws {
        let fixture = try FakeSSHFixture(script: """
        echo "ssh: connect to host example.com port 22: Connection refused" >&2
        exit 255
        """)
        defer { fixture.remove() }

        let retrying = expectation(description: "retrying")
        retrying.assertForOverFulfill = false
        let reason = Locked<String>("")
        let tunnel = ReverseTunnel(
            server: config,
            localPort: 1,
            sshExecutableURL: fixture.scriptURL
        ) { event in
            if case .retrying(let value, _) = event {
                reason.value = value
                retrying.fulfill()
            }
        }

        tunnel.start()
        wait(for: [retrying], timeout: 15)
        tunnel.stop()

        XCTAssertTrue(reason.value.contains("Connection refused"), reason.value)
    }
}

// MARK: - 测试工具

/// 加锁的可变盒子。@Sendable 闭包里不能直接改捕获的 var。
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// 直接拿裸 TCP 说 HTTP，才能构造出 URLSession 造不出来的请求
/// —— 截断的 body、缺 Content-Length、手写的 Expect 头。
private final class RawHTTPClient: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "dropship.test.rawhttp")
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var received = Data()
    private var signalled = false

    init(port: UInt16) { self.port = port }

    /// 发一个请求，返回读到的全部响应字节。
    /// halfCloseAfterBody 用于模拟传到一半断线。
    func perform(
        head: String,
        body: Data,
        halfCloseAfterBody: Bool = false,
        timeout: TimeInterval = 10
    ) -> String {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return "" }
        let connection = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .tcp)

        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                var payload = Data(head.utf8)
                payload.append(body)
                // .finalMessage 才会送 FIN（用来模拟传到一半断线）；
                // .defaultMessage 下 isComplete 只表示这条消息发完了，连接不关。
                connection.send(
                    content: payload,
                    contentContext: halfCloseAfterBody ? .finalMessage : .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in }
                )
                self.read(from: connection)
            case .failed, .cancelled:
                self.signalOnce()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()

        lock.lock()
        defer { lock.unlock() }
        return String(decoding: received, as: UTF8.self)
    }

    private func read(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.lock.lock()
                self.received.append(data)
                self.lock.unlock()
            }
            if isComplete || error != nil {
                self.signalOnce()
                return
            }
            self.read(from: connection)
        }
    }

    private func signalOnce() {
        lock.lock()
        let alreadyDone = signalled
        signalled = true
        lock.unlock()
        if !alreadyDone { semaphore.signal() }
    }
}

/// 假的 ssh 可执行文件，手法同 LargeUploadRegressionTests 里的 UploadFixture。
private struct FakeSSHFixture {
    let directory: URL
    let scriptURL: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scriptURL = directory.appendingPathComponent("fake-ssh.sh")
        try "#!/bin/sh\n\(script)\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
