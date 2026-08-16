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

/// 远程系统列目录的方言。SFTP 降级路径靠 shell 命令取目录元数据，
/// 而各家 find/stat 的选项并不通用，连接后探测一次决定用哪套。
enum RemoteListingFlavor: String, Sendable {
    /// GNU findutils：一次 find -printf 拿全字段，最快，覆盖绝大多数 Linux。
    case gnuFind
    /// GNU coreutils / busybox 的 stat -c，用于没有 find -printf 的精简系统。
    case gnuStat
    /// macOS / FreeBSD 的 stat -f。
    case bsdStat
}

final class SFTPTransport: FileTransport {
    private let runner: SSHProcessRunner
    private let flavors = ListingFlavorCache()

    /// 每台服务器探测一次即可，断开时清掉，换机器或换系统不会用到旧结论。
    private actor ListingFlavorCache {
        private var byServer: [UUID: RemoteListingFlavor] = [:]
        func get(_ id: UUID) -> RemoteListingFlavor? { byServer[id] }
        func set(_ flavor: RemoteListingFlavor, for id: UUID) { byServer[id] = flavor }
        func clear(_ id: UUID) { byServer.removeValue(forKey: id) }
    }

    init(runner: SSHProcessRunner = .shared) {
        self.runner = runner
    }

    func connect(_ server: ServerConfig) async throws -> TransportMode {
        try require(try await runner.runSSH(server: server, command: "true"))
        return .sftp
    }

    func disconnect(_ serverID: UUID) async {
        await flavors.clear(serverID)
    }

    func list(
        _ server: ServerConfig,
        path: String,
        showHidden: Bool
    ) async throws -> [RemoteEntry] {
        let flavor = try await listingFlavor(server)
        let result = try await runner.runSSH(
            server: server,
            command: Self.listCommand(path: path, flavor: flavor)
        )
        try require(result)
        let entries = flavor == .gnuFind
            ? Self.parseGNUFindListing(result.stdout)
            : Self.parseStatListing(result.stdout)
        return Self.finalize(entries, showHidden: showHidden)
    }

    // MARK: - 目录列举的跨平台适配

    /// 探测一次并缓存。`find -printf` 是 GNU findutils 专有，BSD（macOS/FreeBSD）
    /// 和部分精简系统上不存在，直接用会导致降级模式下列目录直接失败。
    private func listingFlavor(_ server: ServerConfig) async throws -> RemoteListingFlavor {
        if let cached = await flavors.get(server.id) { return cached }
        let result = try await runner.runSSH(server: server, command: Self.probeCommand)
        let raw = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let flavor = RemoteListingFlavor(rawValue: raw) else {
            throw TransferError(
                code: "EPROTO",
                message: "远程系统既没有 GNU find -printf，也没有可用的 stat，"
                    + "SFTP 降级模式无法列目录。请让 agent 正常部署后重试。"
            )
        }
        await flavors.set(flavor, for: server.id)
        return flavor
    }

    private static let probeCommand = "if find . -maxdepth 0 -printf '' 2>/dev/null; "
        + "then echo gnuFind; "
        + "elif stat -c %s . >/dev/null 2>&1; then echo gnuStat; "
        + "elif stat -f %z . >/dev/null 2>&1; then echo bsdStat; "
        + "else echo unsupported; fi"

    /// stat 两种方言统一输出同样的 7 字段记录，共用一个解析器。
    /// 分隔符用 US(0x1F)：文件名里不能有 `/` 和 NUL，但可以有换行和 `|`，
    /// 而 BSD stat 没有 NUL 输出选项，US 是现实中最稳妥的选择。
    private static let unitSeparator = "\u{1F}"

    private static func listCommand(path: String, flavor: RemoteListingFlavor) -> String {
        let base = "find \(shellQuote(path)) -mindepth 1 -maxdepth 1"
        let sep = unitSeparator
        switch flavor {
        case .gnuFind:
            let format = "%f\\0%p\\0%y\\0%s\\0%m\\0%T@\\0%u\\0%g\\0%l\\0"
            return "\(base) -printf \(shellQuote(format))"
        case .gnuStat:
            let format = "%n\(sep)%s\(sep)%a\(sep)%Y\(sep)%U\(sep)%G\(sep)%F\(sep)"
            return "\(base) -exec stat -c \(shellQuote(format)) {} +"
        case .bsdStat:
            // %Mp%Lp 只取 setuid 位和权限位，与 GNU 的 %a 对齐（%Op 会带上文件类型位）
            let format = "%N\(sep)%z\(sep)%Mp%Lp\(sep)%m\(sep)%Su\(sep)%Sg\(sep)%HT\(sep)"
            return "\(base) -exec stat -f \(shellQuote(format)) {} +"
        }
    }

    static func parseGNUFindListing(_ stdout: Data) -> [RemoteEntry] {
        let fields = stdout
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var entries: [RemoteEntry] = []
        var index = 0
        while index + 8 < fields.count {
            entries.append(
                RemoteEntry(
                    name: fields[index],
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
            )
            index += 9
        }
        return entries
    }

    static func parseStatListing(_ stdout: Data) -> [RemoteEntry] {
        let fields = String(decoding: stdout, as: UTF8.self)
            .components(separatedBy: unitSeparator)
        var entries: [RemoteEntry] = []
        var index = 0
        while index + 6 < fields.count {
            // stat 每处理完一个文件补一个换行，它会粘在下一条记录的首字段前面。
            // 只剥掉这一个前导换行，文件名自身的换行得以保留。
            var fullPath = fields[index]
            if fullPath.hasPrefix("\n") { fullPath.removeFirst() }

            let kind = fields[index + 6].lowercased()
            entries.append(
                RemoteEntry(
                    name: (fullPath as NSString).lastPathComponent,
                    path: fullPath,
                    isDir: kind.contains("directory"),
                    isSymlink: kind.contains("symbolic link"),
                    symlinkTarget: nil,
                    size: Int64(fields[index + 1]) ?? 0,
                    mode: normalizedMode(fields[index + 2]),
                    modTime: Date(timeIntervalSince1970: Double(fields[index + 3]) ?? 0),
                    owner: fields[index + 4],
                    group: fields[index + 5]
                )
            )
            index += 7
        }
        return entries
    }

    static func finalize(_ entries: [RemoteEntry], showHidden: Bool) -> [RemoteEntry] {
        entries
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted {
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

    static func uploadCommand(remote: String, offset: Int64, expectedSize: Int64) -> String {
        let part = remote + ".dropship-part"
        let parent = NSString(string: remote).deletingLastPathComponent
        let writeCommand = offset > 0
            ? "dd if=/dev/null of=\(shellQuote(part)) bs=1 seek=\(offset) 2>/dev/null\ncat >> \(shellQuote(part))"
            : "cat > \(shellQuote(part))"
        return """
        set -e
        mkdir -p -- \(shellQuote(parent))
        \(writeCommand)
        size=$(wc -c < \(shellQuote(part)) | tr -d '[:space:]')
        if [ "$size" != "\(expectedSize)" ]; then
            printf 'ESIZE: expected %s bytes, got %s\\n' \(expectedSize) "$size" >&2
            exit 1
        fi
        mv -f -- \(shellQuote(part)) \(shellQuote(remote))
        """
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
        let command = Self.uploadCommand(
            remote: remote,
            offset: offset,
            expectedSize: Int64(fileSize)
        )
        do {
            try await runner.streamUpload(
                server: server,
                command: command,
                source: local,
                offset: offset,
                cancellation: cancellation,
                progress: progress
            )
        } catch CoreProcessError.failed(let status, let stderr) {
            throw transferError(from: CoreProcessError.failed(status, stderr))
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

    private static func normalizedMode(_ mode: String) -> String {
        String(repeating: "0", count: max(0, 4 - mode.count)) + mode
    }

    private func require(_ result: ProcessResult) throws {
        guard result.status == 0 else {
            throw CoreProcessError.failed(result.status, result.stderrString)
        }
    }
}
