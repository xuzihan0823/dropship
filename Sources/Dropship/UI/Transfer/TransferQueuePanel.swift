import SwiftUI
import AppKit

// ============================================================
// 传输队列面板：底部可折叠。
// 两个分页：「传输队列」是本机发起的上传/下载，
// 「收件箱」是服务器通过反向隧道主动推回来的文件。
// ============================================================

struct TransferQueuePanel: View {
    private enum Tab: Hashable {
        case transfers
        case inbox
    }

    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var queue: TransferQueue
    @ObservedObject private var tunnels: TunnelService
    @State private var tab: Tab = .transfers

    init(queue: TransferQueue, tunnels: TunnelService) {
        self.queue = queue
        self.tunnels = tunnels
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if env.transferPanelExpanded {
                Divider()
                switch tab {
                case .transfers: taskList
                case .inbox: inboxList
                }
            }
        }
        .background(.regularMaterial)
        .frame(maxHeight: env.transferPanelExpanded ? .infinity : nil)
    }

    // MARK: - 顶部工具栏

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    env.transferPanelExpanded.toggle()
                }
            } label: {
                Image(systemName: env.transferPanelExpanded
                      ? "chevron.down"
                      : "chevron.up")
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .help(env.transferPanelExpanded ? "折叠传输队列" : "展开传输队列")

            Picker("", selection: $tab) {
                Text("传输队列").tag(Tab.transfers)
                Text(tunnels.inbox.isEmpty ? "收件箱" : "收件箱 \(tunnels.inbox.count)")
                    .tag(Tab.inbox)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            if tab == .transfers, queue.taskCount > 0 {
                Text("\(queue.activeCount) 个进行中 · \(queue.taskCount) 个任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if tab == .transfers {
                if queue.activeCount > 0 || queue.completedCount > 0 {
                    overallProgress
                }

                Button {
                    queue.clearFinished()
                } label: {
                    Label("清除已完成", systemImage: "checkmark.broom")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(queue.finishedCount == 0)
            } else {
                Button {
                    _ = NSWorkspace.shared.open(tunnels.inboxDirectory)
                } label: {
                    Label("打开收件箱", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    tunnels.clearInbox()
                } label: {
                    Label("清空列表", systemImage: "eraser")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(tunnels.inbox.isEmpty)
                .help("只清列表，磁盘上的文件不动")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var overallProgress: some View {
        let total = queue.totalBytes
        let done = queue.transferredBytes
        let ratio = total > 0 ? Double(done) / Double(total) : 0
        HStack(spacing: 6) {
            Text("总体")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: ratio)
                .frame(width: 80)
            Text(Formatters.percent(ratio))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 任务列表

    @ViewBuilder
    private var taskList: some View {
        if queue.taskCount == 0 {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("没有传输任务")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.visibleTasks) { task in
                        TransferRow(task: task)
                            .contextMenu {
                                taskContextMenu(for: task)
                            }
                        if task.id != queue.visibleTasks.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func taskContextMenu(for task: TransferTask) -> some View {
        switch task.state {
        case .transferring, .preparing, .verifying:
            Button {
                queue.pause(task.id)
            } label: {
                Label("暂停", systemImage: "pause")
            }
            Button(role: .destructive) {
                queue.cancel(task.id)
            } label: {
                Label("取消", systemImage: "xmark")
            }
        case .paused:
            Button {
                queue.resume(task.id)
            } label: {
                Label("恢复", systemImage: "play")
            }
            Button(role: .destructive) {
                queue.cancel(task.id)
            } label: {
                Label("取消", systemImage: "xmark")
            }
        case .failed:
            Button {
                queue.retry(task.id)
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                queue.removeTask(task.id)
            } label: {
                Label("移除", systemImage: "trash")
            }
        case .queued:
            Button(role: .destructive) {
                queue.cancel(task.id)
            } label: {
                Label("取消", systemImage: "xmark")
            }
        case .completed, .skipped, .cancelled:
            Button(role: .destructive) {
                queue.removeTask(task.id)
            } label: {
                Label("移除", systemImage: "trash")
            }
        }
    }

    // MARK: - 收件箱

    @ViewBuilder
    private var inboxList: some View {
        if tunnels.inbox.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("还没有收到推送")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("开启收件隧道后，在服务器上执行 \(TunnelService.sendCommand)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tunnels.inbox) { item in
                        InboxRow(item: item)
                            .onTapGesture(count: 2) {
                                _ = NSWorkspace.shared.open(item.url)
                            }
                            .contextMenu {
                                inboxContextMenu(for: item)
                            }
                        if item.id != tunnels.inbox.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func inboxContextMenu(for item: InboxItem) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }
        Button {
            _ = NSWorkspace.shared.open(item.url)
        } label: {
            Label("打开", systemImage: "arrow.up.forward.app")
        }
        Divider()
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        } label: {
            Label("拷贝路径", systemImage: "doc.on.doc")
        }
    }

}

// MARK: - 单行收件

private struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Formatters.fileSize(item.bytes)) · \(Formatters.relativeDate(item.receivedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - 单行任务

private struct TransferRow: View {
    let task: TransferTask

    var body: some View {
        HStack(spacing: 12) {
            directionIcon
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.filename)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statusLabel
                }
                HStack(spacing: 8) {
                    if showsProgress {
                        ProgressView(value: task.progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: .infinity)
                        Text(Formatters.percent(task.progress))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    if let speed = speedText {
                        Text(speed)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let eta = etaText {
                        Text(eta)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(Formatters.fileSize(task.transferredBytes)
                         + " / "
                         + Formatters.fileSize(task.totalBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var directionIcon: some View {
        ZStack {
            Circle()
                .fill(.quaternary)
                .frame(width: 28, height: 28)
            Image(systemName: task.direction == .upload
                  ? "arrow.up"
                  : "arrow.down")
                .font(.callout)
                .foregroundStyle(task.direction == .upload
                                ? Color.orange
                                : Color.blue)
        }
        .frame(width: 28)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch task.state {
        case .queued:
            statusBadge("排队中", color: .secondary, icon: "hourglass")
        case .preparing:
            statusBadge("准备中", color: .orange, icon: "gear")
        case .transferring:
            statusBadge("传输中", color: .accentColor, icon: "arrow.triangle.2.circlepath")
        case .verifying:
            statusBadge("校验中", color: .purple, icon: "checkmark.shield")
        case .completed:
            statusBadge("已完成", color: .green, icon: "checkmark.circle.fill")
        case .skipped:
            statusBadge("已跳过（内容一致）", color: .teal, icon: "checkmark.seal.fill")
        case .paused:
            statusBadge("已暂停", color: .secondary, icon: "pause.circle")
        case .failed(let err):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text(err.message)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.red)
        case .cancelled:
            statusBadge("已取消", color: .secondary, icon: "xmark.circle")
        }
    }

    @ViewBuilder
    private func statusBadge(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(color)
    }

    private var showsProgress: Bool {
        switch task.state {
        case .transferring, .paused, .verifying, .preparing, .failed:
            return task.totalBytes > 0
        case .completed, .skipped:
            return task.totalBytes > 0
        case .queued:
            return task.totalBytes > 0
        case .cancelled:
            return false
        }
    }

    private var speedText: String? {
        switch task.state {
        case .transferring:
            return Formatters.speed(task.speed)
        default:
            return nil
        }
    }

    private var etaText: String? {
        switch task.state {
        case .transferring:
            return Formatters.eta(task.eta)
        default:
            return nil
        }
    }
}
