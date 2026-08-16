import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers

// ============================================================
// 远程文件面板：浏览服务器目录、上传/下载、增删改。
// ============================================================

/// 「下载到本地」的目标目录解析。抽成纯函数，是为了把"绝不回退到硬编码路径"
/// 这条规则钉在测试里--与 UploadDestination 对称：右键下载曾经写死 ~/Downloads，
/// 既不跟本地面板当前目录，也和拖拽下载（落到拖放目标目录）行为不一致。
enum DownloadDestination {
    static func resolve(localDirectory: URL, fileManager: FileManager = .default) -> URL? {
        let path = localDirectory.path
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue,
              fileManager.isWritableFile(atPath: path) else { return nil }
        return localDirectory
    }
}

extension View {
    /// 「message 非 nil 则弹窗，点好清空」的统一错误提示。四个同形弹窗会让
    /// body 的类型检查超时，抽成一个 modifier 才能编译通过。
    func errorAlert(title: String, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("好", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "未知错误")
        }
    }
}

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
    /// 删除失败原因。以前是直接吞掉的，用户只看到列表没变化。
    @State private var deleteError: String?
    /// 下载目标目录不可用时的提示。宁可报错也不静默回退到 ~/Downloads。
    @State private var downloadError: String?
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
        .onChange(of: vm.path) { _, newPath in
            // 同步给本地面板，「上传到远程」要靠它决定目标目录
            env.currentRemotePath = newPath
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
        .errorAlert(title: "创建文件夹失败", message: $folderError)
        .errorAlert(title: "移动失败", message: $moveError)
        .errorAlert(title: "删除失败", message: $deleteError)
        .errorAlert(title: "下载失败", message: $downloadError)
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
            // 空目录下没有表格兜底，占位视图自己要能接收投放
            FilePanelStatusView(status: .empty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .fileDropCatcher { urls in handleDrop(urls, into: vm.path) }
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
            Label(downloadMenuTitle, systemImage: "arrow.down.circle")
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

    /// 菜单里直接写出目标目录，避免用户不清楚文件会落到本地哪里（与 uploadMenuTitle 对称）。
    private var downloadMenuTitle: String {
        guard DownloadDestination.resolve(localDirectory: env.currentLocalDirectory) != nil else {
            return "下载到本地"
        }
        return "下载到 \(Self.displayPath(env.currentLocalDirectory))"
    }

    /// 家目录显示为 ~，其余显示绝对路径。
    private static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func downloadSelected(_ entries: [RemoteEntry]) {
        guard let server = env.selectedServer else { return }
        // 目标目录取本地面板当前所在目录。以前这里写死 ~/Downloads，
        // 既不跟本地面板，也和拖拽下载（落到拖放目标目录）行为不一致。
        guard let localDir = DownloadDestination.resolve(localDirectory: env.currentLocalDirectory) else {
            downloadError = "本地目标目录不可用（不存在、不是目录或不可写）：\(Self.displayPath(env.currentLocalDirectory))\n请在左侧本地面板打开一个有效目录后重试"
            return
        }
        env.transferQueue.enqueueDownload(
            entries: entries,
            from: server,
            localDir: localDir,
            policy: .ask
        )
    }

    private func deleteEntries(_ entries: [RemoteEntry]) {
        guard let server = env.selectedServer else { return }
        // 逐个串行删除并收集失败原因：原先每项各起一个 Task 且吞掉错误，
        // 既拿不到失败信息，也会并发触发多次 reload。
        Task { @MainActor in
            var failures: [String] = []
            for e in entries {
                do {
                    try await env.remoteFiles.remove(server, path: e.path, recursive: e.isDir)
                    vm.selection.remove(e.path)
                } catch {
                    failures.append("\(e.name)：\(AppEnvironment.describe(error))")
                }
            }
            if !failures.isEmpty {
                deleteError = failures.joined(separator: "\n")
            }
            reload()
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
