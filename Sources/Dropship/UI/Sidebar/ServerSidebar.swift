import SwiftUI
import AppKit

// ============================================================
// 服务器侧边栏：列出所有服务器、连接状态、右键菜单、底部操作按钮。
// ============================================================

struct ServerSidebar: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var store: ServerStore
    @State private var editingServer: ServerConfig?
    @State private var showingAddSheet = false
    @State private var importCandidates: [ServerConfig]?
    @State private var showImportSheet = false

    init(store: ServerStore) {
        self.store = store
    }

    var body: some View {
        List(selection: $env.selectedServerID) {
            Section {
                ForEach(store.servers) { server in
                    ServerRow(server: server, state: store.connectionState(of: server.id))
                        .tag(server.id)
                        .contextMenu {
                            contextMenu(for: server)
                        }
                }
            } header: {
                Text("服务器").font(.headline)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .sheet(isPresented: $showingAddSheet) {
            ServerFormSheet(mode: .add) { newServer in
                store.add(newServer)
            }
        }
        .sheet(item: $editingServer) { server in
            ServerFormSheet(mode: .edit(server)) { updated in
                store.update(updated)
            }
        }
        .sheet(isPresented: $showImportSheet) {
            if let candidates = importCandidates {
                ImportSSHConfigSheet(candidates: candidates) { chosen in
                    for c in chosen { store.add(c) }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for server: ServerConfig) -> some View {
        let state = store.connectionState(of: server.id)
        switch state {
        case .disconnected, .failed:
            Button {
                env.toggleConnection(server.id)
            } label: {
                Label("连接", systemImage: "link")
            }
        case .connecting:
            Button(role: .destructive) {
                store.setState(.disconnected, for: server.id)
            } label: {
                Label("取消连接", systemImage: "xmark")
            }
        case .connected:
            Button {
                env.toggleConnection(server.id)
            } label: {
                Label("断开", systemImage: "link.badge.plus")
            }
        }
        Divider()
        Button {
            editingServer = server
        } label: {
            Label("编辑…", systemImage: "pencil")
        }
        Button {
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(server.hostname, forType: .string)
            #endif
        } label: {
            Label("拷贝主机地址", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) {
            store.remove(server.id)
        } label: {
            Label("删除", systemImage: "trash")
        }
        .disabled(server.source == .sshConfig)
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    importCandidates = (try? store.parseSSHConfig()) ?? []
                    showImportSheet = true
                } label: {
                    Label("从 SSH 导入", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showingAddSheet = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(.regularMaterial)
    }
}

// MARK: - 单行服务器

private struct ServerRow: View {
    let server: ServerConfig
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if server.source == .sshConfig {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("来自 ~/.ssh/config")
                    }
                }
                subtitle
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusDot: some View {
        switch state {
        case .disconnected:
            Circle().fill(.secondary).frame(width: 9, height: 9)
        case .connecting:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .connected(let transport):
            Circle()
                .fill(Color.green)
                .frame(width: 9, height: 9)
                .help("已连接 · \(transport == .agent ? "Agent 通道" : "SFTP 降级")")
        case .failed:
            Circle().fill(Color.red).frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch state {
        case .disconnected:
            Text(server.hostname)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting:
            Text("连接中…")
                .font(.caption)
                .foregroundStyle(.orange)
        case .connected(let transport):
            HStack(spacing: 4) {
                Image(systemName: transport == .agent ? "bolt.fill" : "tortoise")
                    .font(.caption2)
                Text(transport == .agent ? "Agent" : "SFTP 降级")
            }
            .font(.caption)
            .foregroundStyle(transport == .agent ? Color.green : Color.orange)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(Color.red)
                .lineLimit(1)
        }
    }
}
