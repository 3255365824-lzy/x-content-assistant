import AppKit
import Combine
import Foundation
import XContentAssistantCore

private actor OriginalDisk {
    let store: InteractionStore
    init(_ store: InteractionStore) { self.store = store }
    func run<T: Sendable>(_ body: @Sendable (InteractionStore) throws -> T) rethrows -> T { try body(store) }
}

@MainActor final class OriginalIdeaModel: ObservableObject {
    @Published private(set) var items: [OriginalIdea] = []
    @Published var preferences = OriginalPreferences()
    @Published private(set) var loaded = false
    @Published private(set) var generating = false
    @Published private(set) var saving = false
    @Published var selectedID: String?
    @Published var message = "无需原帖或素材，在本机自己写一组。"
    @Published var error: String?
    @Published var skipped: [String] = []
    @Published var openingID: String?
    private let disk: OriginalDisk
    private let client: OriginalDraftClient
    private let interaction: InteractionModel
    private let hot: HotMaterialModel
    private var work: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var pending: [String: String] = [:]
    private var editTicks: [String: Int] = [:]
    private var epoch = 0
    private var closed = false
    init(interaction: InteractionModel, hot: HotMaterialModel, client: OriginalDraftClient = OriginalDraftClient()) {
        self.interaction = interaction; self.hot = hot; self.client = client; disk = OriginalDisk(interaction.store)
    }
    var hasPendingEdits: Bool { !pending.isEmpty }
    func text(_ item: OriginalIdea) -> String { pending[item.id] ?? item.text }
    func load() async {
        let tick = epoch
        do {
            let db = try await disk.run { try $0.load() }
            guard tick == epoch else { return }
            items = db.originalIdeas ?? []
            if !loaded { preferences = db.originalPreferences ?? OriginalPreferences(); loaded = true }
            if selectedID == nil { selectedID = items.first?.id }
        } catch { self.error = "自拟灵感读取失败：\(error.localizedDescription)" }
    }
    func generate(otherModelBusy: Bool = false) {
        guard loaded, !generating, !closed else { return }
        guard !otherModelBusy, !hot.busy, !interaction.materialModelBusy, interaction.generatingID == nil else {
            error = "本机正在写其他内容，完成后再生成这组。"; return
        }
        do { try preferences.validate() } catch { self.error = error.localizedDescription; return }
        let request = preferences
        generating = true; interaction.originalModelBusy = true; skipped = []; error = nil
        work = Task {
            defer { generating = false; interaction.originalModelBusy = false; work = nil }
            do {
                try await disk.run { try $0.saveOriginalPreferences(request) }
                guard await flush() else { return }; await load()
                let existing = items.flatMap { [$0.text] + $0.versions.map(\.text) }
                let result = try await client.generate(preferences: request, existing: existing) { [weak self] stage in await self?.setStage(stage) }
                try Task.checkCancellation()
                message = "正在保存通过检查的短帖…"
                let ids = try await disk.run { try $0.insertOriginals(result.ideas) }
                skipped = result.skipped
                if ids.count < result.ideas.count { skipped.append("保存时发现与现有内容重复，已去重。") }
                epoch += 1; await load(); selectedID = ids.first ?? selectedID
                message = "准备好 \(ids.count) 条轻观点\(skipped.isEmpty ? "" : "，\(skipped.count) 条未通过或重复")。先看看合不合你的口味，没有公开发布。"
            } catch {
                if Task.isCancelled { message = "已停止本轮生成，已有内容保留。" }
                else { self.error = "生成未完成：\(error.localizedDescription)。原有内容保留，可手动再试。" }
            }
        }
    }
    private func setStage(_ value: String) { message = value }
    func stop() { work?.cancel() }
    func shutdown() { closed = true; stop() }
    func edit(_ item: OriginalIdea, text: String) {
        guard item.editable else { return }
        epoch += 1; pending[item.id] = text; editTicks[item.id, default: 0] += 1
        objectWillChange.send()
        guard saveTask == nil else { return }
        saving = true
        saveTask = Task {
            defer { saveTask = nil; saving = false }
            while !pending.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                guard await persistEdits() else { return }
            }
        }
    }
    private func persistEdits() async -> Bool {
        let snapshot = pending
        for (id, value) in snapshot {
            let tick = editTicks[id]
            do {
                try await disk.run { try $0.editOriginal(id, text: value) }
                if editTicks[id] == tick { pending.removeValue(forKey: id) }
            } catch { self.error = "尚未保存：\(error.localizedDescription)"; return false }
        }
        epoch += 1; await load(); return true
    }
    func flush() async -> Bool {
        await saveTask?.value
        if pending.isEmpty { return true }; return await persistEdits()
    }
    func organize(_ item: OriginalIdea, favorite: Bool? = nil, archived: Bool? = nil, restore: Bool = false) async {
        guard await flush() else { return }
        do {
            _ = try await disk.run { try $0.updateOriginal(item.id) { value in
                if let favorite { value.favorite = favorite }; if let archived { value.archived = archived }
                if restore { value.handoffAt = nil }
            } }; epoch += 1; await load()
        } catch { self.error = error.localizedDescription }
    }
    func copy(_ item: OriginalIdea) {
        guard !RunConfiguration.isTest else { return }
        NSPasteboard.general.clearContents(); _ = NSPasteboard.general.setString(text(item), forType: .string)
        message = "已复制文案，没有发布。"
    }
    func openPost(_ item: OriginalIdea) async {
        guard openingID == nil else { return }; openingID = item.id; defer { openingID = nil }
        guard await flush(), let current = items.first(where: { $0.id == item.id }), current == item else {
            error = "文案刚改变，请核对保存后的版本再去 X。"; return
        }
        do {
            let url = try HotMaterialRules.intentURL(text: item.text)
            try await disk.run { try $0.handoffOriginal(item) }; epoch += 1; await load()
            if !RunConfiguration.isTest { try await InteractionModel.openInEdge(url) }
            message = "已交接到 X 编辑页面，不代表已发布；仍由你最后点击发送。"
        } catch { self.error = "\(error.localizedDescription)；不会自动重试，文案仍保留在全部状态。" }
    }
}
