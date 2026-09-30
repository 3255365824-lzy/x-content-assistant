import SwiftUI
import XContentAssistantCore
import AppKit

struct CalendarView: View {
    @EnvironmentObject var model: AppModel
    @State var newTime = "20:30"
    @State var selectedDay = Date()
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    var planned: [DraftManifest] { model.queue.filter { $0.plannedAt != nil }.sorted { $0.plannedAt! < $1.plannedAt! } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("让内容有节奏，不必着急发。").font(.system(size: 27, weight: .bold))
                Text("生成时间和发帖提醒相互独立。以下时间均为 Asia/Shanghai。").foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 20) {
                    Panel(title: "自动生成草稿") {
                        Toggle("App 打开时启用", isOn: $model.schedule.enabled)
                        ForEach(model.schedule.times, id: \.self) { time in HStack { Label(time, systemImage: "sparkles").monospacedDigit(); Spacer(); Button { model.schedule.times.removeAll { $0 == time }; model.savePreferences() } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless) } }
                        HStack { TextField("HH:mm", text: $newTime).textFieldStyle(.roundedBorder).frame(width: 80); Button("添加") { if ScheduleRules.normalizedTimes([newTime]).isEmpty { model.errorMessage = "请输入 00:00–23:59 的时间" } else { model.schedule.times.append(newTime); model.savePreferences() } } }
                        Picker("风格", selection: $model.schedule.style) { Text("观点 / 反常识").tag("bold_opinion"); Text("轻科普").tag("knowledge") }
                        Text("每次最多一条 · 关闭后停止 · 错过不补跑").font(.caption).foregroundStyle(.secondary)
                    }
                    Panel(title: "计划发帖 · 仅提醒") {
                        DatePicker("查看日期", selection: $selectedDay, displayedComponents: .date).datePickerStyle(.graphical).environment(\.timeZone, calendar.timeZone)
                        let dayDrafts = planned.filter { calendar.isDate($0.plannedAt!, inSameDayAs: selectedDay) }
                        if dayDrafts.isEmpty { Text("这天还没有安排，去草稿中设置计划时间。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(dayDrafts) { draft in Button { model.showDraft(draft.id) } label: { HStack { Text(draft.plannedAt!, style: .time); Text(draft.postText).lineLimit(2) } }.buttonStyle(.plain) }
                    }
                }
                Panel(title: "全部待发计划") {
                    if planned.isEmpty { Text("在创作台的“⋯”菜单中设置计划时间。") }
                    ForEach(planned) { draft in
                        Button { model.showDraft(draft.id) } label: { HStack { CategoryBadge(category: draft.category); Text(draft.postText).lineLimit(1); Spacer(); Text(draft.plannedAt!.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain)
                    }
                }
            }.padding(28)
        }.onChange(of: model.schedule.enabled) { _, _ in model.savePreferences() }.onChange(of: model.schedule.style) { _, _ in model.savePreferences() }
    }
}
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("appearance") var appearance = "system"
    var body: some View {
        Form {
            Section("外观") { Picker("显示模式", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") } }
            Section("本地服务") {
                status("n8n", model.health.n8n); status("草稿引擎", model.health.draftEngine); status("Ollama", model.health.ollama)
                HStack { Button("启动本地服务") { model.startRuntime() }; Button("停止专用服务") { model.stopRuntime() }; Button("打开 n8n") { model.openN8N() }; Button("刷新") { Task { await model.refresh() } } }
            }
            Section("X 账号 · 可选") {
                Text("不连接也能生成、编辑和导出图文，以及粘贴原帖写回复。读取关注动态或 API 发布需要开发者账号与余额。").foregroundStyle(.secondary)
                TextField("Native App Client ID", text: $model.clientID).textFieldStyle(.roundedBorder)
                HStack { Button("连接 / 重新授权") { model.connectX() }; if model.isConnected { Button("断开") { model.disconnectX() } }; if let account = model.xAccount { Text("@" + account.username) } }
                Text("令牌仅保存在 macOS 钥匙串。发布前会重新核对账号。回调地址：xcontentassistant://oauth/callback").font(.caption).textSelection(.enabled)
            }
            Section("诊断") {
                LabeledContent("版本", value: "0.3.2")
                LabeledContent("模型", value: "qwen3:8b")
                LabeledContent("草稿引擎", value: model.runtime.engineBaseURL.absoluteString)
                LabeledContent("n8n", value: model.runtime.n8nBaseURL.absoluteString)
                Text(model.runtime.runtimeRoot.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("打开素材目录") { NSWorkspace.shared.open(model.runtime.runtimeRoot.appendingPathComponent("content-library")) }
                Text("互动记录：\(model.interactions.store.root.path)").font(.caption.monospaced()).textSelection(.enabled)
                Button("打开互动记录目录") { NSWorkspace.shared.open(model.interactions.store.root) }
                Text("关闭最后一个窗口时先保存编辑，再退出。OrbStack、Ollama 和专用服务不随 App 关闭。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onChange(of: model.clientID) { _, _ in model.savePreferences() }
    }
    func status(_ name: String, _ ready: Bool) -> some View { LabeledContent(name) { Label(ready ? "正常" : "未就绪", systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ready ? .green : .orange) } }
}
