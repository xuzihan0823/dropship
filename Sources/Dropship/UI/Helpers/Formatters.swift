import SwiftUI
import AppKit

// ============================================================
// 格式化工具：文件大小、速度、ETA、权限等统一在此处理。
// 全部用系统语义，不硬编码色值。
// ============================================================

enum Formatters {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        // 默认会把 0 渲染成 "Zero KB"，在传输队列里看着像坏了
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// 1024 进制文件大小，例如 `1.2 MB`。
    static func fileSize(_ bytes: Int64) -> String {
        if bytes < 0 { return "—" }
        return byteFormatter.string(fromByteCount: bytes)
    }

    /// 速度，例如 `1.2 MB/s`。
    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// 剩余时间，例如 `剩余 12 秒`。
    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        if seconds < 1 { return "即将完成" }
        if seconds < 60 { return "剩余 \(Int(seconds)) 秒" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "剩余 \(m) 分 \(s) 秒"
    }

    /// 相对时间，例如 `今天 14:23`、`昨天`、`3 天前`。
    static func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "今天 " + DateFormatter.localizedString(
                from: date, dateStyle: .none, timeStyle: .short)
        }
        if cal.isDateInYesterday(date) {
            return "昨天 " + DateFormatter.localizedString(
                from: date, dateStyle: .none, timeStyle: .short)
        }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(max(2, days)) 天前" }
        return DateFormatter.localizedString(
            from: date, dateStyle: .short, timeStyle: .short)
    }

    /// 八进制权限转人类可读，例如 `0644` -> `rw-r--r--`。
    static func permissionString(_ mode: String) -> String {
        let octal = mode.replacingOccurrences(of: "0", with: "")
        let trimmed: String
        if octal.count >= 3 {
            trimmed = String(octal.suffix(3))
        } else if mode.count >= 3 {
            trimmed = String(mode.suffix(3))
        } else {
            return mode
        }
        let map: [Character: String] = [
            "7": "rwx", "6": "rw-", "5": "r-x", "4": "r--",
            "3": "-wx", "2": "-w-", "1": "--x", "0": "---"
        ]
        var result = ""
        for c in trimmed {
            result += map[c] ?? "???"
        }
        return result
    }

    /// 八进制权限缩写，例如 `0644`。
    static func octalShort(_ mode: String) -> String {
        if mode.count >= 3 { return String(mode.suffix(3)) }
        return mode
    }

    /// 磁盘可用空间，例如 `120 GB 可用 / 500 GB`。
    static func diskUsage(free: Int64, total: Int64) -> String {
        "\(fileSize(free)) 可用 / \(fileSize(total))"
    }

    /// 百分比，例如 `82%`。
    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }
}
