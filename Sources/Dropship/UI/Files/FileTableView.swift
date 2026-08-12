import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OSLog

// ============================================================
// 文件表格：本地与远程共用。
// Table 多列 + 排序 + 多选 + 拖入目标高亮。
// ============================================================

struct FileRow: Identifiable, Hashable {
    let id: String
    let name: String
    let isDir: Bool
    let isSymlink: Bool
    let size: Int64
    let modTime: Date
    let mode: String
    let owner: String
    let group: String
    let path: String

    /// 用于排序：目录排在前面。
    var dirRank: Int { isDir ? 0 : 1 }

    init(_ entry: RemoteEntry) {
        self.id = entry.path
        self.name = entry.name
        self.isDir = entry.isDir
        self.isSymlink = entry.isSymlink
        self.size = entry.size
        self.modTime = entry.modTime
        self.mode = entry.mode
        self.owner = entry.owner
        self.group = entry.group
        self.path = entry.path
    }

    init(
        id: String, name: String, isDir: Bool, isSymlink: Bool,
        size: Int64, modTime: Date, mode: String,
        owner: String, group: String, path: String
    ) {
        self.id = id
        self.name = name
        self.isDir = isDir
        self.isSymlink = isSymlink
        self.size = size
        self.modTime = modTime
        self.mode = mode
        self.owner = owner
        self.group = group
        self.path = path
    }
}

struct FileTableView: View {
    private static let dragLogger = Logger(subsystem: "com.dropship.app", category: "drag-drop")
    let entries: [FileRow]
    @Binding var sortOrder: [KeyPathComparator<FileRow>]
    @Binding var selection: Set<String>

    let onOpen: (FileRow) -> Void
    let onContextMenu: ([FileRow]) -> AnyView
    /// 本地表提供 file URL，远程表提供仅应用内部识别的 URL 载荷。
    let dragProviderForRow: ((FileRow) -> NSItemProvider)?
    /// 投放到面板空白处＝落到当前目录。
    let onDrop: (([URL]) -> Void)?
    /// 投放到某个目录行上＝直接落到那个子目录。
    let onDropInto: (([URL], FileRow) -> Void)?

    @State private var isDropTargeted = false
    var body: some View {
        // Table 由 NSTableView 支撑，拖拽会话被 AppKit 接管，
        // 单元格视图上的 .onDrop 收不到事件；必须用 TableRow 级别的
        // dropDestination/itemProvider，高亮由表格原生绘制。
        let table = Table(of: FileRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { row in
                nameCell(row)
                    .contextMenu {
                        let selectedRows = currentSelection(for: row)
                        onContextMenu(selectedRows)
                    }
            }
            .width(min: 180, ideal: 260)

            TableColumn("大小", value: \.size) { row in
                if row.isDir {
                    Text("-").foregroundStyle(.secondary)
                } else {
                    Text(Formatters.fileSize(row.size))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn("修改时间", value: \.modTime) { row in
                Text(Formatters.relativeDate(row.modTime))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)

            TableColumn("权限", value: \.mode) { row in
                HStack(spacing: 6) {
                    Text(Formatters.octalShort(row.mode))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    Text(Formatters.permissionString(row.mode))
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 130, ideal: 160)
        } rows: {
            ForEach(entries) { row in
                tableRow(row)
            }
        }
        table
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: $isDropTargeted) { providers in
                guard let onDrop else { return false }

                // 完全异步，立即返回
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = FileTableView.receiveFileURLs(from: providers, handler: onDrop)
                }
                return true
            }
    }

    /// 目录行使用 TableRow 原生 dropDestination，让 NSTableView 负责准确
    /// 命中和高亮；本地表同时提供拖出载荷。
    @TableRowBuilder<FileRow>
    private func tableRow(_ row: FileRow) -> some TableRowContent<FileRow> {
        if let dragProviderForRow {
            if row.isDir, let onDropInto {
                TableRow(row)
                    .itemProvider { dragProviderForRow(row) }
                    .dropDestination(for: URL.self) { urls in
                        onDropInto(urls, row)
                    }
            } else {
                TableRow(row)
                    .itemProvider { dragProviderForRow(row) }
            }
        } else {
            if row.isDir, let onDropInto {
                TableRow(row)
                    .dropDestination(for: URL.self) { urls in
                        onDropInto(urls, row)
                    }
            } else {
                TableRow(row)
            }
        }
    }

    @ViewBuilder
    private func nameCell(_ row: FileRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FileIcon.symbol(for: row.name, isDir: row.isDir))
                .font(.body)
                .foregroundStyle(FileIcon.tint(for: row.name, isDir: row.isDir) ?? .secondary)
                .frame(width: 18)
            Text(row.name)
                .font(.body)
            if row.isSymlink {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if row.isDir {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
    }

    static func receiveFileURLs(
        from providers: [NSItemProvider],
        handler: (([URL]) -> Void)?
    ) -> Bool {
        guard let handler, !providers.isEmpty else {
            dragLogger.error("drop rejected: providers=\(providers.count, privacy: .public)")
            return false
        }
        dragLogger.info("drop received: providers=\(providers.count, privacy: .public)")
        var urls: [URL] = []
        var completedCount = 0
        let lock = NSLock()
        let timeoutSeconds = 5.0

        // 超时保护：5 秒后强制调用 handler（即使部分 provider 未完成）
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            lock.lock()
            if completedCount < providers.count {
                dragLogger.warning("receiveFileURLs timeout: completed=\(completedCount, privacy: .public)/\(providers.count, privacy: .public)")
                completedCount = providers.count  // 标记为已完成，避免重复调用 handler
                let finalURLs = urls
                lock.unlock()

                DispatchQueue.main.async {
                    handler(finalURLs)
                }
            } else {
                lock.unlock()
            }
        }

        for provider in providers {
            let typeIdentifier = [UTType.fileURL.identifier, UTType.url.identifier, UTType.item.identifier]
                .first { provider.hasItemConformingToTypeIdentifier($0) }
                ?? UTType.item.identifier
            dragLogger.info("provider type=\(typeIdentifier, privacy: .public)")
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let itemURL = item as? NSURL {
                    url = itemURL as URL
                } else if let data = item as? Data,
                          let value = URL(dataRepresentation: data, relativeTo: nil) {
                    url = value
                } else {
                    url = nil
                }

                lock.lock()
                completedCount += 1
                if let url { urls.append(url) }
                let shouldCallback = completedCount == providers.count
                let finalURLs = shouldCallback ? urls : []
                lock.unlock()

                let itemType = item.map { String(describing: type(of: $0)) } ?? "nil"
                dragLogger.info("provider resolved: item=\(itemType, privacy: .public), completed=\(completedCount, privacy: .public)")

                if shouldCallback {
                    DispatchQueue.main.async {
                        handler(finalURLs)
                    }
                }
            }
        }
        return true
    }

    /// 右键点击某行时，如果该行不在当前选择里，就以单选该行作为上下文。
    private func currentSelection(for row: FileRow) -> [FileRow] {
        if selection.contains(row.id) {
            return entries.filter { selection.contains($0.id) }
        }
        return [row]
    }
}

// MARK: - 状态显示

enum FilePanelStatus: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}

struct FilePanelStatusView: View {
    let status: FilePanelStatus

    var body: some View {
        switch status {
        case .idle:
            ContentUnavailableView("未连接",
                systemImage: "externaldrive.badge.questionmark",
                description: Text("请先在侧边栏选择并连接一台服务器"))
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.large)
                Text("正在读取目录…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView("空目录",
                systemImage: "folder",
                description: Text("此目录下没有文件"))
        case .failed(let msg):
            ContentUnavailableView("加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(msg))
        case .loaded:
            EmptyView()
        }
    }
}
