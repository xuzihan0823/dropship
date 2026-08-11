import Foundation

private let agentPath = "\"$HOME/.local/share/dropship/agent\""

private actor AgentControlSession {
    private let server: ServerConfig
    private let runner: SSHProcessRunner
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var bufferedOutput = Data()

    init(server: ServerConfig, runner: SSHProcessRunner) {
        self.server = server
        self.runner = runner
    }

    func start() throws {
        guard process == nil else { return }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = runner.sshArguments(
            for: server,
            command: "\(agentPath) --stdio"
        )
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw CoreProcessError.launch(error.localizedDescription)
        }
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        drainStderr(stderr.fileHandleForReading)
    }

    func stop() {
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        bufferedOutput.removeAll(keepingCapacity: false)
    }

    func request(op: String, args: [String: Any]) throws -> [String: Any] {
        try start()
        let id = UUID().uuidString
        let request: [String: Any] = ["id": id, "op": op, "args": args]
        var encoded = try JSONSerialization.data(withJSONObject: request)
        encoded.append(0x0A)
        guard let input else {
            throw TransferError(code: "EPROTO", message: "Agent stdin is closed")
        }
        do {
            try input.write(contentsOf: encoded)
        } catch {
            stop()
            throw error
        }

        let line = try readLine()
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["id"] as? String == id,
              let ok = object["ok"] as? Bool else {
            throw TransferError(code: "EPROTO", message: "Invalid agent response")
        }
        if !ok {
            let remoteError = object["error"] as? [String: Any]
            let code = remoteError?["code"] as? String ?? "EINTERNAL"
            let message = remoteError?["message"] as? String ?? "Agent operation failed"
            throw TransferError(
                code: code,
                message: message,
                retryable: ["ESIZE", "EHASH", "EINTERNAL"].contains(code)
            )
        }
        return object["data"] as? [String: Any] ?? [:]
    }

    private func readLine() throws -> Data {
        guard let output else {
            throw TransferError(code: "EPROTO", message: "Agent stdout is closed")
        }
        while true {
            if let newline = bufferedOutput.firstIndex(of: 0x0A) {
                let line = bufferedOutput[..<newline]
                bufferedOutput.removeSubrange(...newline)
                return Data(line)
            }
            let data = output.availableData
            guard !data.isEmpty else {
                let status = process?.terminationStatus ?? -1
                stop()
                throw CoreProcessError.failed(status, "Agent control session closed")
            }
            bufferedOutput.append(data)
        }
    }

    nonisolated private func drainStderr(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async {
            while !handle.availableData.isEmpty {}
        }
    }
}

final class AgentTransport: FileTransport {
    private let runner: SSHProcessRunner
    private let lock = NSLock()
    private var sessions: [UUID: AgentControlSession] = [:]

    init(runner: SSHProcessRunner = .shared) {
        self.runner = runner
    }

    func connect(_ server: ServerConfig) async throws -> TransportMode {
        let session = session(for: server)
        let hello = try await session.request(op: "hello", args: [:])
        guard hello["protocol"] as? Int == 1 else {
            throw TransferError(code: "EPROTO", message: "Agent protocol version mismatch")
        }
        return .agent
    }

    func disconnect(_ serverID: UUID) async {
        let session = removeSession(for: serverID)
        await session?.stop()
    }

    func list(
        _ server: ServerConfig,
        path: String,
        showHidden: Bool
    ) async throws -> [RemoteEntry] {
        let data = try await request(
            server,
            op: "list",
            args: ["path": path, "showHidden": showHidden]
        )
        guard let entries = data["entries"] as? [[String: Any]] else {
            throw TransferError(code: "EPROTO", message: "Agent list response has no entries")
        }
        return try entries.map(decodeEntry)
    }

    func stat(_ server: ServerConfig, path: String) async throws -> RemoteEntry {
        let data = try await request(server, op: "stat", args: ["path": path])
        guard let entry = data["entry"] as? [String: Any] else {
            throw TransferError(code: "EPROTO", message: "Agent stat response has no entry")
        }
        return try decodeEntry(entry)
    }

    func makeDirectory(_ server: ServerConfig, path: String) async throws {
        _ = try await request(
            server,
            op: "mkdir",
            args: ["path": path, "parents": true]
        )
    }

    func remove(_ server: ServerConfig, path: String, recursive: Bool) async throws {
        _ = try await request(
            server,
            op: "remove",
            args: ["path": path, "recursive": recursive]
        )
    }

    func move(_ server: ServerConfig, from: String, to: String) async throws {
        _ = try await request(server, op: "move", args: ["from": from, "to": to])
    }

    func chmod(_ server: ServerConfig, path: String, mode: String) async throws {
        _ = try await request(server, op: "chmod", args: ["path": path, "mode": mode])
    }

    func homeDirectory(_ server: ServerConfig) async throws -> String {
        let data = try await request(server, op: "realpath", args: ["path": "~"])
        guard let path = data["path"] as? String else {
            throw TransferError(code: "EPROTO", message: "Agent realpath response has no path")
        }
        return path
    }

    func diskSpace(
        _ server: ServerConfig,
        path: String
    ) async throws -> (total: Int64, free: Int64) {
        let data = try await request(server, op: "space", args: ["path": path])
        guard let total = int64(data["totalBytes"]),
              let free = int64(data["freeBytes"]) else {
            throw TransferError(code: "EPROTO", message: "Invalid agent space response")
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
        let values = try local.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw TransferError(code: "ENOENT", message: "Cannot read local file size")
        }
        var command = "\(agentPath) --recv --path \(shellQuote(remote)) --expect-size \(fileSize) --offset \(offset)"
        if compress { command += " --compress gzip" }
        do {
            try await runner.streamUpload(
                server: server,
                command: command,
                source: local,
                offset: offset,
                cancellation: cancellation,
                progress: progress
            )
        } catch CoreProcessError.failed(_, let stderr) {
            throw agentTransferError(stderr)
        }
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
        var command = "\(agentPath) --send --path \(shellQuote(remote)) --offset \(offset)"
        if compress { command += " --compress gzip" }
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
        do {
            let data = try await request(
                server,
                op: "hash",
                args: ["path": path, "algo": "blake3"]
            )
            guard let hash = data["hash"] as? String,
                  let size = int64(data["size"]) else {
                throw TransferError(code: "EPROTO", message: "Invalid agent hash response")
            }
            return (hash, size)
        } catch let error as TransferError where error.code == "ENOENT" {
            return nil
        }
    }

    private func removeSession(for serverID: UUID) -> AgentControlSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.removeValue(forKey: serverID)
    }

    private func session(for server: ServerConfig) -> AgentControlSession {
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[server.id] { return session }
        let session = AgentControlSession(server: server, runner: runner)
        sessions[server.id] = session
        return session
    }

    private func request(
        _ server: ServerConfig,
        op: String,
        args: [String: Any]
    ) async throws -> [String: Any] {
        try await session(for: server).request(op: op, args: args)
    }

    private func decodeEntry(_ value: [String: Any]) throws -> RemoteEntry {
        guard let name = value["name"] as? String,
              let path = value["path"] as? String,
              let isDirectory = value["isDir"] as? Bool,
              let isSymlink = value["isSymlink"] as? Bool,
              let size = int64(value["size"]),
              let mode = value["mode"] as? String,
              let modificationTime = int64(value["modTime"]) else {
            throw TransferError(code: "EPROTO", message: "Invalid agent entry")
        }
        let target = value["symlinkTarget"] as? String
        return RemoteEntry(
            name: name,
            path: path,
            isDir: isDirectory,
            isSymlink: isSymlink,
            symlinkTarget: target?.isEmpty == true ? nil : target,
            size: size,
            mode: mode,
            modTime: Date(timeIntervalSince1970: TimeInterval(modificationTime)),
            owner: value["owner"] as? String ?? "",
            group: value["group"] as? String ?? ""
        )
    }

    private func agentTransferError(_ stderr: String) -> TransferError {
        for line in stderr.components(separatedBy: .newlines).reversed() where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "error",
                  let code = object["code"] as? String else { continue }
            return TransferError(
                code: code,
                message: object["message"] as? String ?? stderr,
                retryable: ["ESIZE", "EHASH", "EINTERNAL"].contains(code)
            )
        }
        return transferError(from: CoreProcessError.failed(1, stderr))
    }

    private func int64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }
}

final class RemoteFileServiceImpl: FileTransport {
    private let sftp: SFTPTransport
    private let agent: AgentTransport
    private let bootstrapper: Bootstrapper
    private let lock = NSLock()
    private var modes: [UUID: TransportMode] = [:]

    init(
        sftp: SFTPTransport = SFTPTransport(),
        agent: AgentTransport = AgentTransport(),
        bootstrapper: Bootstrapper = Bootstrapper()
    ) {
        self.sftp = sftp
        self.agent = agent
        self.bootstrapper = bootstrapper
    }

    func connect(_ server: ServerConfig) async throws -> TransportMode {
        do {
            _ = try await bootstrapper.ensure(server)
            let mode = try await agent.connect(server)
            setMode(mode, for: server.id)
            return mode
        } catch {
            _ = try await sftp.connect(server)
            setMode(.sftp, for: server.id)
            return .sftp
        }
    }

    func disconnect(_ serverID: UUID) async {
        setMode(nil, for: serverID)
        await agent.disconnect(serverID)
        await sftp.disconnect(serverID)
    }

    func list(_ server: ServerConfig, path: String, showHidden: Bool) async throws -> [RemoteEntry] {
        try await transport(for: server).list(server, path: path, showHidden: showHidden)
    }

    func stat(_ server: ServerConfig, path: String) async throws -> RemoteEntry {
        try await transport(for: server).stat(server, path: path)
    }

    func makeDirectory(_ server: ServerConfig, path: String) async throws {
        try await transport(for: server).makeDirectory(server, path: path)
    }

    func remove(_ server: ServerConfig, path: String, recursive: Bool) async throws {
        try await transport(for: server).remove(server, path: path, recursive: recursive)
    }

    func move(_ server: ServerConfig, from: String, to: String) async throws {
        try await transport(for: server).move(server, from: from, to: to)
    }

    func chmod(_ server: ServerConfig, path: String, mode: String) async throws {
        try await transport(for: server).chmod(server, path: path, mode: mode)
    }

    func homeDirectory(_ server: ServerConfig) async throws -> String {
        try await transport(for: server).homeDirectory(server)
    }

    func diskSpace(_ server: ServerConfig, path: String) async throws -> (total: Int64, free: Int64) {
        try await transport(for: server).diskSpace(server, path: path)
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
        try await transport(for: server).upload(
            server,
            local: local,
            remote: remote,
            offset: offset,
            compress: compress,
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
        try await transport(for: server).download(
            server,
            remote: remote,
            local: local,
            offset: offset,
            compress: compress,
            cancellation: cancellation,
            progress: progress
        )
    }

    func hash(_ server: ServerConfig, path: String) async throws -> (String, Int64)? {
        try await transport(for: server).hash(server, path: path)
    }

    private func transport(for server: ServerConfig) -> FileTransport {
        mode(for: server.id) == .agent ? agent : sftp
    }

    private func mode(for serverID: UUID) -> TransportMode? {
        lock.lock()
        defer { lock.unlock() }
        return modes[serverID]
    }

    private func setMode(_ mode: TransportMode?, for serverID: UUID) {
        lock.lock()
        modes[serverID] = mode
        lock.unlock()
    }
}
