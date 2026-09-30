import AppKit
import Combine
import Foundation
import XContentAssistantCore

// Atomic writes and fsync can be slow on Desktop/iCloud-backed folders. Never do them on the UI actor.
private actor HotMaterialDisk {
    let store: InteractionStore
    init(_ store: InteractionStore) { self.store = store }
    func run<T: Sendable>(_ operation: @Sendable (InteractionStore) throws -> T) rethrows -> T { try operation(store) }
}

@MainActor final class HotMaterialModel: ObservableObject {
    @Published private(set) var items: [HotMaterial] = []
    @Published var preferences = HotMaterialPreferences()
    @Published private(set) var loaded = false
    @Published var selectedID: String?
    @Published var error: String?
    @Published var message: String?
    @Published private(set) var generatingID: String?
    @Published private(set) var queuedCount = 0
    @Published private(set) var fetching = false
    @Published var showSettings = false
    @Published var openingID: String?
    let interaction: InteractionModel
    let store: InteractionStore
    private let writer: HotDraftClient
    private var work: Task<Void, Never>?
    private var queue: [String] = []
    private var manualIDs = Set<String>()
    private var handledJobs = Set<String>()
    private var ticking = false
    private var stopped = false
    private var epoch = 0
    private var pendingEdits: [String: (String, Bool)] = [:]
    private var editRevisions: [String: Int] = [:]
    private var saveTask: Task<Void, Never>?
    private var preferenceTask: Task<Void, Never>?
    private let disk: HotMaterialDisk
    @Published private(set) var saving = false
    init(interaction: InteractionModel, writer: HotDraftClient = HotDraftClient()) {
        self.interaction = interaction; store = interaction.store; self.writer = writer; disk = HotMaterialDisk(interaction.store)
    }
    var busy: Bool { work != nil || fetching }
    var selected: HotMaterial? { items.first { $0.id == selectedID } }
    var nextRunText: String {
        guard preferences.automatic, let next = preferences.nextFetchAt else { return "未开启自动获取" }
        return next.formatted(date: .abbreviated, time: .shortened)
    }
    func load() async {
        let localStore = store, expectedEpoch = epoch
        do {
            let db = try await Task.detached { try localStore.load() }.value
            guard expectedEpoch == epoch else { return }
            items = db.hotMaterials ?? []
            if !loaded {
                preferences = db.hotPreferences ?? HotMaterialPreferences(); try preferences.validate(); loaded = true
                // Do not catch up several missed runs after the App was closed.
                if preferences.automatic && (preferences.nextFetchAt ?? .distantPast) < Date() {
                    preferences.nextFetchAt = Date().addingTimeInterval(Double(preferences.intervalHours * 3600)); savePreferences()
                }
            }
            if selectedID == nil { selectedID = items.first?.id }
        } catch { self.error = "热门素材读取失败，原数据未覆盖：\(error.localizedDescription)" }
    }
    func reload() async {
        epoch += 1
        await load()
    }
    func savePreferences() {
        guard loaded else { return }
        let value = preferences, previous = preferenceTask, localDisk = disk
        epoch += 1
        preferenceTask = Task {
            await previous?.value
            do { try await localDisk.run { try $0.saveHotPreferences(value) }; error = nil }
            catch { self.error = "偏好未保存：\(error.localizedDescription)" }
        }
    }
    private func saveEdits() async -> Bool {
        // The snapshot revision prevents a completed older write from clearing newer typing.
        let snapshot = pendingEdits
        for (id, value) in snapshot {
            let revision = editRevisions[id]
            do {
                try await disk.run { try $0.editHot(id, text: value.0, includeSourceURL: value.1) }
                if editRevisions[id] == revision { pendingEdits.removeValue(forKey: id) }
            } catch { self.error = "尚未保存：\(error.localizedDescription)"; return false }
        }
        await reload(); return true
    }
    var hasPendingEdits: Bool { !pendingEdits.isEmpty }
    func waitForPreferences() async { await preferenceTask?.value }
    func adopt(_ item: HotMaterial, text: String) async {
        edit(item, text: text, includeSourceURL: editingLink(item)); _ = await flush()
    }
    private func markFailure(_ item: HotMaterial, reason: String) async {
        do {
            _ = try await disk.run { try $0.updateHot(item.id) { value in
                guard value.editable, value.revision == item.revision, value.post.text == item.post.text else { return }
                value.note = reason; if value.text.isEmpty { value.state = .needsReview }
            } }
        }
        catch { self.error = error.localizedDescription }
    }
    func setAutomatic(_ enabled: Bool) {
        preferences.automatic = enabled
        preferences.nextFetchAt = enabled ? Date().addingTimeInterval(Double(preferences.intervalHours * 3600)) : nil
        savePreferences()
        message = enabled ? "已开启每 \(preferences.intervalHours) 小时获取；仅 App 打开时运行，不自动发布。" : "已关闭自动获取，现有素材和草稿保留。"
    }
    func fetch() async {
        guard loaded, !fetching else { return }; fetching = true; defer { fetching = false }
        do {
            guard interaction.discoveryJob?.active != true else { throw InteractionError.invalid("正在采集其他内容，完成后再获取热门素材。") }
            try await interaction.fetchHotMaterials(preferences)
            preferences.lastFetchAt = Date()
            preferences.nextFetchAt = preferences.automatic ? Date().addingTimeInterval(Double(preferences.intervalHours * 3600)) : nil
            savePreferences(); message = "正在读取关注流，按真实互动数筛选；完成后自动加工成短帖。"
        } catch { self.error = error.localizedDescription }
    }
    func tick(otherModelBusy: Bool = false) async {
        guard !ticking, !stopped else { return }; ticking = true; defer { ticking = false }
        await load(); guard loaded, !stopped else { return }
        if preferences.automatic && !RunConfiguration.isTest {
            await interaction.startDiscovery()
            if preferences.isDue(now: Date()) && interaction.discoveryJob?.active != true {
                // Reserve one future slot before trying, so service errors cannot create a rapid retry loop.
                preferences.nextFetchAt = Date().addingTimeInterval(Double(preferences.intervalHours * 3600)); savePreferences()
                await fetch()
            }
        }
        if let job = interaction.discoveryJob, job.isMaterials, !job.active, !handledJobs.contains(job.id) {
            handledJobs.insert(job.id)
            if job.state == "complete" { message = job.message; await load() }
            else { message = nil; error = job.message }
        }
        if preferences.autoAdapt && !otherModelBusy && interaction.generatingID == nil { enqueuePending() }
    }
    func enqueuePending() {
        enqueue(items.filter(\.needsAdaptation).map(\.id), manual: false)
    }
    func rewrite(_ item: HotMaterial) { enqueue([item.id], manual: true) }
    private func enqueue(_ ids: [String], manual: Bool) {
        guard !stopped, work?.isCancelled != true else { return }
        if manual && work != nil { message = "本机正在加工，请稍后再改写这一条。"; return }
        var seen = Set(queue + [generatingID].compactMap { $0 })
        for id in ids where seen.insert(id).inserted {
            guard let item = items.first(where: { $0.id == id }), manual ? item.editable : item.needsAdaptation else { continue }
            if manual { manualIDs.insert(id) }
            queue.append(id)
        }
        queuedCount = queue.count
        guard work == nil, !queue.isEmpty else { return }
        work = Task {
            defer { work = nil; generatingID = nil; interaction.materialModelBusy = false; queuedCount = queue.count }
            while !queue.isEmpty && !Task.isCancelled {
                while interaction.generatingID != nil || interaction.originalModelBusy {
                    try? await Task.sleep(for: .milliseconds(300)); if Task.isCancelled { return }
                }
                let id = queue.removeFirst(); queuedCount = queue.count
                let isManual = manualIDs.remove(id) != nil
                guard await flush() else { return }; await reload()
                guard let item = items.first(where: { $0.id == id }), isManual ? item.editable : item.needsAdaptation else { continue }
                generatingID = id; message = "本机正在加工 @\(item.post.username) 的素材；还剩 \(queue.count) 条。"
                interaction.materialModelBusy = true
                do {
                    let version = try await writer.adapt(item.post, preferences: preferences, currentText: item.text)
                    try Task.checkCancellation()
                    guard await flush() else { return }
                    try await disk.run { try $0.addHotVersion(id, version: version, expectedRevision: item.revision, expectedSource: item.post.text) }
                    error = nil
                } catch {
                    if Task.isCancelled { return }
                    let reason = error.localizedDescription
                    await markFailure(item, reason: reason)
                    self.error = reason
                }
                generatingID = nil; interaction.materialModelBusy = false; await reload()
            }
            if !Task.isCancelled { message = "本轮加工完成。草稿可在这里或创作台继续修改；没有公开发布。" }
        }
    }
    func stopWriting() {
        queue.removeAll(); manualIDs.removeAll(); queuedCount = 0; work?.cancel()
        preferences.autoAdapt = false; savePreferences(); message = "已停止自动加工。已有文案保留，可逐条加工或重新开启。"
    }
    func shutdown() { stopped = true; queue.removeAll(); work?.cancel() }
    func edit(_ item: HotMaterial, text: String, includeSourceURL: Bool) {
        epoch += 1
        pendingEdits[item.id] = (text, includeSourceURL)
        editRevisions[item.id, default: 0] += 1
        objectWillChange.send()
        // Coalesce typing, but don't cancel a write already in progress or its ordered successor.
        guard saveTask == nil else { return }
        saving = true
        saveTask = Task {
            defer { saveTask = nil; saving = false }
            while !pendingEdits.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                guard await saveEdits() else { return }
            }
        }
    }
    func editingText(_ item: HotMaterial) -> String { pendingEdits[item.id]?.0 ?? item.text }
    func editingLink(_ item: HotMaterial) -> Bool { pendingEdits[item.id]?.1 ?? item.includeSourceURL }
    func flush() async -> Bool {
        await preferenceTask?.value
        await saveTask?.value
        if pendingEdits.isEmpty { return true }; return await saveEdits()
    }
    func organize(_ item: HotMaterial, favorite: Bool? = nil, archived: Bool? = nil) async {
        guard await flush() else { return }
        do {
            _ = try await disk.run { try $0.updateHot(item.id) { value in
                if let favorite { value.favorite = favorite }; if let archived { value.archived = archived }
            } }; await reload()
        } catch { self.error = error.localizedDescription }
    }
    func restoreHandoff(_ item: HotMaterial) async {
        do { _ = try await disk.run { try $0.updateHot(item.id) { value in if value.state == .handedOff { value.state = .ready; value.handoffAt = nil } } }; await reload() }
        catch { self.error = error.localizedDescription }
    }
    func openPost(_ item: HotMaterial) async {
        guard openingID == nil else { return }; openingID = item.id; defer { openingID = nil }
        guard await flush(), let current = items.first(where: { $0.id == item.id }), current == item else { error = "文案刚发生变化，请核对保存后的版本再打开 X"; return }
        do {
            let url = try HotMaterialRules.intentURL(text: item.finalText)
            try await disk.run { try $0.handoffHot(item) }; await reload()
            if !RunConfiguration.isTest { try await InteractionModel.openInEdge(url) }
            message = "已交接到 X 编辑页面，不代表已发布；最后请你在 X 核对并发送。"
        } catch { self.error = "\(error.localizedDescription)；不会自动重试。若已交接，可在全部状态中找回文案。" }
    }
    func copy(_ item: HotMaterial) {
        guard !RunConfiguration.isTest else { message = "测试模式不修改剪贴板"; return }
        NSPasteboard.general.clearContents(); _ = NSPasteboard.general.setString(item.finalText, forType: .string)
        message = "已复制当前文案；没有发布。"
    }
}
