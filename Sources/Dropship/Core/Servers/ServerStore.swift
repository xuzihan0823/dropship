import Foundation

@MainActor
final class ServerStore: ServerStoreService, ObservableObject {
    @Published private(set) var servers: [ServerConfig] = []
    @Published private var states: [UUID: ConnectionState] = [:]

    /// 由连接编排方（AppEnvironment）写入，SwiftUI 借此刷新侧边栏状态。
    func setState(_ state: ConnectionState, for serverID: UUID) {
        states[serverID] = state
    }

    private let fileManager: FileManager
    private let configURL: URL
    private let storeURL: URL

    init(
        fileManager: FileManager = .default,
        configURL: URL? = nil,
        storeURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        self.configURL = configURL ?? home.appendingPathComponent(".ssh/config")
        self.storeURL = storeURL ?? home.appendingPathComponent(
            "Library/Application Support/Dropship/servers.json"
        )
        if let data = try? Data(contentsOf: self.storeURL),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved
        }
    }

    func parseSSHConfig() throws -> [ServerConfig] {
        var blocks: [SSHHostBlock] = []
        var visited = Set<String>()
        try parseFile(configURL, blocks: &blocks, visited: &visited)

        return blocks.flatMap { block in
            block.patterns.compactMap { alias in
                guard !alias.contains("*"),
                      !alias.contains("?"),
                      !alias.hasPrefix("!") else {
                    return nil
                }
                let values = resolvedValues(for: alias, blocks: blocks)
                return ServerConfig(
                    alias: alias,
                    hostname: values["hostname"] ?? alias,
                    port: Int(values["port"] ?? "22") ?? 22,
                    username: values["user"] ?? "",
                    identityFile: values["identityfile"].map(expandPath),
                    proxyJump: values["proxyjump"],
                    source: .sshConfig
                )
            }
        }
    }

    func add(_ server: ServerConfig) {
        servers.append(server)
    }

    func update(_ server: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
    }

    func remove(_ serverID: UUID) {
        servers.removeAll { $0.id == serverID }
        states.removeValue(forKey: serverID)
    }

    func connectionState(of serverID: UUID) -> ConnectionState {
        states[serverID] ?? .disconnected
    }

    func save() throws {
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers).write(to: storeURL, options: .atomic)
    }

    private func parseFile(
        _ url: URL,
        blocks: inout [SSHHostBlock],
        visited: inout Set<String>
    ) throws {
        let normalized = url.standardizedFileURL.path
        guard visited.insert(normalized).inserted else { return }
        guard fileManager.fileExists(atPath: normalized) else { return }

        let text = try String(contentsOf: url, encoding: .utf8)
        var currentPatterns: [String]?
        var currentOptions: [String: String] = [:]

        func flush() {
            if let patterns = currentPatterns {
                blocks.append(SSHHostBlock(patterns: patterns, options: currentOptions))
            }
            currentPatterns = nil
            currentOptions = [:]
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(
                maxSplits: 1,
                whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }
            )
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = unquote(String(parts[1]).trimmingCharacters(in: .whitespaces))

            switch key {
            case "host":
                flush()
                currentPatterns = splitArguments(value)
            case "include":
                flush()
                for pattern in splitArguments(value) {
                    for includeURL in includeFiles(pattern, relativeTo: url) {
                        try parseFile(includeURL, blocks: &blocks, visited: &visited)
                    }
                }
            default:
                if currentPatterns != nil, currentOptions[key] == nil {
                    currentOptions[key] = value
                }
            }
        }
        flush()
    }

    private func resolvedValues(
        for alias: String,
        blocks: [SSHHostBlock]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for block in blocks where matches(alias, patterns: block.patterns) {
            for (key, value) in block.options where result[key] == nil {
                result[key] = value
            }
        }
        return result
    }

    private func matches(_ alias: String, patterns: [String]) -> Bool {
        var positiveMatch = false
        for rawPattern in patterns {
            let negated = rawPattern.hasPrefix("!")
            let pattern = negated ? String(rawPattern.dropFirst()) : rawPattern
            if wildcardMatch(alias, pattern: pattern) {
                if negated { return false }
                positiveMatch = true
            }
        }
        return positiveMatch
    }

    private func wildcardMatch(_ value: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(escaped)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func includeFiles(_ pattern: String, relativeTo config: URL) -> [URL] {
        var path = expandPath(pattern)
        if !path.hasPrefix("/") {
            path = config.deletingLastPathComponent().appendingPathComponent(path).path
        }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let filenamePattern = url.lastPathComponent
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { wildcardMatch($0, pattern: filenamePattern) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private func expandPath(_ value: String) -> String {
        NSString(string: value).expandingTildeInPath
    }

    private func stripComment(_ line: String) -> String {
        var quoted = false
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == "#", !quoted { return String(line[..<index]) }
        }
        return line
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2,
              value.first == "\"",
              value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private func splitArguments(_ value: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { arguments.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { arguments.append(current) }
        return arguments
    }
}

private struct SSHHostBlock {
    let patterns: [String]
    let options: [String: String]
}
