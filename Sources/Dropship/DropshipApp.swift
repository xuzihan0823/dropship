import SwiftUI

@main
struct DropshipApp: App {
    init() {
        // 上传时向 ssh 子进程的管道写数据；若 ssh 中途退出，
        // 写入已关闭的管道会触发 SIGPIPE，默认直接终止进程且无崩溃报告。
        // 忽略后写入会抛 EPIPE 错误，由传输层捕获并标记任务失败。
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
        }
    }
}
