import Foundation

// ============================================================
// 一台服务器的反向隧道：常驻 `ssh -N -R 0:127.0.0.1:<收件端口>`。
//
// Mac 在 NAT 后面，服务器连不进来，所以通路必须由 Mac 这头发起。
// 建成之后服务器上的 127.0.0.1:<remotePort> 就通到 App 的收件端点。
//
// 进程退出即按退避重连；开关关掉才真正停。
// ============================================================

final class ReverseTunnel: @unchecked Sendable {
    enum Event: Sendable {
        /// 隧道已通，remotePort 是服务器回环地址上的端口。
        case active(remotePort: Int)
        /// 断了，正在等待重连。
        case retrying(reason: String, afterSeconds: Double)
        case stopped
    }

    /// 退避上限。隧道是后台设施，不值得为它把重连打得很密。
    static let maxBackoff: Double = 30

    private let server: ServerConfig
    private let localPort: UInt16
    private let runner: SSHProcessRunner
    private let sshExecutableURL: URL
    private let onEvent: @Sendable (Event) -> Void

    private let queue = DispatchQueue(label: "com.dropship.tunnel", qos: .utility)
    private let wakeup = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var process: Process?
    private var started = false
    private var stopped = false

    init(
        server: ServerConfig,
        localPort: UInt16,
        runner: SSHProcessRunner = .shared,
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.server = server
        self.localPort = localPort
        self.runner = runner
        self.sshExecutableURL = sshExecutableURL
        self.onEvent = onEvent
    }

    // MARK: - 生命周期

    func start() {
        lock.lock()
        guard !started, !stopped else { lock.unlock(); return }
        started = true
        lock.unlock()
        queue.async { [weak self] in self?.loop() }
    }

    func stop() {
        lock.lock()
        stopped = true
        let running = process
        lock.unlock()
        wakeup.signal()
        if running?.isRunning == true { running?.terminate() }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: - 重连循环

    private func loop() {
        var backoff: Double = 1
        while !isStopped {
            let outcome = runOnce()
            if isStopped { break }

            switch outcome {
            case .establishedThenDied:
                // 曾经通过，说明配置和权限都没问题，是网络抖动，快速重连。
                backoff = 1
            case .neverEstablished:
                backoff = min(backoff * 2, Self.maxBackoff)
            }
            onEvent(.retrying(reason: outcome.reason, afterSeconds: backoff))
            _ = wakeup.wait(timeout: .now() + backoff)
        }
        onEvent(.stopped)
    }

    private enum Outcome {
        case establishedThenDied(String)
        case neverEstablished(String)

        var reason: String {
            switch self {
            case .establishedThenDied(let value), .neverEstablished(let value): return value
            }
        }
    }

    /// 起一次 ssh，阻塞到它退出。
    private func runOnce() -> Outcome {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = sshExecutableURL
        process.arguments = arguments()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        let established = Established()
        let reader = TunnelStderrReader(handle: errorPipe.fileHandleForReading) { [weak self] line in
            guard let self, let port = Self.allocatedPort(in: line) else { return }
            guard established.markOnce() else { return }
            self.onEvent(.active(remotePort: port))
        }

        do {
            try process.run()
        } catch {
            // 进程没起来，管道的写端还留在本进程里。不主动关掉，
            // 读取线程会永远阻塞在 read 上，waitForTail 也就永远回不来。
            try? errorPipe.fileHandleForWriting.close()
            _ = reader.waitForTail()
            return .neverEstablished("无法启动 ssh：\(error.localizedDescription)")
        }

        lock.lock()
        self.process = process
        let alreadyStopped = stopped
        lock.unlock()
        if alreadyStopped { process.terminate() }

        process.waitUntilExit()
        let tail = reader.waitForTail()

        lock.lock()
        self.process = nil
        lock.unlock()

        let detail = Self.describe(status: process.terminationStatus, stderr: tail)
        return established.value
            ? .establishedThenDied(detail)
            : .neverEstablished(detail)
    }

    // MARK: - 参数

    func arguments() -> [String] {
        var base = runner.sshArguments(for: server)
        let host = base.removeLast()

        // ssh 对每个参数取「首次出现」的值，所以覆盖项必须放在基础参数前面。
        //
        // 这里刻意不复用 ControlMaster 的共享连接：隧道要的是确定的生命周期，
        // 进程一杀转发就没。挂在共享 master 上的话，master 何时退出不归我们管，
        // 还可能在服务器上留下已经没人用的转发端口。
        var arguments = [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            // 转发建不起来（比如服务器 sshd 关了 AllowTcpForwarding）就直接退出，
            // 不要留一个"连上了但其实没通"的假象。
            "-o", "ExitOnForwardFailure=yes",
            // 常驻进程不能卡在看不见的密码提示上，失败要立刻可见。
            "-o", "BatchMode=yes"
        ]
        arguments += base
        arguments += ["-N", "-R", "0:127.0.0.1:\(localPort)"]
        arguments.append(host)
        return arguments
    }

    /// OpenSSH 默认 LogLevel 就是 INFO，动态端口的分配结果会打在 stderr 上：
    /// `Allocated port 45678 for remote forward to 127.0.0.1:51234`
    static func allocatedPort(in line: String) -> Int? {
        guard line.contains("Allocated port") else { return nil }
        let digits = line.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        guard let port = Int(digits), port > 0, port <= 65535 else { return nil }
        return port
    }

    private static func describe(status: Int32, stderr: String) -> String {
        let meaningful = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.contains("Allocated port") }
        if let meaningful, !meaningful.isEmpty { return meaningful }
        return "ssh 退出，状态码 \(status)"
    }
}

// MARK: - 状态标记

private final class Established: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }

    /// 只有第一次返回 true，避免重复上报 active。
    func markOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if marked { return false }
        marked = true
        return true
    }
}

// MARK: - stderr 读取

/// 持续排空 ssh 的 stderr 并按行回调。
///
/// 没有直接用 SSHProcess 里的 ProcessPipeCollector：那个只在进程结束后交付数据，
/// 而这里必须在进程还活着的时候就把 "Allocated port" 解析出来。排空管道防死锁
/// 这一层的职责是一样的，只是多了增量分行。
final class TunnelStderrReader: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private let handle: FileHandle
    private let onLine: @Sendable (String) -> Void
    private let byteLimit: Int
    private var tail = Data()
    private var pending = Data()
    private var finished = false

    init(handle: FileHandle, byteLimit: Int = 65_536, onLine: @escaping @Sendable (String) -> Void) {
        self.handle = handle
        self.byteLimit = byteLimit
        self.onLine = onLine
        group.enter()
        handle.readabilityHandler = { [weak self] readable in
            guard let self else { return }
            let chunk = readable.availableData
            guard !chunk.isEmpty else {
                readable.readabilityHandler = nil
                self.finishReading()
                return
            }
            self.consume(chunk)
        }
    }

    /// 等读取线程结束，返回保留的 stderr 尾部。
    func waitForTail() -> String {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: tail, as: UTF8.self)
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        tail.append(chunk)
        if tail.count > byteLimit { tail = Data(tail.suffix(byteLimit)) }
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        lock.unlock()
        for line in lines { deliver(line) }
    }

    /// 流结束时最后一行可能没有换行符，补交一次。
    private func finishReading() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let remainder = pending
        pending = Data()
        lock.unlock()
        if !remainder.isEmpty {
            deliver(String(decoding: remainder, as: UTF8.self))
        }
        group.leave()
    }

    private func deliver(_ line: String) {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard !trimmed.isEmpty else { return }
        onLine(trimmed)
    }
}
