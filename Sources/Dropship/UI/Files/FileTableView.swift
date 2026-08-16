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
    /// 最后一行底边（自顶向下，相对表格左上角）。-1 表示探针没量到。
    @State private var rowsBottom: CGFloat = -1

    /// 探针失效时的保守估算，宁可把空白投放区留小一点，也不要盖住目录行。
    private static let estimatedRowHeight: CGFloat = 28
    private static let estimatedHeaderHeight: CGFloat = 28

    var body: some View {
        // Table 由 NSTableView 支撑，拖拽会话被 AppKit 接管，
        // 单元格视图上的 .onDrop 收不到事件；必须用 TableRow 级别的
        // dropDestination/itemProvider，高亮由表格原生绘制。
        let table = Table(of: FileRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { row in
                nameCell(row)
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
            // 使用 Table 原生选择上下文：右键会传入实际命中的行，primaryAction
            // 在 macOS 上对应双击。避免给单元格叠加手势而干扰 TableRow 拖放。
            .contextMenu(forSelectionType: String.self) { selectedIDs in
                onContextMenu(Self.rows(in: entries, matching: selectedIDs))
            } primaryAction: { selectedIDs in
                let selectedRows = Self.rows(in: entries, matching: selectedIDs)
                guard selectedRows.count == 1, let row = selectedRows.first else { return }
                onOpen(row)
            }
            .background(
                TableContentBottomReader(rowCount: entries.count) { bottom in
                    rowsBottom = bottom
                }
            )
            // 最后一行下方的空白区：NSTableView 会把这里的拖拽判为无效目标，
            // 且不会向上转交给 SwiftUI，所以必须自己铺一层投放区。只覆盖行区
            // 以下，避免抢走 TableRow 自己的 dropDestination。
            .overlay {
                GeometryReader { geo in
                    let top = blankAreaTop(viewHeight: geo.size.height)
                    if geo.size.height - top > 2 {
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: top)
                                .allowsHitTesting(false)
                            Color.clear
                                .fileDropCatcher { urls in onDrop?(urls) }
                        }
                    }
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
            // 列头等非 NSTableView 区域仍由这里兜底。
            .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: $isDropTargeted) { providers in
                guard let onDrop else { return false }

                // 完全异步，立即返回
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = FileTableView.receiveFileURLs(from: providers, handler: onDrop)
                }
                return true
            }
    }

    /// 空白投放区的上边界。
    private func blankAreaTop(viewHeight: CGFloat) -> CGFloat {
        let measured = rowsBottom >= 0
            ? rowsBottom
            : Self.estimatedHeaderHeight + Self.estimatedRowHeight * CGFloat(entries.count)
        return min(max(0, measured), viewHeight)
    }

    /// 每一行都注册原生 dropDestination，让 NSTableView 负责排序、滚动后的
    /// 准确行命中与高亮。目录行落进该目录，文件行落到当前目录——否则文件行
    /// 会被 NSTableView 判为无效目标，形成一块块投不进去的死区。
    @TableRowBuilder<FileRow>
    private func tableRow(_ row: FileRow) -> some TableRowContent<FileRow> {
        if let dragProviderForRow {
            TableRow(row)
                .itemProvider { dragProviderForRow(row) }
                .dropDestination(for: URL.self) { urls in handleRowDrop(urls, onto: row) }
        } else {
            TableRow(row)
                .dropDestination(for: URL.self) { urls in handleRowDrop(urls, onto: row) }
        }
    }

    private func handleRowDrop(_ urls: [URL], onto row: FileRow) {
        if row.isDir, let onDropInto {
            onDropInto(urls, row)
        } else {
            onDrop?(urls)
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

    /// 保持表格当前排序，把系统提供的选中 ID 映射回菜单/双击需要的行。
    static func rows(in entries: [FileRow], matching selectedIDs: Set<String>) -> [FileRow] {
        entries.filter { selectedIDs.contains($0.id) }
    }
}

// MARK: - 通用投放区

/// 给任意视图挂一个"接收本机文件 / 应用内条目"的投放区，带高亮反馈。
/// 用于表格空白区和空目录占位视图这些 NSTableView 不接管的地方。
struct FileDropCatcher: ViewModifier {
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: $isTargeted) { providers in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = FileTableView.receiveFileURLs(from: providers, handler: onDrop)
                }
                return true
            }
    }
}

extension View {
    func fileDropCatcher(_ onDrop: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropCatcher(onDrop: onDrop))
    }
}

// MARK: - 表格内容高度探针

/// SwiftUI 不暴露 `Table` 的内容高度，但空白投放区必须精确落在最后一行下方，
/// 否则会盖住目录行、抢掉 TableRow 自己的 dropDestination。这里直接找到表格
/// 背后的 NSTableView，量出最后一行底边。
private struct TableContentBottomReader: NSViewRepresentable {
    /// 行数变化时触发 updateNSView 重新测量。
    let rowCount: Int
    let onMeasure: (CGFloat) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onMeasure = onMeasure
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onMeasure = onMeasure
        nsView.scheduleMeasure()
    }

    final class ProbeView: NSView {
        var onMeasure: ((CGFloat) -> Void)?
        /// -2 表示还没上报过，避免首次测量被去重吞掉。
        private var lastReported: CGFloat = -2

        /// 与 SwiftUI 一致的自顶向下坐标，convert(_:from:) 会自动处理翻转。
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleMeasure()
        }

        override func layout() {
            super.layout()
            scheduleMeasure()
        }

        /// 必须延后一拍：SwiftUI 更新到这里时，NSTableView 往往还没完成布局。
        func scheduleMeasure() {
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        private func measure() {
            guard window != nil else { return }
            let value = contentBottom() ?? -1
            guard value != lastReported else { return }
            lastReported = value
            onMeasure?(value)
        }

        private func contentBottom() -> CGFloat? {
            guard let table = matchingTableView() else { return nil }
            let rows = table.numberOfRows
            guard rows > 0 else { return 0 }
            return convert(table.rect(ofRow: rows - 1), from: table).maxY
        }

        /// 同一窗口里有本地和远程两张表。探针铺在表格背景上，取与自己重叠面积
        /// 最大的那张滚动视图，就能锁定属于自己的 NSTableView。
        private func matchingTableView() -> NSTableView? {
            guard let root = window?.contentView else { return nil }
            let selfRect = convert(bounds, to: nil)
            guard !selfRect.isEmpty else { return nil }

            var best: (table: NSTableView, area: CGFloat)?
            for table in Self.tableViews(in: root) {
                guard let scroll = table.enclosingScrollView else { continue }
                let overlap = scroll.convert(scroll.bounds, to: nil).intersection(selfRect)
                guard !overlap.isNull, !overlap.isEmpty else { continue }
                let area = overlap.width * overlap.height
                if area > (best?.area ?? 0) { best = (table, area) }
            }
            return best?.table
        }

        private static func tableViews(in view: NSView) -> [NSTableView] {
            var found: [NSTableView] = []
            if let table = view as? NSTableView { found.append(table) }
            for sub in view.subviews {
                found.append(contentsOf: tableViews(in: sub))
            }
            return found
        }
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
