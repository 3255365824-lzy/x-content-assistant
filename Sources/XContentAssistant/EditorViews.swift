import SwiftUI
import AppKit
import UniformTypeIdentifiers
import XContentAssistantCore

struct AssetView: View {
    @EnvironmentObject var model: AppModel
    let draft: DraftManifest
    var body: some View {
        if let asset = draft.media.first, let image = NSImage(contentsOf: model.runtime.localFile(for: draft, asset: asset)) {
            Image(nsImage: image).resizable().scaledToFit()
        } else { ContentUnavailableView("暂无配图", systemImage: "photo") }
    }
}
struct StudioView: View {
    @EnvironmentObject var model: AppModel
    var history = false
    @State var archived = false
    @State var category = "全部"
    var visible: [DraftManifest] {
        let base = history ? model.drafts.filter { $0.status == .published } : model.drafts.filter { $0.status != .published && $0.archived == archived }
        return base.filter { (category == "全部" || $0.category.rawValue == category) && (model.search.isEmpty || ($0.postText + " " + ($0.sourceTitle ?? "")).localizedCaseInsensitiveContains(model.search)) }
            .sorted { history ? $0.updatedAt > $1.updatedAt : ($0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order) }
    }
    var body: some View {
        GeometryReader { layout in
        HSplitView {
            VStack(spacing: 12) {
                Picker("分类", selection: $category) { ForEach(["全部", "医学", "AI"], id: \.self) { Text($0) } }.pickerStyle(.segmented).padding(.horizontal, 14).padding(.top, 14)
                if !history { Toggle("显示已归档", isOn: $archived).toggleStyle(.switch).controlSize(.mini).padding(.horizontal, 16) }
                ScrollView {
                LazyVStack(spacing: 6) {
                ForEach(visible) { draft in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack { CategoryBadge(category: draft.category, selected: model.selectedDraftID == draft.id); Spacer(); Label(draft.status.label, systemImage: draft.status.symbol).font(.caption2).foregroundStyle(draft.status == .needsConfirmation ? .orange : .secondary) }
                        HStack(alignment: .top, spacing: 10) { AssetView(draft: draft).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 7)); Text(draft.postText).font(.callout.weight(.medium)).lineLimit(3) }
                        if let time = draft.plannedAt { Label(time.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar").font(.caption2).foregroundStyle(.secondary) }
                    }.padding(12)
                    .background(model.selectedDraftID == draft.id ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedDraftID = draft.id }
                    .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                    .onDrag { NSItemProvider(object: draft.id as NSString) }
                    .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                        guard !history, let provider = providers.first else { return false }
                        _ = provider.loadObject(ofClass: String.self) { value, _ in
                            guard let value else { return }
                            Task { @MainActor in await model.moveDraft(value, before: draft.id) }
                        }
                        return true
                    }
                }
                }.padding(10)
                }
                Text(history ? "发布回执与人工记录分别标识" : "拖动调整待发顺序 · 不会自动发布").font(.caption2).foregroundStyle(.secondary).padding(12)
            }.frame(minWidth: 240, idealWidth: 285, maxWidth: 330).frame(height: layout.size.height)
            if let draft = visible.first(where: { $0.id == model.selectedDraftID }) {
                if history { PublishedDetail(draft: draft) } else { DraftStudio(editor: model.editor(draft)).id(draft.id) }
            } else { ContentUnavailableView(history ? (visible.isEmpty ? "还没有发布记录" : "选择一条发布记录") : "选择一条草稿开始创作", systemImage: history ? "clock" : "square.and.pencil", description: Text(history ? "导出不会被标为已发布。" : "这里可以修改文案、比较版本、调整配图。")) .frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(width: layout.size.width, height: layout.size.height)
        }.onChange(of: model.selectedDraftID) { _, _ in Task { _ = await model.flushAll() } }
    }
}
struct DraftStudio: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var editor: DraftEditor
    @State var tab = "编辑"
    @State var plannedAt = Date().addingTimeInterval(3600)
    @State var showPlan = false
    @State var showManual = false
    @State var manualURL = ""
    @State var confirmNotPosted = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editor.draft.sourceTitle ?? "本地创作").font(.headline).lineLimit(1)
                    Text(editor.saveState).font(.caption).foregroundStyle(editor.dirty ? .orange : .secondary)
                }; Spacer()
                Button { Task { _ = await editor.flush() } } label: { Image(systemName: "square.and.arrow.down") }.help("保存 ⌘S").keyboardShortcut("s").disabled(!editor.editable)
                Menu {
                    Button("复制最终文案") { model.copyText(editor) }
                    Button("复制配图") { Task { await model.copyImage(editor) } }
                    Button("导出图文包…") { Task { await model.export(editor) } }
                    Divider()
                    Button("设置计划时间…") { plannedAt = editor.draft.plannedAt ?? Date().addingTimeInterval(3600); showPlan = true }.disabled(!editor.editable)
                    Button("登记手动发布…") { showManual = true }.disabled(editor.draft.status == .publishing)
                    Button(editor.draft.archived ? "恢复草稿" : "归档草稿") { Task { await model.patchDraft(editor.draft, values: ["archived": !editor.draft.archived]) } }.disabled(!editor.editable)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
                Button(model.preparingPublish ? "核对账号…" : "发布确认…") { Task { await model.preparePublish(editor) } }.buttonStyle(.borderedProminent).disabled(!editor.editable || !editor.validation.valid || model.preparingPublish || model.publishingIDs.contains(editor.draft.id))
            }.padding(18)
            Divider()
            if let error = editor.draft.lastError {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    if editor.draft.status == .needsConfirmation {
                        HStack { Button("打开 X 核对") { NSWorkspace.shared.open(URL(string: "https://x.com/home")!) }; Button("已核对，确实未发出…") { confirmNotPosted = true }; Button("已发出，登记链接…") { showManual = true } }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.06))
            }
            GeometryReader { geometry in
                if geometry.size.width >= 760 {
                    HSplitView { editPane.frame(minWidth: 370); previewPane.frame(minWidth: 310) }
                } else {
                    VStack(spacing: 0) { Picker("视图", selection: $tab) { Text("编辑").tag("编辑"); Text("成品预览").tag("预览") }.pickerStyle(.segmented).padding(14); if tab == "编辑" { editPane } else { previewPane } }
                }
            }
        }
        .onChange(of: editor.text) { _, _ in editor.changed() }.onChange(of: editor.sourceURL) { _, _ in editor.changed() }
        .onChange(of: editor.includeURL) { _, _ in editor.changed() }.onChange(of: editor.card) { _, _ in editor.changed() }
        .onDisappear { Task { _ = await editor.flush() } }
        .sheet(isPresented: $showPlan) { planSheet }
        .sheet(isPresented: $showManual) { manualSheet }
        .confirmationDialog("确定已经在 X 核对，且这条内容没有发出？", isPresented: $confirmNotPosted) { Button("我已核对，确认未发出") { Task { await model.action(editor.draft, name: "resolve-uncertain", values: ["confirmedNotPosted": true]) } } } message: { Text("这会允许你再次手动发布。若已经发出，请登记帖子链接，避免重复。") }
    }
    var editPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Panel(title: "文案") {
                    TextEditor(text: $editor.text).font(.system(size: 15)).lineSpacing(5).frame(minHeight: 200).scrollContentBackground(.hidden).disabled(!editor.editable)
                    HStack { Text("\(editor.validation.weightedLength) / 280").monospacedDigit(); Spacer(); Text(editor.validation.message) }.font(.caption).foregroundStyle(editor.validation.valid ? Color.secondary : Color.red)
                    HStack { ForEach(["再写一版", "更口语", "缩短", "加强开头"], id: \.self) { action in Button(action) { Task { await model.generate(style: editor.draft.style, draftID: editor.draft.id, action: action) } }.controlSize(.small).disabled(!editor.editable || model.isBusy) } }
                }
                Panel(title: "来源与依据") {
                    Text(editor.draft.evidence).font(.callout).textSelection(.enabled)
                    Divider(); Text(editor.draft.sourceTitle ?? "本地素材").font(.caption.weight(.medium)); Text(editor.draft.sourceDate ?? "来源日期未提供").font(.caption).foregroundStyle(.secondary)
                    TextField("原文链接，可不填", text: $editor.sourceURL).textFieldStyle(.roundedBorder).disabled(!editor.editable)
                    Toggle("发布时附链接", isOn: $editor.includeURL).disabled(editor.sourceURL.isEmpty || !editor.editable)
                    Text("链接开关会同时影响预览、导出和发布确认。").font(.caption2).foregroundStyle(.secondary)
                }
                Panel(title: "信息卡片") {
                    Picker("模板", selection: $editor.card.template) { Text("观点卡").tag("bold_opinion"); Text("常识卡").tag("knowledge") }.pickerStyle(.segmented)
                    TextField("标题 / 强开头", text: $editor.card.hook, axis: .vertical).lineLimit(2...4)
                    TextField("事实锚点", text: $editor.card.fact, axis: .vertical).lineLimit(2...4)
                    TextField("反转 / 简短解释", text: $editor.card.ending, axis: .vertical).lineLimit(2...3)
                    Text("保存后生成真实 PNG；文字放不下会提示缩短，不会截掉事实。").font(.caption2).foregroundStyle(.secondary)
                    if !editor.draft.availableMedia.isEmpty {
                        Menu("选择配图") { ForEach(editor.draft.availableMedia) { asset in Button((asset.madeWithAI ? "信息卡 " : "原图 ") + String(asset.id.prefix(6))) { Task { await model.patchDraft(editor.draft, values: ["mediaID": asset.id]) } } } }
                    }
                }.textFieldStyle(.roundedBorder).disabled(!editor.editable)
                Panel(title: "版本历史 · 候选不会覆盖当前内容") {
                    ForEach(editor.draft.versions.reversed()) { version in
                        DisclosureGroup {
                            Text(version.postText).textSelection(.enabled).font(.callout).padding(.vertical, 8)
                            Button(version.id == editor.draft.selectedVersionID ? "当前版本" : "采用为新修订") { Task { await model.patchDraft(editor.draft, values: ["restoreVersionID": version.id]) } }.disabled(version.id == editor.draft.selectedVersionID || !editor.editable)
                        } label: { HStack { Text(version.label); Spacer(); Text(version.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
                    }
                }
            }.padding(20)
        }
    }
    var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("成品预览").font(.headline); Spacer(); Text("并非已发布").font(.caption).foregroundStyle(.secondary) }
                Panel(title: model.xAccount.map { "@" + $0.username } ?? "你的 X 账号") {
                    Text(editor.finalText).font(.system(size: 16)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    AssetView(draft: editor.draft).clipShape(RoundedRectangle(cornerRadius: 12)).onTapGesture { if let asset = editor.draft.media.first { model.previewURL = model.runtime.localFile(for: editor.draft, asset: asset) } }
                    if editor.dirty { Label("文字有未保存修改；图片展示最近成功渲染版本", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
                    if editor.draft.media.first?.madeWithAI == true { Label("AI 生成信息卡，请核对", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary) }
                }
                HStack { Button("复制文字") { model.copyText(editor) }; Button("复制配图") { Task { await model.copyImage(editor) } }; Button("导出…") { Task { await model.export(editor) } } }
                Text("没有连接 X 也能复制或导出。公开发布始终需要单独确认。").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
    var planSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("计划发帖时间").font(.title2.bold()); DatePicker("时间", selection: $plannedAt)
            Text("仅在 App 打开时提醒；不会自动发帖。错过的提醒不补跑。").foregroundStyle(.secondary)
            HStack { Button("取消计划") { showPlan = false; Task { await model.patchDraft(editor.draft, values: ["plannedAt": NSNull()]) } }; Spacer(); Button("返回") { showPlan = false }; Button("保存") { showPlan = false; Task { await model.patchDraft(editor.draft, values: ["plannedAt": ISO8601DateFormatter().string(from: plannedAt)]) } }.buttonStyle(.borderedProminent) }
        }.padding(26).frame(width: 430)
    }
    var manualSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("登记已经发出的帖子").font(.title2.bold()); Text("仅在你已核对真实帖子后使用。记录会注明“人工确认”，不作为 API 回执。").foregroundStyle(.secondary)
            TextField("https://x.com/账号/status/帖子ID", text: $manualURL).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("取消") { showManual = false }; Button("我已核对，登记") { showManual = false; Task { guard await editor.flush() else { return }; await model.action(editor.draft, name: "manual-publication", values: ["postURL": manualURL]) } }.buttonStyle(.borderedProminent).disabled(manualURL.isEmpty) }
        }.padding(26).frame(width: 490)
    }
}
struct PublishConfirmation: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let snapshot: PublicationSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("最后确认，再发出去").font(.title2.bold())
            Label("@" + snapshot.account.username, systemImage: "person.crop.circle.fill").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(snapshot.finalText).font(.body).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if let data = snapshot.imageData, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280).frame(maxWidth: .infinity) }
                }
            }.frame(maxHeight: 440)
            HStack { Text("\(XTextRules.weightedLength(snapshot.finalText)) / 280"); Spacer(); Text(snapshot.draft.includeSourceURL ? "附原文链接" : "不附原文链接") }.font(.caption).foregroundStyle(.secondary)
            Text(XTextRules.containsURL(snapshot.finalText) ? "创建帖文估算约 $0.200；其他 API 操作可能另收费。" : "创建帖文估算约 $0.015；其他 API 操作可能另收费。").font(.caption)
            Text("费用以 X Developer Console 为准。确认后会公开发布。修改内容请返回编辑，再重新确认。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }; Button(RunConfiguration.isTest ? "隔离预览 · 发布已禁用" : "确认并公开发布") { Task { await model.publish(snapshot) } }.buttonStyle(.borderedProminent).disabled(RunConfiguration.isTest || model.publishingIDs.contains(snapshot.draft.id)) }
        }.padding(26).frame(width: 540)
    }
}
struct PublishedDetail: View {
    @EnvironmentObject var model: AppModel
    let draft: DraftManifest
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { CategoryBadge(category: draft.category); Spacer(); Label(draft.publication?.kind == "manual_confirmed" ? "人工确认记录" : "API 发布回执", systemImage: "checkmark.seal").foregroundStyle(.green) }
                Text(draft.publication?.finalText ?? draft.postText).font(.title3).lineSpacing(7).textSelection(.enabled)
                AssetView(draft: draft).frame(maxHeight: 440).frame(maxWidth: .infinity)
                if let receipt = draft.publication {
                    Panel(title: "发布记录") {
                        Text(receipt.publishedAt.formatted(date: .complete, time: .shortened))
                        if let url = URL(string: receipt.postURL) { Link("在 X 查看帖子 ↗", destination: url) }
                        Text("帖子 ID：" + receipt.postID).font(.caption.monospaced())
                        Text("最终文案 SHA256：" + receipt.finalTextHash).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
                if let error = draft.lastError { Text(error).foregroundStyle(.orange); Button("修复归档") { Task { await model.action(draft, name: "repair-archive") } } }
                Panel(title: "素材依据") { Text(draft.evidence).textSelection(.enabled) }
            }.padding(28)
        }.frame(maxWidth: .infinity)
    }
}
