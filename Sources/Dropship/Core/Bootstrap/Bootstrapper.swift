import Foundation

struct Bootstrapper {
    static let agentVersion = "1.0.1"

    private let runner: SSHProcessRunner
    private let resourcesURL: URL?
    private let expectedVersion: String

    init(
        runner: SSHProcessRunner = .shared,
        resourcesURL: URL? = Bundle.main.resourceURL,
        expectedVersion: String = Bootstrapper.agentVersion
    ) {
        self.runner = runner
        self.resourcesURL = resourcesURL
        self.expectedVersion = expectedVersion
    }

    func ensure(_ server: ServerConfig) async throws -> TransportMode {
        let architectureResult = try await runner.runSSH(
            server: server,
            command: "uname -m"
        )
        try requireSuccess(architectureResult)

        let architecture = try agentArchitecture(
            String(decoding: architectureResult.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if try await installedVersion(on: server) == expectedVersion {
            return .agent
        }

        guard let resourcesURL else {
            throw TransferError(
                code: "ENOENT",
                message: "Application resource directory is unavailable"
            )
        }
        let binaryURL = resourcesURL
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("agent-linux-\(architecture)")
        guard FileManager.default.isReadableFile(atPath: binaryURL.path) else {
            throw TransferError(
                code: "ENOENT",
                message: "Bundled agent is missing: \(binaryURL.path)"
            )
        }

        let binary = try Data(contentsOf: binaryURL, options: .mappedIfSafe)
        let installCommand = """
        set -e
        dir="$HOME/.local/share/dropship"
        mkdir -p "$dir"
        cat > "$dir/agent.dropship-new"
        chmod 0755 "$dir/agent.dropship-new"
        mv -f "$dir/agent.dropship-new" "$dir/agent"
        """
        let installResult = try await runner.runSSH(
            server: server,
            command: installCommand,
            input: binary,
            timeout: 120
        )
        try requireSuccess(installResult)

        guard try await installedVersion(on: server) == expectedVersion else {
            throw TransferError(
                code: "EPROTO",
                message: "Installed agent did not report version \(expectedVersion)"
            )
        }
        return .agent
    }

    private func installedVersion(on server: ServerConfig) async throws -> String? {
        let result = try await runner.runSSH(
            server: server,
            command: "\"$HOME/.local/share/dropship/agent\" --version",
            timeout: 15
        )
        guard result.status == 0 else { return nil }
        let output = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "dropship-agent "
        guard output.hasPrefix(prefix) else { return nil }
        return String(output.dropFirst(prefix.count))
    }

    private func agentArchitecture(_ uname: String) throws -> String {
        switch uname {
        case "x86_64", "amd64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        default:
            throw TransferError(
                code: "EPROTO",
                message: "Unsupported Linux architecture: \(uname)"
            )
        }
    }

    private func requireSuccess(_ result: ProcessResult) throws {
        guard result.status == 0 else {
            throw CoreProcessError.failed(result.status, result.stderrString)
        }
    }
}
