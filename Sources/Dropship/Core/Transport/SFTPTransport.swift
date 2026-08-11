import Foundation

protocol FileTransport: RemoteFileService {
    func upload(
        _ server: ServerConfig,
        local: URL,
        remote: String,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws

    func download(
        _ server: ServerConfig,
        remote: String,
        local: URL,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws

    func hash(_ server: ServerConfig, path: String) async throws -> (String, Int64)?
}

final class SFTPTransport: FileTransport {
    private let runner: SSHProcessRunner

    init(runner: SSHProcessRunner = .shared) {
        self.runner = runner
    }

    func connect(_ server: ServerConfig) async throws -> TransportMode {
        try require(try await runner.runSSH(server: server, command: "true"))
        return .sftp
    }

    func disconnect(_ serverID: UUID) async {}

    func list(
        _ server: ServerConfig,
        path: String,
        showHidden: Bool
    ) async throws -> [RemoteEntry] {
        let format = "%f\\0%p\\0%y\\0%s\\0%m\\0%T@\\0%u\\0%g\\0%l\\0"
        let result = try await runner.runSSH(
            server: server,
            command: "find \(shellQuote(path)) -mindepth 1 -maxdepth 1 -printf \(shellQuote(format))"
        )
        try require(result)
        let fields = result.stdout
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var entries: [RemoteEntry] = []
        var index = 0
        while index + 8 < fields.count {
            let name = fields[index]
            let entry = RemoteEntry(
                name: name,
                path: fields[index + 1],
                isDir: fields[index + 2] == "d",
                isSymlink: fields[index + 2] == "l",
                symlinkTarget: fields[index + 8].isEmpty ? nil : fields[index + 8],
                size: Int64(fields[index + 3]) ?? 0,
                mode: normalizedMode(fields[index + 4]),
                modTime: Date(timeIntervalSince1970: Double(fields[index + 5]) ?? 0),
                owner: fields[index + 6],
                group: fields[index + 7]
            )
            if showHidden || !name.hasPrefix(".") { entries.append(entry) }
            index += 9
        }
        return entries.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func stat(_ server: ServerConfig, path: String) async throws -> RemoteEntry {
        let parent = NSString(string: path).deletingLastPathComponent
        let name = NSString(string: path).lastPathComponent
        let entries = try await list(
            server,
            path: parent.isEmpty ? "/" : parent,
            showHidden: true
        )
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw TransferError(code: "ENOENT", message: "Path does not exist: \(path)")
        }
        return entry
    }

    func makeDirectory(_ server: ServerConfig, path: String) async throws {
        try require(try await runner.runSSH(
            server: server,
            command: "mkdir -p -- \(shellQuote(path))"
        ))
    }

    func remove(_ server: ServerConfig, path: String, recursive: Bool) async throws {
        let command = recursive
            ? "rm -rf -- \(shellQuote(path))"
            : "rm -f -- \(shellQuote(path))"
        try require(try await runner.runSSH(server: server, command: command))
    }

    func move(_ server: ServerConfig, from: String, to: String) async throws {
        try require(try await runner.runSSH(
            server: server,
            command: "mv -- \(shellQuote(from)) \(shellQuote(to))"
        ))
    }

    func chmod(_ server: ServerConfig, path: String, mode: String) async throws {
        try require(try await runner.runSSH(
            server: server,
            command: "chmod \(shellQuote(mode)) -- \(shellQuote(path))"
        ))
    }

    func homeDirectory(_ server: ServerConfig) async throws -> String {
        let result = try await runner.runSSH(
            server: server,
            command: "printf %s \"$HOME\""
        )
        try require(result)
        return result.stdoutString
    }

    func diskSpace(
        _ server: ServerConfig,
        path: String
    ) async throws -> (total: Int64, free: Int64) {
        let result = try await runner.runSSH(
            server: server,
            command: "df -Pk -- \(shellQuote(path)) | tail -1 | awk '{print $2*1024, $4*1024}'"
        )
        try require(result)
        let values = result.stdoutString.split(whereSeparator: \ .isWhitespace)
        guard values.count >= 2,
              let total = Int64(values[0]),
              let free = Int64(values[1]) else {
            throw TransferError(code: "EPROTO", message: "Invalid df output")
        }
        return (total, free)
    }

    func upload(
        _ server: ServerConfig,
        local: URL,
        remote: String,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let part = remote + ".dropship-part"
        let parent = NSString(string: remote).deletingLastPathComponent
        let writeCommand: String
        if offset > 0 {
            writeCommand = "dd of=\(shellQuote(part)) bs=1048576 seek=\(offset / 1_048_576) skip=0 conv=notrunc status=none"
        } else {
            writeCommand = "cat > \(shellQuote(part))"
        }
        let command = """
        set -e
        mkdir -p -- \(shellQuote(parent))
        \(writeCommand)
        mv -f -- \(shellQuote(part)) \(shellQuote(remote))
        """
        try await runner.streamUpload(
            server: server,
            command: command,
            source: local,
            offset: offset,
            cancellation: cancellation,
            progress: progress
        )
    }

    func download(
        _ server: ServerConfig,
        remote: String,
        local: URL,
        offset: Int64,
        compress: Bool,
        cancellation: TransferCancellation,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let command = offset > 0
            ? "tail -c +\(offset + 1) -- \(shellQuote(remote))"
            : "cat -- \(shellQuote(remote))"
        try await runner.streamDownload(
            server: server,
            command: command,
            destination: local,
            offset: offset,
            cancellation: cancellation,
            progress: progress
        )
    }

    func hash(_ server: ServerConfig, path: String) async throws -> (String, Int64)? {
        let result = try await runner.runSSH(
            server: server,
            command: "test -f \(shellQuote(path)) && printf '%s ' \"$(wc -c < \(shellQuote(path)))\" && shasum -a 256 -- \(shellQuote(path)) | cut -d' ' -f1",
            timeout: 120
        )
        if result.status != 0 { return nil }
        let parts = result.stdoutString.split(whereSeparator: \ .isWhitespace)
        guard parts.count == 2, let size = Int64(parts[0]) else { return nil }
        return (String(parts[1]), size)
    }

    private func normalizedMode(_ mode: String) -> String {
        String(repeating: "0", count: max(0, 4 - mode.count)) + mode
    }

    private func require(_ result: ProcessResult) throws {
        guard result.status == 0 else {
            throw CoreProcessError.failed(result.status, result.stderrString)
        }
    }
}
