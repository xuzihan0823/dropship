import SwiftUI

// ============================================================
// 服务器表单弹窗：添加 / 编辑。
// ============================================================

struct ServerFormSheet: View {
    enum Mode {
        case add
        case edit(ServerConfig)
    }

    let mode: Mode
    let onSave: (ServerConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var alias: String = ""
    @State private var displayName: String = ""
    @State private var hostname: String = ""
    @State private var port: String = "22"
    @State private var username: String = "root"
    @State private var identityFile: String = ""
    @State private var proxyJump: String = ""
    @State private var defaultRemotePath: String = ""
    @State private var allowAgentDeploy = true
    @State private var showValidationError = false

    init(mode: Mode, onSave: @escaping (ServerConfig) -> Void) {
        self.mode = mode
        self.onSave = onSave
        if case .edit(let s) = mode {
            _alias = State(initialValue: s.alias)
            _displayName = State(initialValue: s.displayName)
            _hostname = State(initialValue: s.hostname)
            _port = State(initialValue: String(s.port))
            _username = State(initialValue: s.username)
            _identityFile = State(initialValue: s.identityFile ?? "")
            _proxyJump = State(initialValue: s.proxyJump ?? "")
            _defaultRemotePath = State(initialValue: s.defaultRemotePath ?? "")
            _allowAgentDeploy = State(initialValue: s.allowAgentDeploy)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("基本") {
                    TextField("别名", text: $alias)
                        .disabled(isEditingSSHSourced)
                    TextField("显示名（可选）", text: $displayName)
                    TextField("主机", text: $hostname)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    HStack {
                        TextField("用户名", text: $username)
                        TextField("端口", text: $port)
                            .frame(width: 80)
                    }
                }
                Section {
                    TextField("私钥路径", text: $identityFile)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("认证")
                } footer: {
                    Text("留空则交由 ssh 自行选择；也可填 ~/.ssh/id_ed25519 或绝对路径")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("网络") {
                    TextField("跳板机（ProxyJump）", text: $proxyJump)
                        .help("可选，填写其他服务器的别名或 user@host:port")
                }
                Section("默认目录") {
                    TextField("连接后打开的远程目录", text: $defaultRemotePath)
                        .help("留空则使用服务器家目录")
                }
                Section("Agent 部署") {
                    Toggle("允许部署并执行 Dropship agent", isOn: $allowAgentDeploy)
                    Text("开启后，连接时会将版本 \(Bootstrapper.agentVersion) 的 Dropship agent 二进制上传到 $HOME/.local/share/dropship/agent，设置权限 0755 并执行。关闭后不会上传或执行 agent，而是直接使用 SFTP 降级路径；该路径速度较慢，传输后只有字节数校验，没有哈希校验。修改此设置后需要断开并重新连接才会生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showValidationError {
                    Section {
                        Label("请填写别名、主机、用户名", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .formStyle(.grouped)
            footer
        }
        // 表单较长，放开滚动并留足高度：此前写死 540 且禁用滚动，
        // 导致「默认目录」一节被窗口下沿切断，只露出半行字。
        .frame(width: 480, height: 600)
    }

    @ViewBuilder
    private var header: some View {
        Text(isEditing ? "编辑服务器" : "添加服务器")
            .font(.headline)
            .padding(.vertical, 12)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if isEditing {
                Text("来源：\(sourceLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "保存" : "添加") {
                validateAndSave()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isEditingSSHSourced: Bool {
        if case .edit(let s) = mode, s.source == .sshConfig { return true }
        return false
    }

    private var sourceLabel: String {
        if case .edit(let s) = mode {
            return s.source == .sshConfig ? "~/.ssh/config" : "手动添加"
        }
        return "手动添加"
    }

    private func validateAndSave() {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedAlias.isEmpty, !trimmedHost.isEmpty, !trimmedUser.isEmpty else {
            showValidationError = true
            return
        }
        var server: ServerConfig
        if case .edit(let existing) = mode {
            server = existing
            server.alias = trimmedAlias
            server.displayName = displayName.isEmpty ? trimmedAlias : displayName
            server.hostname = trimmedHost
            server.username = trimmedUser
            server.port = Int(port) ?? 22
            server.identityFile = identityFile.isEmpty ? nil : identityFile
            server.proxyJump = proxyJump.isEmpty ? nil : proxyJump
            server.defaultRemotePath = defaultRemotePath.isEmpty ? nil : defaultRemotePath
            server.allowAgentDeploy = allowAgentDeploy
        } else {
            server = ServerConfig(
                alias: trimmedAlias,
                displayName: displayName.isEmpty ? trimmedAlias : displayName,
                hostname: trimmedHost,
                port: Int(port) ?? 22,
                username: trimmedUser,
                identityFile: identityFile.isEmpty ? nil : identityFile,
                proxyJump: proxyJump.isEmpty ? nil : proxyJump,
                source: .manual,
                defaultRemotePath: defaultRemotePath.isEmpty ? nil : defaultRemotePath,
                allowAgentDeploy: allowAgentDeploy
            )
        }
        onSave(server)
        dismiss()
    }
}

// MARK: - SSH 导入弹窗

struct ImportSSHConfigSheet: View {
    let candidates: [ServerConfig]
    let onImport: ([ServerConfig]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            Text("从 SSH Config 导入")
                .font(.headline)
                .padding(.vertical, 12)

            if candidates.isEmpty {
                ContentUnavailableView(
                    "无可导入条目",
                    systemImage: "doc.questionmark",
                    description: Text("未在 ~/.ssh/config 中发现主机配置")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates) { c in
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(c.alias).font(.body)
                            Text("\(c.username)@\(c.hostname):\(c.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected.contains(c.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selected.contains(c.id) {
                            selected.remove(c.id)
                        } else {
                            selected.insert(c.id)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入 \(selected.count) 台") {
                    let chosen = candidates.filter { selected.contains($0.id) }
                    onImport(chosen)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 400)
    }
}
