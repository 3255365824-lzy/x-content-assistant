import SwiftUI

struct ExtensionConnectionSheet: View {
    @ObservedObject var center: InteractionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("一次连接，以后在 App 获取新帖").font(.title2.bold())
            Text("本地 Edge 扩展只读 X 页面，数据只回到本机。不需要 X API、云端账号或 Codex；不会发送、点赞、关注或读取登录信息。")
            Text("1. 打开扩展管理，开启开发人员模式，选择「加载解压缩的扩展」，选中 EdgeExtension 文件夹。")
            HStack { Button("打开 Edge 扩展管理") { center.openExtensionManager() }; Button("显示扩展文件夹") { center.revealExtension() } }
            Text("2. 点下面的复制按钮，再打开 Edge 工具栏的「X 素材助手 · 只读选帖」，粘贴并连接。连接码只在本机使用，5 分钟后失效。")
            Button("复制连接码") { center.copyExtensionCode() }.disabled(center.extensionConnected)
            Text(center.discoveryMessage).font(.callout).foregroundStyle(center.extensionConnected ? .green : .secondary)
            Text("3. 回到 App 点「获取新帖」。默认读取「正在关注」，不限医学或 AI，生活、职场、科技和趣味也可入选。最近 48 小时、粉丝达到 1 万优先，每位作者最多 2 条；本轮可见内容不足时不凑数。")
            Text("首次加载扩展与站点访问权限由你确认。遇到登录、验证码、平台限制会停下；关闭 App 就停止接收新任务。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 590)
    }
}
