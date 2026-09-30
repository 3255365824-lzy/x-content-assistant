import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            if await model.flushAll() { model.stopScheduler(); sender.reply(toApplicationShouldTerminate: true) }
            else {
                let alert = NSAlert(); alert.messageText = "编辑尚未保存"; alert.informativeText = "请恢复本地服务后再保存。现在退出会丢失未保存修改。"; alert.addButton(withTitle: "返回继续处理"); alert.addButton(withTitle: "仍然退出")
                let quit = alert.runModal() == .alertSecondButtonReturn
                if quit { model.stopScheduler() }; sender.reply(toApplicationShouldTerminate: quit)
            }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct XContentAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup("X 素材助手") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 720)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .onAppear { appDelegate.model = model; applyAppearance() }
                .onChange(of: appearance) { _, _ in applyAppearance() }
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("立即生成") { model.showGenerate = true }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                Button("导入医学素材") { model.chooseFiles(.medical) }.keyboardShortcut("i")
                Button("搜索") { model.searchPresented = true }.keyboardShortcut("f")
            }
        }
    }
    private func applyAppearance() {
        NSApp.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
    }
}
