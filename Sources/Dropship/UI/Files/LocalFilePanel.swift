import SwiftUI
import AppKit

// ============================================================
// 本地文件面板：浏览 Mac 本地目录，作为拖拽源和下载目标。
// ============================================================

@MainActor
final class LocalFileViewModel: ObservableObject {
    @Published var url: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var entries: [FileRow] = []
    @Published var status: FilePanelStatus = .loading
    @Published var selection: Set<String> = []
    @Published var sortOrder: [KeyPathComparator<FileRow>] = [
        KeyPathComparator(\.dirRank),
        KeyPathComparator(\.name),
    ]
    @Published var history: [URL] = []
    @Published var future: [URL] = []

    private let openFile: (URL) -> Bool

    init(openFile: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openFile = openFile
    }

    private func fm() -> FileManager { FileManager.default }

    func navigate(to newURL: URL) {
        guard newURL != url else { return }
        history.append(url)
        future.removeAll()
        url = newURL
        reload()
    }

    func goBack() {
        guard let prev = history.popLast() else { return }
        future.append(url)
        url = prev
        reload()
    }

    var canGoBack: Bool { !history.isEmpty }

    @discardableResult
    func openEntry(_ row: FileRow) -> Bool {
        let target = URL(fileURLWithPath: row.path)
        var isDir: ObjCBool = false
        guard fm().fileExists(atPath: target.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            navigate(to: target)
            return true
        }
        return openFile(target)
    }

    func reload() {
        status = .loading
        let path = url.path
        let fm = self.fm()
        guard fm.fileExists(atPath: path) else {
            status = .failed("路径不存在")
            entries = []
            return
        }
        do {
            let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                .contentModificationDateKey
            ])
            var rows: [FileRow] = []
            for u in urls {
                let values = try u.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey
                ])
                let isDir = values.isDirectory ?? false
                let isSymlink = values.isSymbolicLink ?? false
                let size = Int64(values.fileSize ?? 0)
                let modTime = values.contentModificationDate ?? Date()
                // 通过 FileManager 取权限/属主
                let attrs = try? fm.attributesOfItem(atPath: u.path)
                let perm = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
                let mode = String(format: "0%o", perm)
                let owner = (attrs?[.ownerAccountName] as? String) ?? ""
                let group = (attrs?[.groupOwnerAccountName] as? String) ?? ""
                rows.append(FileRow(
                    id: u.path,
                    name: u.lastPathComponent,
                    isDir: isDir,
                    isSymlink: isSymlink,
                    size: size,
                    modTime: modTime,
                    mode: mode,
                    owner: owner,
                    group: group,
                    path: u.path
                ))
            }
            entries = rows
            status = rows.isEmpty ? .empty : .loaded
        } catch {
            status = .failed(error.localizedDescription)
            entries = []
        }
    }
}

/// 「上传到远程」的目标目录解析。抽成纯函数，是为了把"绝不回退到硬编码路径"
/// 这条规则钉在测试里——早期版本写死 `/root`，非 root 账号会把文件传到
/// 没有权限、也不是用户想要的位置。
enum UploadDestination {
    static func resolve(remotePath: String) -> String? {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return trimmed
    }
}

struct LocalFilePanel: View {
    @StateObject private var vm = LocalFileViewModel()
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var queue: TransferQueue
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var confirmDelete: [FileRow]?
    /// 删除/移动/新建失败时的提示。以前这些错误是直接丢掉的，用户只会觉得"点了没反应"。
    @State private var actionError: String?

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
        .onAppear {
            vm.reload()
            // 同步给远程面板，「下载到本地」要靠它决定目标目录
            env.currentLocalDirectory = vm.url
        }
        .onChange(of: vm.url) { _, newURL in
            env.currentLocalDirectory = newURL
        }
        // 下载结束后自动刷新，否则刚取回的文件不会出现在列表里
        .onChange(of: finishedTransferSignature) { _, _ in
            vm.reload()
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") { createFolder() }
        } message: {
            Text("请输入新文件夹名称")
        }
        .alert("操作失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "未知错误")
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
    }

    @ViewBuilder
    private var content: some View {
        switch vm.status {
        case .loading where vm.entries.isEmpty:
            FilePanelStatusView(status: .loading)
        case .empty:
            // 空目录下没有表格兜底，占位视图自己要能接收投放
            FilePanelStatusView(status: .empty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .fileDropCatcher { urls in handleDrop(urls, into: vm.url) }
        case .failed(let msg):
            FilePanelStatusView(status: .failed(msg))
        default:
            ZStack {
                FileTableView(
                    entries: vm.entries,
                    sortOrder: $vm.sortOrder,
                    selection: $vm.selection,
                    onOpen: { row in openEntry(row) },
                    onContextMenu: { selectedRows in
                        AnyView(contextMenu(for: selectedRows))
                    },
                    dragProviderForRow: { row in
                        NSItemProvider(object: URL(fileURLWithPath: row.path) as NSURL)
                    },
                    onDrop: { urls in handleDrop(urls, into: vm.url) },
                    onDropInto: { urls, row in
                        handleDrop(urls, into: URL(fileURLWithPath: row.path))
                    }
                )
                if case .loading = vm.status {
                    ProgressView().controlSize(.regular)
                }
            }
        }
    }

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
                vm.reload()
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
                confirmDelete = vm.entries.filter { vm.selection.contains($0.id) }
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(vm.selection.isEmpty)
        }
    }

    @ViewBuilder
    private var breadcrumbsBar: some View {
        let segments = localPathSegments(vm.url)
        HStack(spacing: 8) {
            Image(systemName: "macbook")
                .foregroundStyle(.secondary)
                .font(.callout)
            Breadcrumbs(segments: segments) { seg in
                vm.navigate(to: URL(fileURLWithPath: seg.path))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func contextMenu(for rows: [FileRow]) -> some View {
        if !rows.isEmpty {
            if rows.count == 1, let row = rows.first {
                Button {
                    openEntry(row)
                } label: {
                    Label(
                        row.isDir ? "打开文件夹" : "打开文件",
                        systemImage: row.isDir ? "folder" : "doc"
                    )
                }
                Divider()
            }
            Button {
                uploadToRemote(rows)
            } label: {
                Label(uploadMenuTitle, systemImage: "arrow.up.circle")
            }
            .disabled(env.selectedServer == nil
                      || UploadDestination.resolve(remotePath: env.currentRemotePath) == nil)
            Divider()
            Button(role: .destructive) {
                confirmDelete = rows
            } label: {
                Label("删除", systemImage: "trash")
            }
            Divider()
            Button {
                if let path = rows.first?.path {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }
            .disabled(rows.count != 1)
        }
    }

    // MARK: - 操作

    /// destDir 为 nil 时落到当前目录；拖到某个目录行上时传入该行路径。
    /// 已结束传输的指纹。任一任务进入完成/跳过状态，指纹变化，触发列表刷新。
    private var finishedTransferSignature: Int {
        queue.finishedTransferRevision
    }

    /// 菜单里直接写出目标目录，避免用户不清楚文件会落到远端哪里。
    private var uploadMenuTitle: String {
        let dir = env.currentRemotePath
        return dir.isEmpty ? "上传到远程" : "上传到 \(dir)"
    }

    private func openEntry(_ row: FileRow) {
        guard vm.openEntry(row) else {
            actionError = "无法打开「\(row.name)」，文件可能已被移动或没有可用的默认应用"
            return
        }
        vm.selection = [row.id]
    }

    private func handleDrop(_ urls: [URL], into targetDirectory: URL) {
        let payloads = LocalFileDropPayloads.classify(urls)
        if !payloads.localURLs.isEmpty {
            handleMoveInto(payloads.localURLs, into: targetDirectory)
        }
        if !payloads.remotePayloads.isEmpty {
            handleDownload(payloads.remotePayloads, into: targetDirectory)
        }
    }

    private func handleMoveInto(_ urls: [URL], into destDir: URL? = nil) {
        // Finder 拖入本地面板：把文件移入目标目录
        let dest = destDir ?? vm.url
        let fm = FileManager.default
        var failures: [String] = []
        for u in urls {
            let target = dest.appendingPathComponent(u.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                failures.append("\(u.lastPathComponent)：目标目录中已存在同名项")
                continue
            }
            do {
                try fm.moveItem(at: u, to: target)
            } catch {
                failures.append("\(u.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        reportIfNeeded(failures)
        vm.reload()
    }

    private func handleDownload(
        _ payloads: [RemoteFileDragPayload],
        into targetDirectory: URL
    ) {
        guard let server = env.selectedServer else {
            actionError = "请先在左侧选择一台服务器"
            return
        }

        Task { @MainActor in
            do {
                let plans = try payloads.map {
                    try RemoteDownloadPlan.make(
                        payload: $0,
                        targetDirectory: targetDirectory,
                        selectedServerID: server.id
                    )
                }
                var entries: [RemoteEntry] = []
                for plan in plans {
                    entries.append(try await env.remoteFiles.stat(server, path: plan.sourcePath))
                }
                guard let localDirectory = plans.first?.localDirectory else { return }
                env.transferQueue.enqueueDownload(
                    entries: entries,
                    from: server,
                    localDir: localDirectory,
                    policy: .ask
                )
            } catch {
                actionError = AppEnvironment.describe(error)
            }
        }
    }

    private func uploadToRemote(_ rows: [FileRow]) {
        guard let server = env.selectedServer else {
            actionError = "请先在左侧选择一台服务器"
            return
        }
        // 目标目录取远程面板当前所在目录。以前这里写死 /root，
        // 非 root 账号会传到没有权限、也不是用户想要的位置。
        guard let remoteDir = UploadDestination.resolve(remotePath: env.currentRemotePath) else {
            actionError = "请先连接服务器，并在右侧打开要上传到的远程目录"
            return
        }
        let urls = rows.map { URL(fileURLWithPath: $0.path) }
        env.transferQueue.enqueueUpload(
            localURLs: urls,
            to: server,
            remoteDir: remoteDir,
            policy: .ask
        )
    }

    private func deleteEntries(_ rows: [FileRow]) {
        let fm = FileManager.default
        var failures: [String] = []
        for row in rows {
            do {
                try fm.removeItem(atPath: row.path)
                vm.selection.remove(row.id)
            } catch {
                failures.append("\(row.name)：\(error.localizedDescription)")
            }
        }
        reportIfNeeded(failures)
        vm.reload()
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionError = "文件夹名称不能为空"
            return
        }
        guard name != ".", name != "..", !name.contains("/") else {
            actionError = "请输入当前目录下的单个文件夹名称"
            return
        }
        let target = vm.url.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: false
            )
            newFolderName = ""
        } catch {
            actionError = error.localizedDescription
        }
        vm.reload()
    }

    /// 逐项收集失败原因后一次性提示，避免多选操作弹出一连串弹窗。
    private func reportIfNeeded(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        actionError = failures.joined(separator: "\n")
    }
}

/// 把本地 URL 拆成面包屑段。
func localPathSegments(_ url: URL) -> [PathSegment] {
    var segments: [PathSegment] = []
    let path = url.path
    // 起点：家目录显示为 ~
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home {
        return [PathSegment(path: home, name: "~")]
    }
    if path.hasPrefix(home + "/") {
        segments.append(PathSegment(path: home, name: "~"))
        let rest = String(path.dropFirst(home.count + 1))
        var current = home
        for comp in rest.split(separator: "/") {
            current += "/" + comp
            segments.append(PathSegment(path: current, name: String(comp)))
        }
        return segments
    }
    // 非家目录：从根开始
    return pathSegments(path)
}
