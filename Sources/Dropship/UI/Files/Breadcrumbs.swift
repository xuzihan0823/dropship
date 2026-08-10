import SwiftUI

// ============================================================
// 面包屑：路径导航。可点击任意一级跳转。
// ============================================================

struct Breadcrumbs<PathComponent: Hashable>: View {
    let components: [PathComponent]
    let label: (PathComponent) -> String
    let onSelect: (PathComponent) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(components.enumerated()), id: \.offset) { idx, c in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        onSelect(c)
                    } label: {
                        Text(label(c))
                            .font(.callout)
                            .foregroundStyle(idx == components.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(label(c))
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 便捷构造

extension Breadcrumbs where PathComponent == PathSegment {
    init(segments: [PathSegment], onSelect: @escaping (PathSegment) -> Void) {
        self.init(
            components: segments,
            label: { $0.name },
            onSelect: onSelect
        )
    }
}

/// 一段路径：绝对路径 + 显示名。
struct PathSegment: Hashable {
    let path: String
    let name: String
}

/// 把一个绝对路径拆分成面包屑段。
/// 例如 `/root/logs/nginx` -> ["/", "root", "logs", "nginx"]
func pathSegments(_ absolutePath: String) -> [PathSegment] {
    let comps = absolutePath.split(separator: "/").map { String($0) }
    var segments: [PathSegment] = [PathSegment(path: "/", name: "/")]
    var current = ""
    for c in comps {
        current += "/" + c
        segments.append(PathSegment(path: current, name: c))
    }
    return segments
}
