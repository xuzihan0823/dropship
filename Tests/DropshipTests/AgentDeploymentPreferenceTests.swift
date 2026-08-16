import Foundation
import XCTest
@testable import Dropship

final class ServerConfigAgentDeploymentTests: XCTestCase {
    func testLegacyServerWithoutAgentDeploymentPreferenceDefaultsToEnabled() throws {
        let id = UUID(uuidString: "D3402E89-1E77-4D75-A894-6A884FA71D87")!
        let json = """
        {
          "id": "D3402E89-1E77-4D75-A894-6A884FA71D87",
          "alias": "legacy-production",
          "displayName": "Legacy Production",
          "hostname": "legacy.example.com",
          "port": 2202,
          "username": "deploy",
          "identityFile": "~/.ssh/legacy_ed25519",
          "proxyJump": "bastion",
          "source": "manual",
          "defaultRemotePath": "/srv/app",
          "favorites": ["/srv/app", "/var/log"]
        }
        """

        let server = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))

        XCTAssertEqual(server.id, id)
        XCTAssertEqual(server.alias, "legacy-production")
        XCTAssertEqual(server.displayName, "Legacy Production")
        XCTAssertEqual(server.hostname, "legacy.example.com")
        XCTAssertEqual(server.port, 2202)
        XCTAssertEqual(server.username, "deploy")
        XCTAssertEqual(server.identityFile, "~/.ssh/legacy_ed25519")
        XCTAssertEqual(server.proxyJump, "bastion")
        XCTAssertEqual(server.source, .manual)
        XCTAssertEqual(server.defaultRemotePath, "/srv/app")
        XCTAssertEqual(server.favorites, ["/srv/app", "/var/log"])
        XCTAssertTrue(server.allowAgentDeploy)
    }
}

final class RemoteFileServiceAgentDeploymentTests: XCTestCase {
    func testDisabledDeploymentConnectsOnlyThroughSFTP() async throws {
        let sftp = ConnectionTransportSpy(mode: .sftp)
        let agent = ConnectionTransportSpy(mode: .agent)
        let bootstrapper = BootstrapperSpy()
        let service = RemoteFileServiceImpl(
            sftp: sftp,
            agent: agent,
            bootstrapper: bootstrapper
        )
        let server = ServerConfig(
            alias: "no-agent",
            hostname: "example.com",
            username: "deploy",
            allowAgentDeploy: false
        )

        let mode = try await service.connect(server)

        XCTAssertEqual(mode, .sftp)
        XCTAssertEqual(bootstrapper.ensureCallCount, 0)
        XCTAssertEqual(agent.connectCallCount, 0)
        XCTAssertEqual(sftp.connectCallCount, 1)
    }

    func testEnabledDeploymentUsesBootstrapperAndAgent() async throws {
        let sftp = ConnectionTransportSpy(mode: .sftp)
        let agent = ConnectionTransportSpy(mode: .agent)
        let bootstrapper = BootstrapperSpy()
        let service = RemoteFileServiceImpl(
            sftp: sftp,
            agent: agent,
            bootstrapper: bootstrapper
        )
        let server = ServerConfig(
            alias: "agent",
            hostname: "example.com",
            username: "deploy",
            allowAgentDeploy: true
        )

        let mode = try await service.connect(server)

        XCTAssertEqual(mode, .agent)
        XCTAssertEqual(bootstrapper.ensureCallCount, 1)
        XCTAssertEqual(agent.connectCallCount, 1)
        XCTAssertEqual(sftp.connectCallCount, 0)
    }
}

private final class BootstrapperSpy: BootstrapperProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var ensureCalls = 0

    var ensureCallCount: Int {
        lock.withLock { ensureCalls }
    }

    func ensure(_ server: ServerConfig) async throws -> TransportMode {
        lock.withLock { ensureCalls += 1 }
        return .agent
    }
}

private final class ConnectionTransportSpy: FileTransport, @unchecked Sendable {
    private let mode: TransportMode
    private let lock = NSLock()
    private var connectCalls = 0

    init(mode: TransportMode) {
        self.mode = mode
    }

    var connectCallCount: Int {
        lock.withLock { connectCalls }
    }

    func connect(_ server: ServerConfig) async throws -> TransportMode {
        lock.withLock { connectCalls += 1 }
        return mode
    }

    func disconnect(_ serverID: UUID) async {}

    func list(
        _ server: ServerConfig,
        path: String,
        showHidden: Bool
    ) async throws -> [RemoteEntry] { [] }

    func stat(_ server: ServerConfig, path: String) async throws -> RemoteEntry {
        throw TransferError(code: "ENOENT", message: "not found")
    }

    func makeDirectory(_ server: ServerConfig, path: String) async throws {}
    func remove(_ server: ServerConfig, path: String, recursive: Bool) async throws {}
    func move(_ server: ServerConfig, from: String, to: String) async throws {}
    func chmod(_ server: ServerConfig, path: String, mode: String) async throws {}
    func homeDirectory(_ server: ServerConfig) async throws -> String { "/home/deploy" }

    func diskSpace(
        _ server: ServerConfig,
        path: String
    ) async throws -> (total: Int64, free: Int64) { (1, 1) }

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

    func hash(_ server: ServerConfig, path: String) async throws -> (String, Int64)? { nil }
}
