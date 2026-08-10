import SwiftUI

/// 应用根视图 —— 占位实现。
///
/// 由 UI 负责人替换为真正的三栏布局（服务器侧边栏 / 本地面板 / 远程面板 + 传输队列）。
/// 保留此文件是为了让 Core 层在 UI 尚未完成时也能通过编译。
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Dropship")
                .font(.title2)
            Text("界面构建中")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
