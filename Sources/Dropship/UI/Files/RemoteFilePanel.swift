import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers

// ============================================================
// 远程文件面板：浏览服务器目录、上传/下载、增删改。
// ============================================================

@MainActor
final class RemoteFileViewModel: ObservableObject {
    @Published var path: String = ""
    @Published var entries: [RemoteEntry] = []
    @Published var status: FilePanelStatus = .idle
    @Published var selection: Set<String> = []
    @Published var sortOrder: [KeyPathComparator<FileRow>] = [
        KeyPathComparator(\.dirRank),
        KeyPathComparator(\.name),
    ]
    @Published var history: [String] = []
    @Published var future: [String] = []
    @Published var diskFree: Int64?
    @Published var diskTotal: Int64?

    private var loadTask: Task<Void, Never>?
    private var initialDirectoryRequestID: UUID?

    func navigate(to newPath: String) {
        guard newPath != path else { return }
        if !path.isEmpty { history.append(path) }
        future.removeAll()
        path = newPath
    }

    func goBack() {
        guard let prev = history.popLast() else { return }
        future.append(path)
        path = prev
    }

    var canGoBack: Bool { !history.isEmpty }

    func openEntry(_ entry: RemoteEntry) {
        guard entry.isDir else { return }
        navigate(to: entry.path)
    }

    func load(server: ServerConfig,
              service: any RemoteFileService,
              showHidden: Bool) {
        loadTask?.cancel()
        status = .loading
        let targetPath = path
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let list = service.list(server, path: targetPath, showHidden: showHidden)
                async let disk = service.diskSpace(server, path: targetPath)
                let resolved = try await list
                let (total, free) = try await disk
                await MainActor.run {
                    self.entries = resolved
                    self.diskTotal = total
                    self.diskFree = free
                    self.status = resolved.isEmpty ? .empty : .loaded
                }
            } catch is CancellationError {
                // 取消时保持旧状态
            } catch {
                await MainActor.run {
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func loadInitialDirectory(
        server: ServerConfig,
        service: any RemoteFileService,
        showHidden: Bool
    ) {
        loadTask?.cancel()
        let requestID = UUID()
        initialDirectoryRequestID = requestID
        history.removeAll()
        future.removeAll()
        selection.removeAll()
        entries.removeAll()
        diskFree = nil
        diskTotal = nil
        status = .loading

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let initialPath: String
                if let configured = server.defaultRemotePath,
                   !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    initialPath = configured
                } else {
                    initialPath = try await service.homeDirectory(server)
                }
                try Task.checkCancellation()
                guard self.initialDirectoryRequestID == requestID else { return }

                if self.path == initialPath {
                    self.load(server: server, service: service, showHidden: showHidden)
                } else {
                    self.path = initialPath
                }
            } catch is CancellationError {
                // A newer server selection owns the view now.
            } catch {
                guard self.initialDirectoryRequestID == requestID else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }
}

struct RemoteFilePanel: View {
    private static let dragLogger = Logger(subsystem: "com.dropship.app", category: "drag-drop")
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var queue: TransferQueue
    @StateObject private var vm = RemoteFileViewModel()
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var folderError: String?
    @State private var moveError: String?
    @State private var confirmDelete: [RemoteEntry]?

    init(queue: TransferQueue) {
        self.queue = queue
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbsBar
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .toolbar { toolbar }
        .onChange(of: env.selectedServerID) { _, _ in
            resetToInitialPath()
        }
        .onChange(of: env.selectedConnectionState) { _, state in
            if case .connected = state {
                resetToInitialPath()
            } else {
                vm.path = ""
                vm.entries = []
                vm.status = .idle
            }
        }
        .onChange(of: env.showHiddenFiles) { _, _ in
            reload()
        }
        .onChange(of: vm.path) { _, _ in
            reload()
        }
        // 传输结束后自动刷新，否则刚传上去的文件不会出现在列表里
        .onChange(of: finishedTransferSignature) { _, _ in
            reload()
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") { createFolder() }
        } message: {
            Text("请输入新文件夹名称")
        }
        .alert("创建文件夹失败", isPresented: Binding(
            get: { folderError != nil },
            set: { if !$0 { folderError = nil } }
        )) {
            Button("好", role: .cancel) { folderError = nil }
        } message: {
            Text(folderError ?? "未知错误")
        }
        .alert("移动失败", isPresented: Binding(
            get: { moveError != nil },
            set: { if !$0 { moveError = nil } }
        )) {
            Button("好", role: .cancel) { moveError = nil }
        } message: {
            Text(moveError ?? "未知错误")
        }
        .alert("确认删除", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("取消", role: .cancel) { confirmDelete = nil }
            Button("删除", role: .destructive) {
                if let entries = confirmDelete { deleteEntries(entries) }
                confirmDelete = nil
            }
        } message: {
            if let entries = confirmDelete {
                Text(entries.count == 1
                     ? "确定删除「\(entries[0].name)」？"
                     : "确定删除选中的 \(entries.count) 项？")
            }
        }
        .onAppear { resetToInitialPath() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.status {
        case .idle:
            FilePanelStatusView(status: .idle)
        case .loading where vm.entries.isEmpty:
            FilePanelStatusView(status: .loading)
        case .empty:
            FilePanelStatusView(status: .empty)
        case .failed(let msg):
            FilePanelStatusView(status: .failed(msg))
        default:
            ZStack {
                FileTableView(
                    entries: vm.entries.map(FileRow.init),
                    sortOrder: $vm.sortOrder,
                    selection: $vm.selection,
                    onOpen: { row in
                        if let e = vm.entries.first(where: { $0.path == row.path }) {
                            vm.openEntry(e)
                        }
                    },
                    onContextMenu: { selectedRows in
                        AnyView(contextMenu(for: selectedRows))
                    },
                    dragProviderForRow: { row in
                        guard let server = env.selectedServer else { return NSItemProvider() }
                        return RemoteFileDragPayload(
                            serverID: server.id,
                            path: row.path,
                            name: row.name,
                            isDirectory: row.isDir
                        ).itemProvider()
                    },
                    onDrop: { urls in handleDrop(urls, into: vm.path) },
                    onDropInto: { urls, row in handleDrop(urls, into: row.path) }
                )
                if case .loading = vm.status {
                    ProgressView().controlSize(.regular)
                }
            }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                vm.goBack()
            } label: {
                Label("返回上级", systemImage: "arrow.left")
            }
            .disabled(!vm.canGoBack)

            Button {
                reload()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }

            Button {
                showNewFolder = true
                newFolderName = "新建文件夹"
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }

            Button {
                confirmDelete = vm.entries.filter { vm.selection.contains($0.path) }
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(vm.selection.isEmpty)

            Toggle(isOn: $env.showHiddenFiles) {
                Label("显示隐藏", systemImage: "eye")
            }
            .help("显示隐藏文件")

            if let free = vm.diskFree, let total = vm.diskTotal {
                Text(Formatters.diskUsage(free: free, total: total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("磁盘可用空间")
            }
        }
    }

    @ViewBuilder
    private var breadcrumbsBar: some View {
        let segments = pathSegments(vm.path.isEmpty ? "/" : vm.path)
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .font(.callout)
            Breadcrumbs(segments: segments) { seg in
                vm.navigate(to: seg.path)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func contextMenu(for rows: [FileRow]) -> some View {
        let selected = vm.entries.filter { e in rows.contains { $0.id == e.path } }
        if let directory = selected.first, selected.count == 1, directory.isDir {
            Button {
                vm.openEntry(directory)
            } label: {
                Label("打开文件夹", systemImage: "folder")
            }
            Divider()
        }
        Button {
            downloadSelected(selected)
        } label: {
            Label("下载到本地", systemImage: "arrow.down.circle")
        }
        Divider()
        Button(role: .destructive) {
            confirmDelete = selected
        } label: {
            Label("删除", systemImage: "trash")
        }
        Divider()
        Button {
            if let path = selected.first?.path {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        } label: {
            Label("拷贝路径", systemImage: "doc.on.doc")
        }
        .disabled(selected.count != 1)
    }

    // MARK: - 操作

    private func resetToInitialPath() {
        guard let server = env.selectedServer else {
            vm.path = ""
            vm.entries = []
            vm.status = .idle
            return
        }
        guard case .connected = env.selectedConnectionState else {
            vm.path = ""
            vm.entries = []
            vm.status = .idle
            return
        }
        vm.loadInitialDirectory(
            server: server,
            service: env.remoteFiles,
            showHidden: env.showHiddenFiles
        )
    }

    private func reload() {
        guard let server = env.selectedServer,
              case .connected = env.selectedConnectionState,
              !vm.path.isEmpty else { return }
        vm.load(server: server, service: env.remoteFiles, showHidden: env.showHiddenFiles)
    }

    /// remoteDir 为 nil 时落到当前目录；拖到某个目录行上时传入该行路径。
    /// 已结束传输的指纹。任一任务进入完成/跳过状态，指纹变化，触发列表刷新。
    private var finishedTransferSignature: Int {
        queue.finishedTransferRevision
    }

    private func handleUpload(_ urls: [URL], into remoteDir: String? = nil) {
        let targetKind = remoteDir == nil ? "current" : "directory"
        Self.dragLogger.info("upload callback: urls=\(urls.count, privacy: .public), target=\(targetKind, privacy: .public)")
        guard let server = env.selectedServer else { return }
        env.transferQueue.enqueueUpload(
            localURLs: urls,
            to: server,
            remoteDir: remoteDir ?? vm.path,
            policy: .ask
        )
    }

    private func handleDrop(_ urls: [URL], into targetDirectory: String) {
        let remotePayloads = urls.compactMap(RemoteFileDragPayload.init(dragURL:))
        let localURLs = urls.filter(\.isFileURL)
        Self.dragLogger.info(
            "classified drop: local=\(localURLs.count, privacy: .public), remote=\(remotePayloads.count, privacy: .public)"
        )
        if !localURLs.isEmpty {
            handleUpload(localURLs, into: targetDirectory)
        }
        if !remotePayloads.isEmpty {
            handleRemoteMove(remotePayloads, into: targetDirectory)
        }
    }

    private func handleRemoteMove(
        _ payloads: [RemoteFileDragPayload],
        into targetDirectory: String
    ) {
        guard let server = env.selectedServer, !payloads.isEmpty else { return }
        Task { @MainActor in
            do {
                for payload in payloads {
                    let plan = try RemoteFileMovePlan.make(
                        payload: payload,
                        targetDirectory: targetDirectory,
                        selectedServerID: server.id
                    )

                    do {
                        _ = try await env.remoteFiles.stat(server, path: plan.targetPath)
                        throw RemoteFileMoveError.targetExists(payload.name)
                    } catch let error as TransferError where error.code == "ENOENT" {
                        // The destination is free. Other stat failures must be surfaced.
                    }

                    try await env.remoteFiles.move(
                        server,
                        from: plan.sourcePath,
                        to: plan.targetPath
                    )
                    vm.selection.remove(plan.sourcePath)
                }
                reload()
            } catch {
                moveError = AppEnvironment.describe(error)
                reload()
            }
        }
    }

    private func downloadSelected(_ entries: [RemoteEntry]) {
        guard let server = env.selectedServer else { return }
        let localDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads")
        env.transferQueue.enqueueDownload(
            entries: entries,
            from: server,
            localDir: localDir,
            policy: .ask
        )
    }

    private func deleteEntries(_ entries: [RemoteEntry]) {
        guard let server = env.selectedServer else { return }
        for e in entries {
            Task {
                do {
                    try await env.remoteFiles.remove(server, path: e.path, recursive: e.isDir)
                } catch {
                    // 忽略，最后刷新
                }
                await MainActor.run {
                    vm.selection.remove(e.path)
                    reload()
                }
            }
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            folderError = "文件夹名称不能为空"
            return
        }
        guard name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            folderError = "请输入当前目录下的单个文件夹名称"
            return
        }
        guard let server = env.selectedServer, !vm.path.isEmpty else {
            folderError = "请先连接服务器并打开一个目录"
            return
        }

        let target = (vm.path as NSString).appendingPathComponent(name)
        Task { @MainActor in
            do {
                try await env.remoteFiles.makeDirectory(server, path: target)
                newFolderName = ""
                reload()
            } catch {
                folderError = error.localizedDescription
            }
        }
    }
}
