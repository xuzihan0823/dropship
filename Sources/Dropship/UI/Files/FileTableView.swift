import SwiftUI
import AppKit

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
    let entries: [FileRow]
    @Binding var sortOrder: [KeyPathComparator<FileRow>]
    @Binding var selection: Set<String>

    let onOpen: (FileRow) -> Void
    let onContextMenu: ([FileRow]) -> AnyView
    /// 投放到面板空白处＝落到当前目录。
    let onDrop: (([URL]) -> Void)?
    /// 投放到某个目录行上＝直接落到那个子目录。
    let onDropInto: (([URL], FileRow) -> Void)?

    @State private var isDropTargeted = false
    /// 当前被拖拽悬停的目录行，用于高亮。
    @State private var dropTargetRowID: String?

    var body: some View {
        Table(entries, selection: $selection, sortOrder: $sortOrder) {
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
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .opacity(isDropTargeted ? 0.65 : 1.0)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let onDrop {
                onDrop(urls)
                return true
            }
            return false
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.12)) {
                isDropTargeted = targeted
            }
        }
    }

    @ViewBuilder
    private func nameCell(_ row: FileRow) -> some View {
        let cell = HStack(spacing: 8) {
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onOpen(row)
        }

        // 目录行本身就是投放目标：拖到某个文件夹上，直接传进那个文件夹，
        // 不必先双击进去。非目录行不拦截，让事件落到整张表格＝传到当前目录。
        if row.isDir, let onDropInto {
            cell
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(dropTargetRowID == row.id ? 0.30 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            Color.accentColor,
                            lineWidth: dropTargetRowID == row.id ? 1.5 : 0
                        )
                )
                .dropDestination(for: URL.self) { urls, _ in
                    dropTargetRowID = nil
                    guard !urls.isEmpty else { return false }
                    onDropInto(urls, row)
                    return true
                } isTargeted: { targeted in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        if targeted {
                            dropTargetRowID = row.id
                        } else if dropTargetRowID == row.id {
                            dropTargetRowID = nil
                        }
                    }
                }
        } else {
            cell
        }
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
