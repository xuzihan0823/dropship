import Foundation
import Combine

// ============================================================
// 反向收件隧道的编排层。
//
// 一个共用的收件端点（InboxServer）+ 每台开了开关的服务器一条反向隧道
// （ReverseTunnel）。推送方靠 token 区分身份，一台一把。
//
// 隧道通了之后往服务器写两个文件，让上面的 agent 一行命令就能推回来：
//   ~/.local/share/dropship/inbox.env      端口与 token，0600
//   ~/.local/share/dropship/dropship-send  curl 包装脚本，0755
// 关掉开关时这两个文件会被删除，token 同时作废。
// ============================================================

@MainActor
final class TunnelService: ObservableObject {
    /// 每台服务器的隧道状态。
    @Published private(set) var states: [UUID: TunnelState] = [:]
    /// 服务器推回来的文件，最新的在前。
    @Published private(set) var inbox: [InboxItem] = []

    /// 服务器上的安装目录，与 agent 同一处。
    static let remoteDirectory = "$HOME/.local/share/dropship"
    /// 给用户/agent 看的那行命令。
    static let sendCommand = "~/.local/share/dropship/dropship-send <文件或目录>"

    @Published private(set) var inboxDirectory: URL

    private var inboxServer: InboxServer
    private let runner: SSHProcessRunner
    private let preferencesURL: URL
    private let maxInboxItems = 200
    private var customInboxDirectory: URL?

    private var tunnels: [UUID: ReverseTunnel] = [:]
    private var tunnelTokens: [UUID: String] = [:]
    private var enabledServers: Set<UUID> = []
    private var knownServers: [UUID: ServerConfig] = [:]

    init(
        inboxDirectory: URL? = nil,
        preferencesURL: URL? = nil,
        runner: SSHProcessRunner = .shared
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let resolvedPreferencesURL = preferencesURL ?? home.appendingPathComponent(
            "Library/Application Support/Dropship/tunnels.json"
        )
        let saved = Self.readPreferences(from: resolvedPreferencesURL)
        let savedInbox = saved?.inboxDirectoryPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        let explicitInbox = inboxDirectory?.standardizedFileURL
        let inbox = explicitInbox ?? savedInbox ?? Self.defaultInboxDirectory(home: home)
        self.inboxDirectory = inbox
        self.inboxServer = InboxServer(inboxDirectory: inbox)
        self.runner = runner
        self.preferencesURL = resolvedPreferencesURL
        self.customInboxDirectory = savedInbox
        self.enabledServers = Set(saved?.enabled ?? [])

        for id in enabledServers { states[id] = .disabled }
        configureInboxCallback()
    }

    // MARK: - 查询

    func isEnabled(_ serverID: UUID) -> Bool {
        enabledServers.contains(serverID)
    }

    func state(of serverID: UUID) -> TunnelState {
        states[serverID] ?? .disabled
    }

    func inboxItems(from serverID: UUID) -> [InboxItem] {
        inbox.filter { $0.serverID == serverID }
    }

    // MARK: - 开关

    /// 用户拨动开关。开关状态会持久化，下次连上这台服务器时自动恢复。
    func setEnabled(_ enabled: Bool, for server: ServerConfig) {
        knownServers[server.id] = server
        if enabled {
            enabledServers.insert(server.id)
            savePreferences()
            activate(server)
        } else {
            enabledServers.remove(server.id)
            savePreferences()
            teardown(server, cleanRemote: true)
            states[server.id] = .disabled
        }
    }

    /// 连接建立后调用：开关记着是开的就把隧道重新拉起来。
    func resumeIfEnabled(_ server: ServerConfig) {
        knownServers[server.id] = server
        guard enabledServers.contains(server.id), tunnels[server.id] == nil else { return }
        activate(server)
    }

    /// 断开这台服务器时调用。停隧道但**不动**开关记忆，下次连上还会自动恢复。
    func suspend(_ serverID: UUID) {
        if let server = knownServers[serverID] {
            // 此刻 SSH 主连接还活着，顺手把服务器上的 inbox.env 清掉，
            // 免得留一份指向已经死掉的端口的配置去误导 agent。
            teardown(server, cleanRemote: true)
        } else {
            tunnels.removeValue(forKey: serverID)?.stop()
            tunnelTokens.removeValue(forKey: serverID)
            inboxServer.unregister(serverID)
            stopInboxServerIfIdle()
        }
        states[serverID] = .disabled
    }

    // MARK: - 启停

    private func activate(_ server: ServerConfig) {
        guard tunnels[server.id] == nil else { return }
        states[server.id] = .starting

        Task { [weak self] in
            guard let self else { return }
            let endpoint = self.inboxServer
            let port: UInt16
            do {
                port = try await endpoint.start()
            } catch {
                self.states[server.id] = .failed(Self.describe(error))
                return
            }
            // 中途被关掉了
            guard self.enabledServers.contains(server.id),
                  self.tunnels[server.id] == nil,
                  self.inboxServer === endpoint else { return }

            let token = endpoint.register(server.id)
            let tunnel = ReverseTunnel(server: server, localPort: port, runner: self.runner) { [weak self] event in
                Task { @MainActor in self?.handle(event, for: server, token: token) }
            }
            self.tunnelTokens[server.id] = token
            self.tunnels[server.id] = tunnel
            tunnel.start()
        }
    }

    private func teardown(_ server: ServerConfig, cleanRemote: Bool) {
        let tunnel = tunnels.removeValue(forKey: server.id)
        tunnelTokens.removeValue(forKey: server.id)
        tunnel?.stop()
        inboxServer.unregister(server.id)
        stopInboxServerIfIdle()
        guard cleanRemote, tunnel != nil else { return }
        Task { [runner] in
            // 尽力而为：服务器已经不可达时删不掉也无所谓，token 早就作废了。
            _ = try? await runner.runSSH(
                server: server,
                command: "rm -f \"$HOME/.local/share/dropship/inbox.env\" \"$HOME/.local/share/dropship/dropship-send\"",
                timeout: 15
            )
        }
    }

    private func stopInboxServerIfIdle() {
        if !inboxServer.hasRegistrations { inboxServer.stop() }
    }

    private func handle(_ event: ReverseTunnel.Event, for server: ServerConfig, token: String) {
        guard tunnels[server.id] != nil, tunnelTokens[server.id] == token else { return }
        switch event {
        case .active(let remotePort):
            states[server.id] = .active(remotePort: remotePort)
            // 每次重连远端口都可能变，所以每次 active 都要重写一遍配置。
            Task { [weak self] in
                await self?.provision(server, remotePort: remotePort, token: token)
            }
        case .retrying(let reason, let afterSeconds):
            states[server.id] = .failed("\(reason)（\(Int(afterSeconds)) 秒后重连）")
        case .stopped:
            if states[server.id]?.isActive == true { states[server.id] = .disabled }
        }
    }

    // MARK: - 往服务器写便捷入口

    private func provision(_ server: ServerConfig, remotePort: Int, token: String) async {
        let environment = """
        # Dropship 反向收件隧道 —— 由 Dropship.app 自动写入，关闭隧道时自动删除。
        # 请勿手工编辑。端口在每次重连后都可能变化。
        DROPSHIP_INBOX_URL=http://127.0.0.1:\(remotePort)
        DROPSHIP_INBOX_TOKEN=\(token)
        """
        do {
            try await writeRemoteFile(server, name: "inbox.env", mode: "0600", contents: Data(environment.utf8))
            try await writeRemoteFile(server, name: "dropship-send", mode: "0755", contents: Data(Self.sendScript.utf8))
        } catch {
            states[server.id] = .failed("隧道已通，但写入服务器端脚本失败：\(Self.describe(error))")
        }
    }

    /// 手法与 Bootstrapper 安装 agent 时一致：先写临时名再 mv，避免半截文件被用上。
    private func writeRemoteFile(
        _ server: ServerConfig,
        name: String,
        mode: String,
        contents: Data
    ) async throws {
        let command = """
        set -e
        dir="$HOME/.local/share/dropship"
        mkdir -p "$dir"
        cat > "$dir/\(name).dropship-new"
        chmod \(mode) "$dir/\(name).dropship-new"
        mv -f "$dir/\(name).dropship-new" "$dir/\(name)"
        """
        let result = try await runner.runSSH(server: server, command: command, input: contents, timeout: 30)
        guard result.status == 0 else {
            throw CoreProcessError.failed(result.status, result.stderrString)
        }
    }

    // MARK: - 收件箱

    static func defaultInboxDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Downloads/Dropship", isDirectory: true)
    }

    /// 修改收件箱位置并持久化。正在运行的隧道会换到新的本地收件端点。
    func setInboxDirectory(_ directory: URL) throws {
        try updateInboxDirectory(directory, persistAsCustom: true)
    }

    private func updateInboxDirectory(_ directory: URL, persistAsCustom: Bool) throws {
        guard directory.isFileURL else {
            throw TransferError(code: "EINVAL", message: "收件箱必须是本机文件夹")
        }
        let normalized = directory.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: normalized, withIntermediateDirectories: true)
        } catch {
            throw TransferError(code: "EACCES", message: "无法创建收件箱：\(error.localizedDescription)")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TransferError(code: "ENOTDIR", message: "选择的位置不是文件夹")
        }
        guard FileManager.default.isWritableFile(atPath: normalized.path) else {
            throw TransferError(code: "EACCES", message: "所选文件夹不可写")
        }

        let previousCustomDirectory = customInboxDirectory
        customInboxDirectory = persistAsCustom ? normalized : nil
        guard savePreferences() else {
            customInboxDirectory = previousCustomDirectory
            throw TransferError(code: "EIO", message: "无法保存收件箱位置")
        }
        if normalized == inboxDirectory.standardizedFileURL { return }

        let restartIDs = Set(tunnels.keys).union(
            enabledServers.filter {
                if case .starting = states[$0] { return true }
                return false
            }
        )
        let serversToRestart = restartIDs.compactMap { knownServers[$0] }
        for server in serversToRestart {
            // 新隧道会覆盖服务器端配置；不要让旧清理任务与新配置竞态。
            teardown(server, cleanRemote: false)
            states[server.id] = .disabled
        }
        inboxServer.stop()

        let replacement = InboxServer(inboxDirectory: normalized)
        inboxServer = replacement
        inboxDirectory = normalized
        customInboxDirectory = persistAsCustom ? normalized : nil
        configureInboxCallback()

        for server in serversToRestart where enabledServers.contains(server.id) {
            activate(server)
        }
    }

    private func configureInboxCallback() {
        inboxServer.onReceive = { [weak self] received in
            Task { @MainActor in self?.append(received) }
        }
    }

    private func append(_ received: InboxServer.Received) {
        inbox.insert(
            InboxItem(
                serverID: received.serverID,
                filename: received.filename,
                url: received.url,
                bytes: received.bytes
            ),
            at: 0
        )
        if inbox.count > maxInboxItems {
            inbox.removeLast(inbox.count - maxInboxItems)
        }
    }

    /// 只清列表，磁盘上的文件不动。
    func clearInbox() {
        inbox.removeAll()
    }

    // MARK: - 开关记忆

    private struct Preferences: Codable {
        var enabled: [UUID]
        var inboxDirectoryPath: String?
    }

    private static func readPreferences(from url: URL) -> Preferences? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    @discardableResult
    private func savePreferences() -> Bool {
        let payload = Preferences(
            enabled: Array(enabledServers),
            inboxDirectoryPath: customInboxDirectory?.path
        )
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: preferencesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: preferencesURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 工具

    static func describe(_ error: Error) -> String {
        if let transfer = error as? TransferError {
            return transfer.message.isEmpty ? transfer.code : transfer.message
        }
        if let process = error as? CoreProcessError, case .failed(let status, let stderr) = process {
            let line = stderr
                .components(separatedBy: .newlines)
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return line ?? "ssh 失败，状态码 \(status)"
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// 服务器端的 curl 包装脚本。
    ///
    /// 用原始字符串字面量（#"""）写：脚本里有 `\n` 这类反斜杠序列，
    /// 普通字面量会把它们当 Swift 转义吃掉。
    static let sendScript = #"""
    #!/bin/sh
    # dropship-send —— 把文件推回 Mac 的 Dropship 收件箱。
    #
    # 由 Dropship.app 打开传输隧道时自动写入，关闭隧道时自动删除。
    # 走 ssh -R 反向隧道，只通到 127.0.0.1，不经过公网。
    #
    # 用法：dropship-send <文件或目录> [更多...]
    set -eu

    env_file="$HOME/.local/share/dropship/inbox.env"
    if [ ! -r "$env_file" ]; then
        echo "dropship-send: 传输隧道未开启（找不到 $env_file）" >&2
        exit 1
    fi
    . "$env_file"

    if [ $# -lt 1 ]; then
        echo "用法: dropship-send <文件或目录> [更多...]" >&2
        exit 2
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "dropship-send: 需要 curl" >&2
        exit 1
    fi

    send_one() {
        src="$1"
        name="$2"
        # 文件名走 base64 头传递：空格和中文放在 HTTP 请求行里会被切断
        encoded=$(printf '%s' "$name" | base64 | tr -d '\n')
        # -T 读普通文件才会带 Content-Length；管道输入会退化成 chunked，收件端点不收
        if curl --fail --silent --show-error --max-time 3600 \
                -H "Authorization: Bearer $DROPSHIP_INBOX_TOKEN" \
                -H "X-Dropship-Name: $encoded" \
                -T "$src" "$DROPSHIP_INBOX_URL/upload" >/dev/null; then
            echo "→ 已送达 Mac 收件箱: $name"
            return 0
        fi
        echo "dropship-send: 推送失败: $name" >&2
        return 1
    }

    status=0
    for target in "$@"; do
        if [ -d "$target" ]; then
            base=$(basename "$target")
            parent=$(dirname "$target")
            archive="${TMPDIR:-/tmp}/dropship-$$-$base.tar.gz"
            # 目录先打包成临时文件再传，避开 chunked
            tar -czf "$archive" -C "$parent" "$base"
            send_one "$archive" "$base.tar.gz" || status=1
            rm -f "$archive"
        elif [ -f "$target" ]; then
            send_one "$target" "$(basename "$target")" || status=1
        else
            echo "dropship-send: 不是文件也不是目录: $target" >&2
            status=1
        fi
    done
    exit $status
    """#
}
