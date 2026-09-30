import AppKit
import SwiftUI
import XContentAssistantCore

struct MaterialsHubView: View {
    @EnvironmentObject var model: AppModel
    @State private var source = "自拟灵感"
    var body: some View {
        VStack(spacing: 0) {
            Picker("素材来源", selection: $source) {
                Text("自拟灵感").tag("自拟灵感"); Text("热门灵感").tag("热门灵感"); Text("本地图片 / 文档").tag("本地图片 / 文档")
            }.pickerStyle(.segmented).frame(width: 450).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if source == "自拟灵感" { OriginalIdeaWorkspace(center: model.originalIdeas) }
            else if source == "热门灵感" { HotMaterialWorkspace(center: model.hotMaterials, interaction: model.interactions) }
            else { MaterialsView() }
        }
    }
}
struct CreationHubView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Picker("创作类型", selection: Binding(get: { model.showOriginalDrafts ? "自拟短帖" : model.showHotDrafts ? "热门短帖草稿" : "文件图文稿" }, set: { value in model.showOriginalDrafts = value == "自拟短帖"; model.showHotDrafts = value == "热门短帖草稿" })) {
                Text("文件图文稿").tag("文件图文稿"); Text("热门短帖草稿").tag("热门短帖草稿"); Text("自拟短帖").tag("自拟短帖")
            }.pickerStyle(.segmented).frame(width: 420).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if model.showOriginalDrafts { OriginalIdeaWorkspace(center: model.originalIdeas, studio: true) }
            else if model.showHotDrafts { HotMaterialWorkspace(center: model.hotMaterials, interaction: model.interactions, studio: true) }
            else { StudioView() }
        }
    }
}
struct HotMaterialWorkspace: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: HotMaterialModel
    @ObservedObject var interaction: InteractionModel
    var studio = false
    @State private var category = "全部"
    @State private var status = "未交接"
    @State private var favorites = false
    @State private var archived = false
    var visible: [HotMaterial] {
        center.items.filter { item in
            item.archived == archived && (!favorites || item.favorite) &&
            (category == "全部" || item.post.category == category) &&
            (status == "全部" || (status == "未交接" ? item.state != .handedOff : item.state.label == status)) &&
            (!studio || item.state != .collected || !item.versions.isEmpty) &&
            (model.search.isEmpty || (item.post.text + item.post.username + item.text).localizedCaseInsensitiveContains(model.search))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(studio ? "把灵感，写成自己的话。" : "发现热度，留下自己的角度。").font(.title2.bold())
                        Text("近期关注流里的高互动候选 · 不是全网热榜 · 不照搬原帖，不自动发布").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await center.fetch() } } label: { Label("获取热门并加工", systemImage: "flame") }
                        .buttonStyle(.borderedProminent).disabled(!center.loaded || center.fetching || interaction.discoveryJob?.active == true)
                    Button("偏好与门槛") { center.showSettings = true }.disabled(!center.loaded)
                    Button("连接扩展") { interaction.showExtension = true }
                }
                HStack(spacing: 18) {
                    Toggle("每 \(center.preferences.intervalHours) 小时自动获取", isOn: Binding(get: { center.preferences.automatic }, set: { center.setAutomatic($0) }))
                    Toggle("获取后自动加工", isOn: Binding(get: { center.preferences.autoAdapt }, set: { center.preferences.autoAdapt = $0; center.savePreferences() }))
                    Spacer()
                    Text(center.nextRunText).font(.caption).foregroundStyle(.secondary)
                }.toggleStyle(.checkbox).disabled(!center.loaded)
                Text("近 \(center.preferences.maxAgeHours) 小时 · 至少 \(center.preferences.minimumLikes) 赞或 \(center.preferences.minimumReplies) 评 · 每轮最多 \(center.preferences.limit) 条 · \(center.preferences.length) · App 关闭后停止，不补跑错过的采集")
                    .font(.caption).foregroundStyle(.secondary)
                if let job = interaction.discoveryJob, job.isMaterials {
                    HStack {
                        if job.active { ProgressView().controlSize(.small) }
                        Text(job.message).font(.caption).textSelection(.enabled)
                        if job.active { Button("取消获取") { interaction.cancelDiscovery() }.controlSize(.small) }
                    }
                    if !job.skipped.isEmpty {
                        DisclosureGroup("为何跳过 \(job.skipped.count) 条") {
                            ForEach(ReplyDiscoverySkipSummary.grouped(job.skipped)) { group in Text("\(group.count) 条：\(group.reason)").font(.caption) }
                        }.font(.caption)
                    }
                }
                if center.generatingID != nil {
                    HStack { ProgressView().controlSize(.small); Text(center.message ?? "本机正在加工…").font(.caption); Button("停止加工") { center.stopWriting() } }
                } else if let message = center.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error = center.error {
                    HStack { Image(systemName: "exclamationmark.triangle"); Text(error).font(.caption).textSelection(.enabled); Spacer(); Button("关闭提示") { center.error = nil } }.foregroundStyle(.orange)
                }
            }.padding(20)
            Divider()
            HStack {
                Picker("分类", selection: $category) { ForEach(["全部"] + InteractionRules.categories, id: \.self) { Text($0) } }.frame(width: 150)
                Picker("状态", selection: $status) { ForEach(["未交接", "待加工", "已准备草稿", "需要检查", "已交接到 X", "全部"], id: \.self) { Text($0) } }.frame(width: 175)
                Toggle("收藏", isOn: $favorites).toggleStyle(.button)
                Toggle("已归档", isOn: $archived).toggleStyle(.button)
                Spacer(); Text("\(visible.count) 条").font(.caption).foregroundStyle(.secondary)
                Button("加工未处理素材") { center.enqueuePending() }.disabled(!center.loaded || center.busy || !center.items.contains(where: \.needsAdaptation))
            }.padding(14)
            Divider()
            HSplitView {
                List(visible, selection: $center.selectedID) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(item.post.category).font(.caption.bold()).foregroundStyle(.indigo); Spacer(); Text(item.state.label).font(.caption2).foregroundStyle(.secondary) }
                        Text(item.post.text).lineLimit(3).font(.callout.weight(.medium))
                        Text("@\(item.post.username) · \(metrics(item))").font(.caption).foregroundStyle(.secondary)
                        if item.favorite { Image(systemName: "star.fill").foregroundStyle(.orange) }
                    }.padding(.vertical, 6).tag(item.id)
                }.listStyle(.inset).frame(minWidth: 245, idealWidth: 300, maxWidth: 370)
                if let item = visible.first(where: { $0.id == center.selectedID }) {
                    HotMaterialInspector(center: center, item: item, studio: studio).id(item.id)
                } else {
                    ContentUnavailableView(visible.isEmpty ? "收一点热度，写自己的看法" : "挑一份素材开始", systemImage: "flame", description: Text("点击「获取热门并加工」。只保留符合真实热度门槛的新帖，没有就少收；也可调整偏好与门槛。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await center.load(); await interaction.startDiscovery() }
        .onChange(of: visible.map(\.id), initial: true) { _, ids in if !ids.contains(center.selectedID ?? "") { center.selectedID = ids.first } }
        .sheet(isPresented: $center.showSettings) { HotMaterialSettings(center: center, value: center.preferences) }
        .sheet(isPresented: $interaction.showExtension) { ExtensionConnectionSheet(center: interaction) }
    }
    func metrics(_ item: HotMaterial) -> String {
        "\(item.post.discovery?.likes.map(String.init) ?? "未知") 赞 · \(item.post.discovery?.replies.map(String.init) ?? "未知") 评"
    }
}

struct HotMaterialInspector: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: HotMaterialModel
    let item: HotMaterial
    var studio: Bool
    var text: String { center.editingText(item) }
    var includeURL: Bool { center.editingLink(item) }
    var validation: (valid: Bool, weightedLength: Int, message: String) { XTextRules.validate(postText: text, sourceURL: item.post.discovery?.postURL, includeSourceURL: includeURL) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { Task { await center.openPost(item) } } label: { Label("去 X 编辑发布", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.borderedProminent).disabled(!validation.valid || !item.editable || center.openingID != nil || text != item.text)
                Button("复制文案") { center.copy(item) }.disabled(text.isEmpty || text != item.text)
                if !studio { Button("在创作台打开") { model.showOriginalDrafts = false; model.showHotDrafts = true; model.section = .queue } }
                Spacer(); Text("不代发").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text("我的短帖").font(.title3.bold()); Spacer(); Button(item.favorite ? "取消收藏" : "收藏") { Task { await center.organize(item, favorite: !item.favorite) } } }
                    TextEditor(text: Binding(get: { text }, set: { center.edit(item, text: $0, includeSourceURL: includeURL) }))
                        .font(.body).frame(minHeight: 170).padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10)).disabled(!item.editable).accessibilityLabel("热门素材改写文案")
                    HStack {
                        Text("\(validation.weightedLength) / 280 · \(center.saving ? "保存中…" : center.hasPendingEdits ? "尚未保存" : "本地保存")").font(.caption).foregroundStyle(validation.valid ? Color.secondary : .orange)
                        Spacer(); Toggle("附原帖链接", isOn: Binding(get: { includeURL }, set: { center.edit(item, text: text, includeSourceURL: $0) })).disabled(!item.editable)
                    }
                    HStack {
                        Button(item.text.isEmpty ? "用我的口吻加工" : "再写一版（保留当前）") { center.rewrite(item) }.disabled(!item.editable || center.busy)
                        Button(item.archived ? "恢复素材" : "归档") { Task { await center.organize(item, archived: !item.archived) } }
                    }
                    if !item.note.isEmpty { Text(item.note).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if item.state == .handedOff {
                        Text("已打开过 X 编辑页，不代表发送成功。文案仍在本机保留。").font(.caption)
                        Button("确认未发，移回草稿") { Task { await center.restoreHandoff(item) } }
                    }
                    Panel(title: "原帖与热度依据") {
                        HStack { Text("@\(item.post.username)").font(.headline); Spacer(); Link("查看原帖", destination: URL(string: item.post.discovery?.postURL ?? item.post.url.absoluteString)!) }
                        Text(item.post.text).font(.callout).textSelection(.enabled)
                        if let e = item.post.discovery {
                            Text("发布 \(e.publishedAt.formatted()) · 观察 \(e.observedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                            Text("可见点赞 \(e.likes.map(String.init) ?? "未知") · 可见评论 \(e.replies.map(String.init) ?? "未知")").font(.caption)
                        }
                        Text("热度不等于真实。这里只基于原帖生成观察或观点，医疗结论须另外核对可靠来源。").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(item.versions.reversed())) { version in
                        Panel(title: "候选角度：" + version.angle) {
                            Text(version.text).textSelection(.enabled)
                            Text("依据摘录：" + version.quote).font(.caption).foregroundStyle(.secondary)
                            if !version.caution.isEmpty { Text(version.caution).font(.caption).foregroundStyle(.orange) }
                            HStack { Text(version.createdAt.formatted()).font(.caption).foregroundStyle(.secondary); Spacer(); Button("采用这版") { Task { await center.adopt(item, text: version.text) } }.disabled(!item.editable) }
                        }
                    }
                }.padding(20)
            }
        }.frame(minWidth: 410, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HotMaterialSettings: View {
    @ObservedObject var center: HotMaterialModel
    @State var value: HotMaterialPreferences
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("挑什么，怎么写").font(.title2.bold())
            Text("来源：Edge 已登录账号的正在关注；沿用已安装的只读扩展。不需要 X API。空选分类表示不限题材。").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading) {
                ForEach(InteractionRules.categories, id: \.self) { category in
                    Toggle(category, isOn: Binding(get: { value.categories.contains(category) }, set: { on in value.categories.removeAll { $0 == category }; if on { value.categories.append(category) } })).toggleStyle(.checkbox)
                }
            }
            HStack {
                Picker("点赞至少", selection: $value.minimumLikes) { ForEach([10, 50, 100, 500, 1000], id: \.self) { Text("\($0)") } }
                Text("或")
                Picker("评论至少", selection: $value.minimumReplies) { ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0)") } }
            }
            HStack {
                Picker("新鲜度", selection: $value.maxAgeHours) { Text("24 小时").tag(24); Text("48 小时").tag(48); Text("72 小时").tag(72) }
                Picker("每轮最多", selection: $value.limit) { Text("5 条").tag(5); Text("10 条").tag(10); Text("20 条").tag(20) }
            }
            HStack {
                Picker("自动间隔", selection: $value.intervalHours) { Text("1 小时").tag(1); Text("3 小时").tag(3); Text("6 小时").tag(6); Text("12 小时").tag(12) }
                Picker("长度", selection: $value.length) { Text("30–60 字").tag("30–60 字"); Text("60–120 字").tag("60–120 字") }
            }
            Text("我的口吻与偏好").font(.headline)
            TextEditor(text: $value.voice).frame(height: 100).border(.quaternary)
            Text("偏好只影响新候选，不覆盖现有编辑。只改写可读文字，缺少上下文、依据或与原帖过于相近时会留下原因。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存偏好") {
                do {
                    try value.validate()
                    value.nextFetchAt = value.automatic ? Date().addingTimeInterval(Double(value.intervalHours * 3600)) : nil
                    center.preferences = value; center.savePreferences(); if center.error == nil { dismiss() }
                } catch { center.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent) }
        }.padding(26).frame(width: 560)
    }
}
