import SwiftUI
import UniformTypeIdentifiers

// ============================================================
// 文件图标：根据文件名后缀返回对应 SF Symbol。
// 远程文件没有本地 URL，无法用 NSWorkspace，故按扩展名映射。
// ============================================================

enum FileIcon {
    /// 根据文件名返回 SF Symbol 名称。
    static func symbol(for filename: String, isDir: Bool) -> String {
        if isDir { return "folder.fill" }
        let ext = (filename as NSString).pathExtension.lowercased()
        return symbol(forExtension: ext)
    }

    /// 远程目录里符号链接的角标。
    static let symlinkBadge = "arrow.triangle.branch"

    private static func symbol(forExtension ext: String) -> String {
        switch ext {
        // 归档
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "iso":
            return "doc.zipper"
        // 代码
        case "swift", "m", "mm", "c", "cpp", "h", "hpp":
            return "swift"
        case "go":
            return "building.columns"
        case "py":
            return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "jsx", "tsx":
            return "curlybraces"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "curlybraces"
        case "sh", "bash", "zsh":
            return "terminal"
        // 文档
        case "md", "markdown", "txt", "rst":
            return "doc.text"
        case "pdf":
            return "doc.richtext"
        case "doc", "docx":
            return "doc.fill"
        case "xls", "xlsx", "csv":
            return "tablecells"
        case "ppt", "pptx":
            return "rectangle.on.rectangle"
        // 图片
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "svg", "heic":
            return "photo"
        // 视频
        case "mp4", "mov", "avi", "mkv", "flv", "wmv":
            return "film"
        // 音频
        case "mp3", "wav", "flac", "aac", "m4a":
            return "waveform"
        // 可执行
        case "", "bin", "exe":
            return "terminal"
        default:
            return "doc"
        }
    }

    /// 用于表头排序箭头等。
    static func sortIndicator(ascending: Bool, active: Bool) -> String {
        guard active else { return "" }
        return ascending ? "chevron.up" : "chevron.down"
    }
}

// MARK: - 颜色

extension FileIcon {
    /// 为不同文件类型提供强调色，全部走系统色避免深色模式崩坏。
    static func tint(for filename: String, isDir: Bool) -> Color? {
        if isDir { return .accentColor }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return .orange
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "svg", "heic":
            return .purple
        case "mp4", "mov", "avi", "mkv", "flv", "wmv":
            return .pink
        case "mp3", "wav", "flac", "aac", "m4a":
            return .teal
        case "md", "markdown", "txt":
            return nil
        default:
            return nil
        }
    }
}
