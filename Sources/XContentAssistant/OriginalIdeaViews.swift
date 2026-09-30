import SwiftUI
import XContentAssistantCore

struct OriginalIdeaWorkspace: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: OriginalIdeaModel
    var studio = false
    @State private var favorites = false
    @State private var archived = false
    @State private var state = "待发送"
    var visible: [OriginalIdea] {
        center.items.filter { item in
            item.archived == archived && (!favorites || item.favorite) &&
            (state == "全部" || (state == "待发送" ? item.handoffAt == nil : item.handoffAt != nil)) &&
            (model.search.isEmpty || (item.text + item.topic).localizedCaseInsensitiveContains(model.search))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("不等热点，自己来点观点。").font(.title2.bold())
                        Text("轻争议 · 吃喝日常 · 直接亮态度 · 不说教、不沉重").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("每组", selection: $center.preferences.count) { ForEach([1, 5, 10, 20], id: \.self) { Text("\($0) 条").tag($0) } }.frame(width: 125).disabled(center.generating)
                    Button { center.generate(otherModelBusy: model.isBusy) } label: { Label("自己写 \(center.preferences.count) 条", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent).disabled(!center.loaded || center.generating)
                }
                HStack {
                    Text("本轮话题").font(.caption).foregroundStyle(.secondary)
                    ForEach(OriginalRules.topics, id: \.self) { topic in
                        Toggle(topic, isOn: Binding(get: { center.preferences.topics.contains(topic) }, set: { on in
                            center.preferences.topics.removeAll { $0 == topic }; if on { center.preferences.topics.append(topic) }
                        })).toggleStyle(.button).disabled(center.generating)
                    }
                    Spacer()
                }
                DisclosureGroup("已采用你喜欢的最后一版风格") {
                    Text(OriginalRules.styleReference).font(.caption).foregroundStyle(.secondary)
                    TextField("口吻微调", text: $center.preferences.voice, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(center.generating)
                    Text("目标 20–50 字，一两句话到包袱就停。只学习节奏，不直接搬例句；这类是主观观点，不是有来源的知识或新闻。").font(.caption).foregroundStyle(.secondary)
                }.font(.caption)
                HStack {
                    if center.generating { ProgressView().controlSize(.small) }
                    Text(center.message).font(.caption).textSelection(.enabled)
                    if center.generating { Button("停止") { center.stop() }.controlSize(.small) }
                }
                if let error = center.error { HStack { Image(systemName: "exclamationmark.triangle"); Text(error).font(.caption); Spacer(); Button("关闭提示") { center.error = nil } }.foregroundStyle(.orange) }
                if !center.skipped.isEmpty { DisclosureGroup("未采用 \(center.skipped.count) 条的原因") { ForEach(Array(center.skipped.enumerated()), id: \.offset) { _, reason in Text(reason).font(.caption) } }.font(.caption) }
            }.padding(20)
            Divider()
            HStack {
                Picker("状态", selection: $state) { ForEach(["待发送", "已交接到 X", "全部"], id: \.self) { Text($0) } }.frame(width: 200)
                Toggle("收藏", isOn: $favorites).toggleStyle(.button)
                Toggle("已归档", isOn: $archived).toggleStyle(.button)
                Spacer(); Text("\(visible.count) 条 · 本机生成，无外部来源").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
            Divider()
            HSplitView {
                List(visible, selection: $center.selectedID) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(item.topic).font(.caption.bold()).foregroundStyle(.purple); Spacer(); if item.favorite { Image(systemName: "star.fill").foregroundStyle(.orange) } }
                        Text(item.text.isEmpty ? "（已清空，请继续编辑）" : item.text).font(.callout).lineLimit(4)
                        Text(item.handoffAt == nil ? "自拟观点 · 待审核" : "已交接，不代表已发").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).tag(item.id)
                }.listStyle(.inset).frame(minWidth: 250, idealWidth: 330, maxWidth: 400)
                if let item = visible.first(where: { $0.id == center.selectedID }) {
                    OriginalIdeaInspector(center: center, item: item, studio: studio)
                } else {
                    ContentUnavailableView("直接来一组轻观点", systemImage: "lightbulb", description: Text("不需要爆帖、原文或 API Key。点「自己写 10 条」，本机模型会先构思，再检查风格和重复。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await center.load() }
        .onChange(of: visible.map(\.id), initial: true) { _, ids in if !ids.contains(center.selectedID ?? "") { center.selectedID = ids.first } }
    }
}

struct OriginalIdeaInspector: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: OriginalIdeaModel
    let item: OriginalIdea
    var studio: Bool
    var text: String { center.text(item) }
    var validation: (valid: Bool, weightedLength: Int, message: String) { XTextRules.validate(postText: text, sourceURL: nil, includeSourceURL: false) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { Task { await center.openPost(item) } } label: { Label("去 X 编辑发布", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.borderedProminent).disabled(!item.editable || !validation.valid || text != item.text || center.openingID != nil)
                Button("复制文案") { center.copy(item) }.disabled(text.isEmpty)
                if !studio { Button("在创作台打开") { model.showOriginalDrafts = true; model.showHotDrafts = false; model.section = .queue } }
                Spacer()
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text(item.topic + " · 自拟观点").font(.title3.bold()); Spacer(); Button(item.favorite ? "取消收藏" : "收藏") { Task { await center.organize(item, favorite: !item.favorite) } } }
                    TextEditor(text: Binding(get: { text }, set: { center.edit(item, text: $0) }))
                        .font(.title3).frame(minHeight: 160).padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).disabled(!item.editable).accessibilityLabel("自拟轻观点文案")
                    Text("\(validation.weightedLength) / 280 · \(center.saving ? "保存中…" : center.hasPendingEdits ? "尚未保存" : "本地保存")").font(.caption).foregroundStyle(validation.valid ? Color.secondary : .orange)
                    Text("AI 自拟的主观表达，无外部原帖、热度或事实依据；不是医学结论。请先看是否符合你的看法，再由你发布。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(item.archived ? "恢复" : "归档") { Task { await center.organize(item, archived: !item.archived) } }
                        if item.editable, let first = item.versions.first { Button("恢复生成初稿") { center.edit(item, text: first.text) } }
                        if item.handoffAt != nil { Button("确认未发，移回草稿") { Task { await center.organize(item, restore: true) } } }
                    }
                    if item.handoffAt != nil { Text("已交接到 X，不代表已发布；如未发送可以移回草稿。").font(.caption).foregroundStyle(.orange) }
                    Text("生成于 \(item.createdAt.formatted())").font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }
        }.frame(minWidth: 410, maxWidth: .infinity, maxHeight: .infinity)
    }
}
