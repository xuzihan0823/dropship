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

    func openEntry(_ row: FileRow) {
        let target = URL(fileURLWithPath: row.path)
        var isDir: ObjCBool = false
        if fm().fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            navigate(to: target)
        }
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

struct LocalFilePanel: View {
    @StateObject private var vm = LocalFileViewModel()
    @EnvironmentObject private var env: AppEnvironment
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var confirmDelete: [FileRow]?

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
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") { createFolder() }
        } message: {
            Text("请输入新文件夹名称")
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
            FilePanelStatusView(status: .empty)
        case .failed(let msg):
            FilePanelStatusView(status: .failed(msg))
        default:
            ZStack {
                FileTableView(
                    entries: vm.entries,
                    sortOrder: $vm.sortOrder,
                    selection: $vm.selection,
                    onOpen: { row in vm.openEntry(row) },
                    onContextMenu: { selectedRows in
                        AnyView(contextMenu(for: selectedRows))
                    },
                    onDrop: { urls in handleMoveInto(urls) }
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
        Button {
            uploadToRemote(rows)
        } label: {
            Label("上传到远程", systemImage: "arrow.up.circle")
        }
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
        Button {
            if let row = rows.first {
                vm.openEntry(row)
            }
        } label: {
            Label("打开", systemImage: "arrow.right.circle")
        }
        .disabled(rows.count != 1 || !rows.first!.isDir)
    }

    // MARK: - 操作

    private func handleMoveInto(_ urls: [URL]) {
        // Finder 拖入本地面板：把文件移入当前目录
        let dest = vm.url
        let fm = FileManager.default
        for u in urls {
            let target = dest.appendingPathComponent(u.lastPathComponent)
            if fm.fileExists(atPath: target.path) { continue }
            do {
                try fm.moveItem(at: u, to: target)
            } catch {
                // 失败忽略
            }
        }
        vm.reload()
    }

    private func uploadToRemote(_ rows: [FileRow]) {
        guard let server = env.selectedServer else { return }
        let urls = rows.map { URL(fileURLWithPath: $0.path) }
        // remoteDir 需要从远程面板拿到，这里用一个简化路径
        env.transferQueue.enqueueUpload(
            localURLs: urls,
            to: server,
            remoteDir: "/root",
            policy: .ask
        )
    }

    private func deleteEntries(_ rows: [FileRow]) {
        let fm = FileManager.default
        for row in rows {
            try? fm.removeItem(atPath: row.path)
            vm.selection.remove(row.id)
        }
        vm.reload()
    }

    private func createFolder() {
        let target = vm.url.appendingPathComponent(newFolderName)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        newFolderName = ""
        vm.reload()
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
