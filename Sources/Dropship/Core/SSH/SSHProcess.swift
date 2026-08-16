import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum CoreProcessError: Error {
    case launch(String)
    case timedOut
    case failed(Int32, String)
    case cancelled
}

/// 没有这层实现时，连接失败会一路走到 `error.localizedDescription`，界面上只剩
/// "The operation couldn't be completed. (Dropship.CoreProcessError error 2.)"，
/// 真正的 ssh stderr 明明已经带在 payload 里却看不到。
extension CoreProcessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .launch(let message):
            return "无法启动 ssh：\(message)"
        case .timedOut:
            return "ssh 命令超时"
        case .cancelled:
            return "操作已取消"
        case .failed(let status, let stderr):
            let detail = Self.condense(stderr)
            return detail.isEmpty ? "ssh 以退出码 \(status) 结束" : detail
        }
    }

    /// ssh 的 stderr 常是多行且带 \r，侧边栏只有一行，压成一句并去掉噪声行。
    private static func condense(_ stderr: String) -> String {
        let noise = [
            "Warning: Permanently added",
            "Pseudo-terminal will not be allocated",
        ]
        return stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !noise.contains(where: line.hasPrefix)
            }
            .joined(separator: " · ")
    }
}

/// Continuously drains a child-process pipe so verbose progress output cannot
/// fill the kernel buffer and deadlock the transfer. Only a bounded tail is
/// retained because callers need the final protocol error, not every progress
/// event from a multi-hour transfer.
private final class ProcessPipeCollector: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private let byteLimit: Int
    private var buffered = Data()

    init(handle: FileHandle, byteLimit: Int = 1_048_576) {
        self.byteLimit = byteLimit
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            while true {
                guard let chunk = try? handle.read(upToCount: 65_536),
                      !chunk.isEmpty else { return }
                lock.lock()
                buffered.append(chunk)
                if buffered.count > byteLimit {
                    buffered = Data(buffered.suffix(byteLimit))
                }
                lock.unlock()
            }
        }
    }

    func waitForData() -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return buffered
    }
}

final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var isCancelled = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let cancel = isCancelled
        lock.unlock()
        if cancel { process.terminate() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let runningProcess = process
        lock.unlock()
        runningProcess?.terminate()
    }
}

final class SSHProcessRunner: @unchecked Sendable {
    static let shared = SSHProcessRunner()

    let controlDirectory: URL
    private let sshExecutableURL: URL

    init(
        fileManager: FileManager = .default,
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")
    ) {
        self.sshExecutableURL = sshExecutableURL
        controlDirectory = URL(fileURLWithPath: "/tmp/dropship-\(getuid())", isDirectory: true)
        try? fileManager.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func sshArguments(for server: ServerConfig, command: String? = nil) -> [String] {
        var arguments = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=600",
            "-o", "ControlPath=\(controlDirectory.path)/control-%C",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "ConnectTimeout=10"
        ]
        if server.port != 22 { arguments += ["-p", String(server.port)] }
        if let identity = server.identityFile, !identity.isEmpty {
            arguments += ["-i", NSString(string: identity).expandingTildeInPath]
        }
        if let jump = server.proxyJump, !jump.isEmpty { arguments += ["-J", jump] }
        let host = server.source == .sshConfig ? server.alias : server.hostname
        arguments.append(server.username.isEmpty ? host : "\(server.username)@\(host)")
        if let command { arguments.append(command) }
        return arguments
    }

    func runSSH(server: ServerConfig, command: String, input: Data? = nil, timeout: TimeInterval = 30) async throws -> ProcessResult {
        try await run(
            executable: sshExecutableURL.path,
            arguments: sshArguments(for: server, command: command),
            input: input,
            timeout: timeout
        )
    }

    func run(executable: String, arguments: [String], input: Data? = nil, timeout: TimeInterval = 30) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.runBlocking(executable, arguments, input, timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runBlocking(_ executable: String, _ arguments: [String], _ input: Data?, _ timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw CoreProcessError.launch(error.localizedDescription) }

        let group = DispatchGroup()
        let lock = NSLock()
        var output = Data()
        var errors = Data()
        func drain(_ handle: FileHandle, outputStream: Bool) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                lock.lock()
                if outputStream { output = data } else { errors = data }
                lock.unlock()
                group.leave()
            }
        }
        drain(stdout.fileHandleForReading, outputStream: true)
        drain(stderr.fileHandleForReading, outputStream: false)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
            try? stdin.fileHandleForWriting.close()
            group.leave()
        }

        let deadline = DispatchTime.now() + timeout
        while process.isRunning && DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            group.wait()
            throw CoreProcessError.timedOut
        }
        process.waitUntilExit()
        group.wait()
        return ProcessResult(status: process.terminationStatus, stdout: output, stderr: errors)
    }

    func streamUpload(server: ServerConfig, command: String, source: URL, offset: Int64, cancellation: TransferCancellation, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await Task.detached {
            let started = try self.start(server, command, cancellation)
            let outputCollector = ProcessPipeCollector(
                handle: started.output.fileHandleForReading,
                byteLimit: 65_536
            )
            let errorCollector = ProcessPipeCollector(handle: started.error.fileHandleForReading)
            do {
                let sourceHandle = try FileHandle(forReadingFrom: source)
                defer { try? sourceHandle.close() }
                try sourceHandle.seek(toOffset: UInt64(offset))
                var sent = offset
                while !cancellation.isCancelled {
                    let data = try sourceHandle.read(upToCount: 262_144) ?? Data()
                    if data.isEmpty { break }
                    try started.input.fileHandleForWriting.write(contentsOf: data)
                    sent += Int64(data.count)
                    progress(sent)
                }
                try? started.input.fileHandleForWriting.close()
                started.process.waitUntilExit()
                _ = outputCollector.waitForData()
                let errors = errorCollector.waitForData()
                if cancellation.isCancelled { throw CoreProcessError.cancelled }
                guard started.process.terminationStatus == 0 else {
                    throw CoreProcessError.failed(started.process.terminationStatus, String(decoding: errors, as: UTF8.self))
                }
            } catch {
                try? started.input.fileHandleForWriting.close()
                if started.process.isRunning { started.process.terminate() }
                started.process.waitUntilExit()
                _ = outputCollector.waitForData()
                let errors = errorCollector.waitForData()
                throw Self.preferRemoteFailure(
                    error,
                    process: started.process,
                    stderr: errors,
                    cancellation: cancellation
                )
            }
        }.value
    }

    func streamDownload(server: ServerConfig, command: String, destination: URL, offset: Int64, cancellation: TransferCancellation, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await Task.detached {
            let started = try self.start(server, command, cancellation)
            let errorCollector = ProcessPipeCollector(handle: started.error.fileHandleForReading)
            try? started.input.fileHandleForWriting.close()
            do {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    FileManager.default.createFile(atPath: destination.path, contents: nil)
                }
                let destinationHandle = try FileHandle(forWritingTo: destination)
                defer { try? destinationHandle.close() }
                if offset == 0 { try destinationHandle.truncate(atOffset: 0) }
                try destinationHandle.seek(toOffset: UInt64(offset))
                var received = offset
                while !cancellation.isCancelled {
                    let data = try started.output.fileHandleForReading.read(upToCount: 262_144) ?? Data()
                    if data.isEmpty { break }
                    try destinationHandle.write(contentsOf: data)
                    received += Int64(data.count)
                    progress(received)
                }
                started.process.waitUntilExit()
                let errors = errorCollector.waitForData()
                if cancellation.isCancelled { throw CoreProcessError.cancelled }
                guard started.process.terminationStatus == 0 else {
                    throw CoreProcessError.failed(started.process.terminationStatus, String(decoding: errors, as: UTF8.self))
                }
            } catch {
                if started.process.isRunning { started.process.terminate() }
                started.process.waitUntilExit()
                let errors = errorCollector.waitForData()
                throw Self.preferRemoteFailure(
                    error,
                    process: started.process,
                    stderr: errors,
                    cancellation: cancellation
                )
            }
        }.value
    }

    /// 读写管道失败（典型是 EPIPE "Broken pipe"）只是**症状**：远端进程先退出了，
    /// 客户端才写不进去。真正的原因写在它的 stderr 里。原先直接抛这个底层 POSIX
    /// 错误，界面上只剩一句 `NSPOSIXErrorDomain Code=32 "Broken pipe"`，
    /// `Permission denied`、`No space left` 这类关键信息全被丢掉。
    ///
    /// 只在远端**确实说了话**时才替换：被我们自己 terminate 掉、或纯本地文件
    /// 读写失败的场景 stderr 为空，那时保留原始错误更有信息量。
    private static func preferRemoteFailure(
        _ error: Error,
        process: Process,
        stderr: Data,
        cancellation: TransferCancellation
    ) -> Error {
        if cancellation.isCancelled { return CoreProcessError.cancelled }
        if case CoreProcessError.cancelled = error { return error }
        let text = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus != 0, !text.isEmpty else { return error }
        return CoreProcessError.failed(process.terminationStatus, text)
    }

    private struct Started { let process: Process; let input: Pipe; let output: Pipe; let error: Pipe }
    private func start(_ server: ServerConfig, _ command: String, _ cancellation: TransferCancellation) throws -> Started {
        let process = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = sshExecutableURL
        process.arguments = sshArguments(for: server, command: command)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { throw CoreProcessError.launch(error.localizedDescription) }
        cancellation.attach(process)
        return Started(process: process, input: input, output: output, error: error)
    }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func transferError(from error: Error) -> TransferError {
    if let error = error as? TransferError { return error }
    if case CoreProcessError.cancelled = error {
        return TransferError(code: "ECANCELLED", message: "Transfer cancelled")
    }

    let message = String(describing: error)
    let knownCodes = [
        "ESIZE", "EHASH", "ENOENT", "EACCES", "EEXIST", "ENOSPC",
        "EISDIR", "ENOTDIR", "EPROTO", "EINTERNAL"
    ]
    let code: String
    if let protocolCode = knownCodes.first(where: { message.contains($0) }) {
        code = protocolCode
    } else if message.localizedCaseInsensitiveContains("No such file") {
        code = "ENOENT"
    } else if message.localizedCaseInsensitiveContains("Permission denied") {
        code = "EACCES"
    } else if message.localizedCaseInsensitiveContains("No space left") {
        code = "ENOSPC"
    } else {
        code = "EINTERNAL"
    }
    return TransferError(
        code: code,
        message: message,
        retryable: ["ESIZE", "EHASH", "EINTERNAL"].contains(code)
    )
}
