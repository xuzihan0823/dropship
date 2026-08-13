import Foundation
import Network

// ============================================================
// App 内置收件端点。
//
// 只监听 127.0.0.1 的随机端口，由 ssh -R 反向隧道从服务器侧接入。
// 因为不绑任何真实网卡，macOS 应用防火墙不会弹"允许接入网络连接"。
//
// 手写最小 HTTP/1.1：只认 PUT/POST + Content-Length + Bearer token。
// 这不是通用 HTTP 服务器，面越小越不容易出洞。
// ============================================================

final class InboxServer: @unchecked Sendable {
    /// 收到一个完整文件。
    struct Received: Sendable {
        let serverID: UUID
        let filename: String
        let url: URL
        let bytes: Int64
    }

    enum StartError: Error, LocalizedError {
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let reason): return "收件端点启动失败：\(reason)"
            }
        }
    }

    /// 单文件上限，超过直接 413。防止误操作把磁盘打满。
    static let maxFileBytes: Int64 = 8 << 30
    /// 请求头上限。不发 \r\n\r\n 的连接不能把内存吃光。
    static let maxHeaderBytes = 16 * 1024
    /// 同时处理的连接数上限。
    static let maxConnections = 8
    /// 落盘前要求的额外余量，避免刚好填满磁盘。
    static let freeSpaceHeadroom: Int64 = 64 << 20
    /// 未完成的 .part 保留多久。超期在下次启动时清掉。
    static let stalePartAge: TimeInterval = 7 * 24 * 3600

    let inboxDirectory: URL
    /// 未完成的文件先落在这里，校验通过才 rename 出去。
    let stagingDirectory: URL

    /// 收到完整文件后回调。在内部队列上调用，接收方需自行切回主线程。
    var onReceive: (@Sendable (Received) -> Void)?

    fileprivate let queue = DispatchQueue(label: "com.dropship.inbox", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var tokenToServer: [String: UUID] = [:]
    private var serverToToken: [UUID: String] = [:]
    /// 正在处理的连接。必须强持有，否则 handler 立刻被释放。
    private var connections: [ObjectIdentifier: InboxConnection] = [:]

    init(inboxDirectory: URL) {
        self.inboxDirectory = inboxDirectory
        self.stagingDirectory = inboxDirectory.appendingPathComponent(".incoming", isDirectory: true)
    }

    // MARK: - 生命周期

    var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    /// 幂等启动，返回实际监听的端口。
    func start() async throws -> UInt16 {
        if let existing = port { return existing }

        // 调用方通常在主线程上 await，建目录和清过期 .part 别占着主线程做。
        try await Task.detached(priority: .utility) { [self] in
            try ensureDirectories()
            purgeStaleParts()
        }.value

        let parameters = NWParameters.tcp
        // 关键：把监听地址钉死在回环，服务器那头只能通过 ssh -R 隧道进来。
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartError.listenerFailed(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let resumed = ResumeOnce()
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let value = listener.port?.rawValue else {
                        resumed.fail(continuation, StartError.listenerFailed("未能获得端口"))
                        return
                    }
                    resumed.succeed(continuation, value)
                case .failed(let error):
                    self?.clearPort()
                    resumed.fail(continuation, StartError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    self?.clearPort()
                    resumed.fail(continuation, StartError.listenerFailed("监听已取消"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        store(listener: listener, port: boundPort)
        return boundPort
    }

    private func store(listener: NWListener, port: UInt16) {
        lock.lock()
        self.listener = listener
        boundPort = port
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        let active = Array(connections.values)
        self.listener = nil
        boundPort = nil
        tokenToServer.removeAll()
        serverToToken.removeAll()
        connections.removeAll()
        lock.unlock()
        listener?.cancel()
        for handler in active { handler.cancel() }
    }

    private func clearPort() {
        lock.lock()
        boundPort = nil
        lock.unlock()
    }

    // MARK: - 每台服务器一把 token

    /// 为一台服务器签发新 token，旧的立即失效。token 同时也是推送方的身份。
    @discardableResult
    func register(_ serverID: UUID) -> String {
        let token = Self.makeToken()
        lock.lock()
        if let old = serverToToken[serverID] { tokenToServer.removeValue(forKey: old) }
        serverToToken[serverID] = token
        tokenToServer[token] = serverID
        lock.unlock()
        return token
    }

    func unregister(_ serverID: UUID) {
        lock.lock()
        if let old = serverToToken.removeValue(forKey: serverID) {
            tokenToServer.removeValue(forKey: old)
        }
        lock.unlock()
    }

    var hasRegistrations: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !serverToToken.isEmpty
    }

    /// 定长时间比对，且不因命中提前 break —— 耗时与 token 数量无关。
    fileprivate func serverID(forToken token: String) -> UUID? {
        let provided = Array(token.utf8)
        lock.lock()
        let known = tokenToServer
        lock.unlock()

        var match: UUID?
        for (candidate, serverID) in known {
            let expected = Array(candidate.utf8)
            var difference = provided.count ^ expected.count
            for index in 0..<min(provided.count, expected.count) {
                difference |= Int(provided[index] ^ expected[index])
            }
            if difference == 0 { match = serverID }
        }
        return match
    }

    private static func makeToken() -> String {
        // SystemRandomNumberGenerator 在 Apple 平台是密码学安全的。
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: - 连接接纳

    private func accept(_ connection: NWConnection) {
        // 必须自己持有 handler：NWConnection 的回调全是 [weak self]，
        // 不留强引用的话对象在 start() 返回那一刻就被释放，回调全成空转。
        let handler = InboxConnection(connection: connection, server: self)
        lock.lock()
        let overLimit = connections.count >= Self.maxConnections
        if !overLimit { connections[ObjectIdentifier(handler)] = handler }
        lock.unlock()

        guard !overLimit else {
            connection.cancel()
            return
        }
        handler.start()
    }

    fileprivate func connectionFinished(_ handler: InboxConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(handler))
        lock.unlock()
    }

    fileprivate func deliver(_ received: Received) {
        onReceive?(received)
    }

    // MARK: - 落地

    /// 收件目录可能被用户在 Finder 中删除；每个上传开始前都重新确保目录存在。
    fileprivate func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    /// 把校验通过的 .part 挪到收件箱，返回最终 URL。重名不覆盖，自动 name-1.ext。
    fileprivate func promote(partURL: URL, preferredName: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let destination = Self.availableURL(in: inboxDirectory, name: preferredName)
        try FileManager.default.moveItem(at: partURL, to: destination)
        return destination
    }

    /// 目标卷剩余空间是否放得下。
    fileprivate func hasRoom(for bytes: Int64) -> Bool {
        guard let values = try? inboxDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else {
            return true  // 查不到就不拦，交给写盘时的真实错误
        }
        return Int64(available) > bytes + Self.freeSpaceHeadroom
    }

    static func availableURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(next)
            suffix += 1
            if suffix > 9999 {
                candidate = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
                break
            }
        }
        return candidate
    }

    /// 把推送方给的任意字符串压成一个安全的裸文件名。
    ///
    /// 这里是路径穿越的唯一防线：先百分号解码再取 lastPathComponent，
    /// 顺序反了 `%2F` 会解出新的分隔符。
    static func sanitize(_ raw: String) -> String {
        var value = raw
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        if let fragment = value.firstIndex(of: "#") { value = String(value[..<fragment]) }
        value = value.removingPercentEncoding ?? value
        value = value.replacingOccurrences(of: "\0", with: "")

        var name = (value as NSString).lastPathComponent
        // NSString 对纯 "/" 会原样返回 "/"，先归零再走下面的空值兜底
        if name == "/" { name = "" }
        // lastPathComponent 已经吃掉了 ../，残留的分隔符再兜一层
        name = name.replacingOccurrences(of: "/", with: "_")
        name = name.replacingOccurrences(of: ":", with: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.components(separatedBy: .controlCharacters).joined()

        if name.isEmpty || name == "." || name == ".." { name = "untitled" }
        // 不让推送方在收件箱里造隐藏文件
        if name.hasPrefix(".") { name = "_" + name }
        return truncate(name, toUTF8Bytes: 200)
    }

    private static func truncate(_ name: String, toUTF8Bytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(16))
        var base = (name as NSString).deletingPathExtension
        while base.utf8.count + suffix.utf8.count > limit, !base.isEmpty {
            base.removeLast()
        }
        return base.isEmpty ? "untitled\(suffix)" : base + suffix
    }

    private func purgeStaleParts() {
        let cutoff = Date().addingTimeInterval(-Self.stalePartAge)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

// MARK: - 一次性 resume 保护

/// NWListener 的 stateUpdateHandler 会被反复调用，continuation 只能 resume 一次。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    func succeed(_ continuation: CheckedContinuation<UInt16, Error>, _ value: UInt16) {
        if claim() { continuation.resume(returning: value) }
    }

    func fail(_ continuation: CheckedContinuation<UInt16, Error>, _ error: Error) {
        if claim() { continuation.resume(throwing: error) }
    }
}

// MARK: - 单个连接

private final class InboxConnection: @unchecked Sendable {
    private enum Phase { case headers, body, done }

    private let connection: NWConnection
    private let server: InboxServer

    private var phase: Phase = .headers
    private var buffer = Data()
    private var handle: FileHandle?
    private var partURL: URL?
    private var expectedBytes: Int64 = 0
    private var writtenBytes: Int64 = 0
    private var serverID: UUID?
    private var filename = "untitled"
    private var finished = false

    init(connection: NWConnection, server: InboxServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.abort()
            default:
                break
            }
        }
        connection.start(queue: server.queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if error != nil { self.abort(); return }
            if isComplete { self.endOfStream(); return }
            if !self.finished { self.receive() }
        }
    }

    // MARK: 解析

    private func ingest(_ data: Data) {
        guard !finished else { return }
        switch phase {
        case .headers:
            buffer.append(data)
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > InboxServer.maxHeaderBytes {
                    respond(431, code: "EPROTO", message: "请求头过大")
                }
                return
            }
            let head = Data(buffer[buffer.startIndex..<separator.lowerBound])
            let leftover = Data(buffer[separator.upperBound...])
            buffer = Data()
            beginBody(head: head, leftover: leftover)
        case .body:
            writeBody(data)
        case .done:
            break
        }
    }

    private func beginBody(head: Data, leftover: Data) {
        guard let request = Self.parseHead(head) else {
            respond(400, code: "EPROTO", message: "无法解析请求行")
            return
        }
        guard request.method == "PUT" || request.method == "POST" else {
            respond(405, code: "EPROTO", message: "只接受 PUT / POST")
            return
        }

        guard let authorization = request.headers["authorization"],
              authorization.lowercased().hasPrefix("bearer "),
              let matched = server.serverID(forToken: String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)) else {
            respond(401, code: "EACCES", message: "token 无效或隧道已关闭")
            return
        }
        serverID = matched

        if request.headers["transfer-encoding"] != nil {
            respond(411, code: "EPROTO", message: "只接受带 Content-Length 的请求；目录请先打包成文件再传")
            return
        }
        guard let lengthText = request.headers["content-length"], let length = Int64(lengthText) else {
            respond(411, code: "EPROTO", message: "缺少 Content-Length")
            return
        }
        guard length >= 0, length <= InboxServer.maxFileBytes else {
            respond(413, code: "EPROTO", message: "文件超过上限 \(InboxServer.maxFileBytes) 字节")
            return
        }
        do {
            try server.ensureDirectories()
        } catch {
            respond(500, code: "EINTERNAL", message: "无法创建收件箱：\(error.localizedDescription)")
            return
        }
        guard server.hasRoom(for: length) else {
            respond(507, code: "ENOSPC", message: "Mac 磁盘空间不足")
            return
        }

        // 文件名优先取 X-Dropship-Name（base64），避免路径里的空格和中文被 HTTP 请求行截断。
        if let encoded = request.headers["x-dropship-name"],
           let decoded = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespaces)),
           let text = String(data: decoded, encoding: .utf8), !text.isEmpty {
            filename = InboxServer.sanitize(text)
        } else {
            filename = InboxServer.sanitize(request.target)
        }

        let part = server.stagingDirectory.appendingPathComponent("\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let opened = try? FileHandle(forWritingTo: part) else {
            respond(500, code: "EINTERNAL", message: "无法创建临时文件")
            return
        }
        partURL = part
        handle = opened
        expectedBytes = length
        phase = .body

        // curl 对 >1KB 的 PUT body 默认发 Expect: 100-continue。
        // 不回这一句，它每次都要白等 1 秒才开始发数据。
        if request.headers["expect"]?.lowercased().contains("100-continue") == true {
            send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), thenClose: false)
        }

        if length == 0 {
            complete()
        } else if !leftover.isEmpty {
            writeBody(leftover)
        }
    }

    private func writeBody(_ data: Data) {
        guard !finished, let handle else { return }
        let remaining = expectedBytes - writtenBytes
        guard remaining > 0 else { return }
        let slice = data.count <= Int(remaining) ? data : data.prefix(Int(remaining))
        do {
            try handle.write(contentsOf: slice)
        } catch {
            respond(500, code: "EINTERNAL", message: "写入失败：\(error.localizedDescription)")
            return
        }
        writtenBytes += Int64(slice.count)
        if writtenBytes >= expectedBytes { complete() }
    }

    private func complete() {
        guard !finished, let part = partURL else { return }
        try? handle?.close()
        handle = nil

        // 到这里字节数已经与 Content-Length 相符，才允许挪进收件箱。
        // 这条"先 .part 再校验再 rename"的规矩来自 PROTOCOL.md 2.2 —— 当初
        // 半截文件覆盖掉服务器原文件的事故就是漏了这一步。
        let destination: URL
        do {
            destination = try server.promote(partURL: part, preferredName: filename)
        } catch {
            respond(500, code: "EINTERNAL", message: "落地失败：\(error.localizedDescription)")
            return
        }
        partURL = nil

        server.deliver(
            InboxServer.Received(
                serverID: serverID ?? UUID(),
                filename: destination.lastPathComponent,
                url: destination,
                bytes: writtenBytes
            )
        )

        let payload: [String: Any] = [
            "ok": true,
            "name": destination.lastPathComponent,
            "bytes": writtenBytes
        ]
        respond(201, json: payload)
    }

    /// 对端关闭了连接。
    private func endOfStream() {
        guard !finished else { return }
        // 响应已经在发送途中，等 send 的 completion 收尾，别把连接提前掐了
        if phase == .done { return }
        if phase == .body, writtenBytes < expectedBytes {
            // 少收了字节。保留 .part、绝不 rename —— 宁可留个半成品，
            // 也不能让收件箱里出现一个看起来完整的截断文件。
            try? handle?.close()
            handle = nil
            respond(
                400,
                code: "ESIZE",
                message: "收到 \(writtenBytes) 字节，声明 \(expectedBytes) 字节，已保留 .part 未落地"
            )
            return
        }
        finish()
    }

    private func abort() {
        guard !finished else { return }
        finished = true
        try? handle?.close()
        handle = nil
        // partURL 故意不删：留作事故现场，由 InboxServer 的过期清理负责回收。
        connection.cancel()
        server.connectionFinished(self)
    }

    /// 供 InboxServer.stop() 强制收尾。
    fileprivate func cancel() {
        abort()
    }

    // MARK: 响应

    private func respond(_ status: Int, code: String, message: String) {
        respond(status, json: ["ok": false, "code": code, "message": message])
    }

    private func respond(_ status: Int, json: [String: Any]) {
        guard !finished else { return }
        phase = .done
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status) \(Self.reason(status))\r\n".utf8)
        response.append(Data("Content-Type: application/json\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        send(response, thenClose: true)
    }

    private func send(_ data: Data, thenClose: Bool) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            if thenClose { self?.finish() }
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        try? handle?.close()
        handle = nil
        connection.cancel()
        server.connectionFinished(self)
    }

    // MARK: 请求头

    private struct Request {
        let method: String
        let target: String
        let headers: [String: String]
    }

    private static func parseHead(_ data: Data) -> Request? {
        // 非 UTF-8 字节用替换字符兜底，不让整个请求因为一个坏字节就失败
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard requestLine.count >= 2 else { return nil }

        let method = requestLine[0].uppercased()
        // 路径里可能有未转义的空格，所以取"第一个和最后一个之间"的全部，
        // 而不是简单按空格切三段。
        let target: String
        if requestLine.count >= 3, requestLine[requestLine.count - 1].hasPrefix("HTTP/") {
            target = requestLine[1..<(requestLine.count - 1)].joined(separator: " ")
        } else {
            target = requestLine[1]
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if headers[key] == nil { headers[key] = value }
        }
        return Request(method: method, target: target, headers: headers)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 507: return "Insufficient Storage"
        default: return "OK"
        }
    }
}
