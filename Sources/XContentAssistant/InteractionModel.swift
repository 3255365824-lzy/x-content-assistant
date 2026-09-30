import AppKit
import Combine
import Foundation
import XContentAssistantCore

@MainActor final class InteractionModel: ObservableObject {
    @Published var items: [InteractionItem] = []
    @Published var selectedID: String?
    @Published var error: String?
    @Published var message: String?
    @Published var lastFetchedAt: Date?
    @Published var isFetching = false
    @Published var generatingID: String?
    @Published var materialModelBusy = false
    @Published var originalModelBusy = false
    @Published var autoRefresh = false
    @Published var autoDraft = true { didSet {
        persistReplyPreferences()
        if preferencesLoaded && autoDraft && !oldValue { prepareMissingReplies() }
    } }
    @Published var nextRefresh: Date?
    @Published var tone = ReplyWritingRules.defaultTone { didSet { persistReplyPreferences() } }
    @Published var useStyleReference = true { didSet { persistReplyPreferences() } }
    @Published var styleReferenceMessage = ""
    @Published var discoveryPolicy = ReplyDiscoveryPolicy() { didSet { persistReplyPreferences() } }
    @Published private(set) var preferencesLoaded = false
    @Published private(set) var replyQueueCount = 0
    @Published private(set) var replyBatchMessage: String?
    @Published var discoveryJob: DiscoveryJob?
    @Published var extensionConnected = false
    @Published var extensionPaired = false
    @Published var showExtension = false
    @Published var discoveryMessage = "扩展尚未连接"
    private var discoveryBridge: DiscoveryBridge?
    private var discoveryStarting = false
    private var discoveryMonitor: Task<Void, Never>?
    private var discoveryGeneration: Task<Void, Never>?
    private var pendingReplyIDs: [String] = []
    private var replyBatchTotal = 0
    private var replyBatchCompleted = 0
    private var replyBatchNeedsContext = 0
    private var replyBatchSkipped = 0
    private var handledDiscoveryJobs = Set<String>()
    @Published var showImport = false
    @Published var recordItem: InteractionItem?
    @Published var openingID: String?
    @Published var lastHandoffURL: URL?
    @Published var loadingStore = false
    var autoAccountID: String?
    let store: InteractionStore
    private let generator: LocalReplyClient
    private let browserOpener: @MainActor (URL) async throws -> Void
    private var generationTask: Task<Void, Never>?
    private var localReadEpoch = 0
    private var stoppedDuringInitialLoad = false
    init(root: URL, generator: LocalReplyClient = LocalReplyClient(), synchronousInitialLoad: Bool = false,
         browserOpener: @escaping @MainActor (URL) async throws -> Void = InteractionModel.openInEdge) {
        store = InteractionStore(root: root); self.generator = generator; self.browserOpener = browserOpener
        if synchronousInitialLoad { reload(); loadPreferences() }
        else { Task {
            await loadPreferencesAsync(); await reloadAsync()
            if !stoppedDuringInitialLoad && !RunConfiguration.isTest { resumeReplyPreparation() }
        } }
    }
    private func applyPreferences(_ value: ReplyPreferences) {
        discoveryPolicy = value.discovery; autoDraft = value.autoDraft
        tone = value.tone; useStyleReference = value.useStyleReference
        preferencesLoaded = true
    }
    private func loadPreferences() {
        do { applyPreferences(try store.loadReplyPreferences()) }
        catch { self.error = "读取选帖设置失败，原设置未覆盖：\(error.localizedDescription)" }
    }
    private func loadPreferencesAsync() async {
        let localStore = store
        do { applyPreferences(try await Task.detached { try localStore.loadReplyPreferences() }.value) }
        catch { self.error = "读取选帖设置失败，原设置未覆盖：\(error.localizedDescription)" }
    }
    private func persistReplyPreferences() {
        guard preferencesLoaded else { return }
        var value = ReplyPreferences(); value.discovery = discoveryPolicy; value.autoDraft = autoDraft
        value.tone = tone; value.useStyleReference = useStyleReference
        do { try store.saveReplyPreferences(value) }
        catch { self.error = "保存选帖设置失败：\(error.localizedDescription)" }
    }
    var selected: InteractionItem? { items.first { $0.id == selectedID } }
    var missingReplyCount: Int { items.filter(\.needsReplyPreparation).count }
    var preparingReplies: Bool { generatingID != nil || discoveryGeneration != nil }
    func resumeReplyPreparation() {
        if preferencesLoaded && autoDraft { prepareMissingReplies() }
    }
    func prepareMissingReplies() {
        guard preferencesLoaded else { return }
        // Reload before selecting the backlog so newer manual edits are respected.
        reload(); generateDiscovered([])
    }
    func selectVisible(_ ids: [String]) {
        if let selectedID, ids.contains(selectedID) { return }
        selectedID = ids.first
    }
    var shouldRefresh: Bool { autoRefresh && !isFetching && generatingID == nil && (nextRefresh ?? .distantFuture) <= Date() }
    func reload() {
        localReadEpoch += 1
        do { let db = try store.loadForManualReplies(); items = db.items; lastFetchedAt = db.lastFetchedAt }
        catch { self.error = "读取互动记录失败，未覆盖原文件：\(error.localizedDescription)" }
    }
    func reloadAsync() async {
        guard !loadingStore else { return }
        loadingStore = true; defer { loadingStore = false }
        let readEpoch = localReadEpoch
        let localStore = store
        do {
            let db = try await Task.detached { try localStore.loadForManualReplies() }.value
            // A polling read started before a local edit must not replace the editor's newer text.
            guard readEpoch == localReadEpoch else { return }
            items = db.items; lastFetchedAt = db.lastFetchedAt
        } catch { self.error = "读取互动记录失败，未覆盖原文件：\(error.localizedDescription)" }
    }
    func perform(_ action: () throws -> Void) {
        do { try action(); error = nil; reload() } catch { self.error = error.localizedDescription }
    }
    func importPost(url: String, text: String, category: String) -> Bool {
        do {
            let id = try InteractionRules.postID(from: url)
            let post = InteractionPost(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), category: category)
            let added = try store.collect([post]); reload(); selectedID = id
            message = added == 0 ? "已定位已有原帖，未创建重复记录" : "已加入互动箱；粘贴内容尚未经 X 核验"
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func saveText(_ id: String, text: String) { perform { try store.edit(id, text: text) } }
    func skip(_ item: InteractionItem) {
        perform { _ = try store.update(item.id) { value in
            guard value.editable else { throw InteractionError.invalid("请先核对已打开的回复") }
            value.state = value.state == .skipped ? (value.replyText.isEmpty ? .unread : .ready) : .skipped
        } }
    }
    func adopt(_ candidate: ReplyCandidate, for item: InteractionItem) { saveText(item.id, text: candidate.text) }
    func generate(_ item: InteractionItem) {
        guard !materialModelBusy && !originalModelBusy else { message = "正在写素材短帖，请稍后再写回复。"; return }
        guard generatingID == nil, item.editable, item.state != .skipped else { return }
        generatingID = item.id; error = nil
        let requestedTone = tone
        let shouldUseStyle = useStyleReference
        let localStore = store
        let recentReplies = items.sorted { $0.updatedAt > $1.updatedAt }.filter { $0.id != item.id }.map(\.replyText)
        generationTask = Task {
            defer { generatingID = nil; generationTask = nil }
            do {
                // Reading an optional local style file must not freeze the UI or prevent cancellation.
                let notes = shouldUseStyle ? try await Task.detached {
                    try localStore.loadReplyStyle().notes(category: item.post.category)
                }.value : []
                try Task.checkCancellation()
                styleReferenceMessage = !shouldUseStyle ? "本次不使用浏览风格参考" : notes.isEmpty ? "暂无适合此分类的浏览观察，使用默认写法" : "本次参考 \(notes.count) 条浏览观察，只学接话方式，不复制原句"
                let candidate = try await generator.generate(post: item.post, tone: requestedTone, currentReply: item.replyText, recentReplies: recentReplies, styleNotes: notes, recoveringEcho: item.isRecoverableEcho)
                try Task.checkCancellation()
                try store.addCandidate(item.id, candidate: candidate, sourceText: item.post.text, expectedEditRevision: item.editRevision ?? 0)
                reload()
                let saved = items.first { $0.id == item.id }
                message = item.replyText.isEmpty && saved?.replyText == candidate.text ? "已写好候选，请读一眼再去 X 回复。" : "新写法已放在下方候选，喜欢再点「采用这版」；当前文案未改动。"
            } catch {
                if Task.isCancelled { message = "已停止生成，已有编辑保留"; return }
                self.error = error.localizedDescription
                _ = try? store.update(item.id) { value in
                    if value.editable && value.state != .skipped && value.post.text == item.post.text &&
                        value.replyText == item.replyText && (value.editRevision ?? 0) == (item.editRevision ?? 0) {
                        value.note = error.localizedDescription
                        if value.replyText.isEmpty {
                            value.state = .needsContext
                            if case ReplyWritingError.echoRetryExhausted = error { value.preparationFailure = .echoRetryExhausted }
                            else { value.preparationFailure = .needsReview }
                        }
                    }
                }
                reload()
            }
        }
    }
    func stop() {
        stoppedDuringInitialLoad = true
        autoRefresh = false; nextRefresh = nil; autoAccountID = nil
        pendingReplyIDs.removeAll(); replyQueueCount = 0
        generationTask?.cancel(); discoveryGeneration?.cancel()
        replyBatchMessage = "已停止写回复，原帖和已写文案保留；可点「补写遗漏」继续。"
    }
    func startDiscovery() async {
        guard discoveryBridge == nil, !discoveryStarting, !RunConfiguration.isTest else { return }
        discoveryStarting = true; defer { discoveryStarting = false }
        do {
            let localStore = store
            let bridge = try await Task.detached { try DiscoveryBridge(store: localStore) }.value
            try bridge.start(); discoveryBridge = bridge
            // Old completed jobs must not restart generation after reopening the App.
            if let previous = try bridge.snapshot().job { handledDiscoveryJobs.insert(previous.id); discoveryJob = previous }
            discoveryMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.pollDiscovery()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } catch { self.error = "启动只读扩展连接失败：\(error.localizedDescription)" }
    }
    private func pollDiscovery() async {
        guard let bridge = discoveryBridge else { return }
        do {
            let snapshot = try await Task.detached { try bridge.snapshot() }.value
            extensionConnected = snapshot.connected; extensionPaired = snapshot.origin != nil; discoveryJob = snapshot.job
            discoveryMessage = snapshot.error ?? (snapshot.connected ? "Edge 扩展已连接" : snapshot.origin != nil ? "扩展已配对；获取时会唤醒 Edge" : "先连接一次 Edge 只读扩展")
            guard let job = snapshot.job, job.state == "complete", !handledDiscoveryJobs.contains(job.id) else { return }
            handledDiscoveryJobs.insert(job.id); await reloadAsync(); message = job.message
            if !job.isMaterials && job.autoDraft && autoDraft { generateDiscovered(job.addedIDs) }
        } catch { self.error = "读取选帖进度失败：\(error.localizedDescription)" }
    }
    func copyExtensionCode() {
        guard let bridge = discoveryBridge else { error = "本地连接尚未启动，请稍后重试"; return }
        do {
            let code = try bridge.connectionCode()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(code, forType: .string) else { throw InteractionError.invalid("复制失败，请重试") }
            discoveryMessage = "已复制 5 分钟有效的连接码；仅粘贴到此扩展，不要发到聊天或网页"
        } catch { self.error = error.localizedDescription }
    }
    func fetchNewPosts() async {
        guard preferencesLoaded else { error = "选帖设置尚未读取成功，请先检查本地数据；未发起采集。"; return }
        guard let bridge = discoveryBridge else { showExtension = true; return }
        do {
            let snapshot = try bridge.snapshot()
            guard let origin = snapshot.origin else { showExtension = true; return }
            guard snapshot.error == nil else { throw InteractionError.invalid(snapshot.error!) }
            discoveryJob = try bridge.enqueue(policy: discoveryPolicy, autoDraft: autoDraft)
            try await browserOpener(URL(string: origin + "/wake.html")!)
            message = "已请求只读采集，通常需 1–3 分钟；不发送回复。"
        } catch { self.error = error.localizedDescription }
    }
    func cancelDiscovery() { do { try discoveryBridge?.cancel() } catch { self.error = error.localizedDescription } }
    func fetchHotMaterials(_ preferences: HotMaterialPreferences) async throws {
        guard !RunConfiguration.isTest else { throw InteractionError.invalid("测试模式不读取真实 X 页面") }
        await startDiscovery()
        guard let bridge = discoveryBridge else { throw InteractionError.invalid("扩展连接未启动，请检查连接扩展") }
        let snapshot = try await Task.detached { try bridge.snapshot() }.value
        guard let origin = snapshot.origin else { showExtension = true; throw InteractionError.invalid("请先完成 Edge 只读扩展的一次配对") }
        guard snapshot.error == nil else { throw InteractionError.invalid(snapshot.error!) }
        discoveryJob = try await Task.detached { try bridge.enqueue(policy: preferences.discoveryPolicy, autoDraft: false, hotPreferences: preferences) }.value
        try await browserOpener(URL(string: origin + "/wake.html")!)
    }
    func shutdownDiscovery() { discoveryMonitor?.cancel(); stop(); discoveryBridge?.stop() }
    func generateDiscovered(_ ids: [String]) {
        // A new completed fetch appends instead of being dropped while the first batch is writing.
        guard discoveryGeneration?.isCancelled != true else {
            message = "本批原帖已保留；上一批正停止，可稍后逐条写回复。"; return
        }
        if discoveryGeneration == nil {
            replyBatchTotal = 0; replyBatchCompleted = 0; replyBatchNeedsContext = 0; replyBatchSkipped = 0
        }
        let existing = Set(pendingReplyIDs + [generatingID].compactMap { $0 })
        var queued = existing
        let backlog = ReplyDiscoveryRules.ordered(items.filter(\.needsReplyPreparation).map(\.post), policy: discoveryPolicy).map(\.id)
        for id in ids + backlog where queued.insert(id).inserted {
            guard let item = items.first(where: { $0.id == id }), item.needsReplyPreparation else { continue }
            pendingReplyIDs.append(id); replyBatchTotal += 1
        }
        replyQueueCount = pendingReplyIDs.count
        guard discoveryGeneration == nil else { return }
        guard !pendingReplyIDs.isEmpty else { return }
        discoveryGeneration = Task {
            defer { discoveryGeneration = nil; replyQueueCount = pendingReplyIDs.count }
            guard !Task.isCancelled else { return }
            while !pendingReplyIDs.isEmpty {
                while generatingID != nil || materialModelBusy || originalModelBusy { try? await Task.sleep(for: .milliseconds(300)); if Task.isCancelled { return } }
                guard !Task.isCancelled else { return }
                let id = pendingReplyIDs.removeFirst(); replyQueueCount = pendingReplyIDs.count
                reload()
                guard let item = items.first(where: { $0.id == id }), item.needsReplyPreparation else { replyBatchSkipped += 1; continue }
                selectedID = selectedID ?? id
                replyBatchMessage = "正在写第 \(replyBatchCompleted + replyBatchSkipped + 1)/\(replyBatchTotal) 条 · 后面还有 \(pendingReplyIDs.count) 条"
                generate(item)
                await generationTask?.value
                guard !Task.isCancelled else { return }
                replyBatchCompleted += 1
                if items.first(where: { $0.id == id })?.state == .needsContext { replyBatchNeedsContext += 1 }
            }
            replyBatchMessage = "本轮已检查 \(replyBatchCompleted) 条；\(replyBatchNeedsContext) 条需人工检查，\(replyBatchSkipped) 条已编辑或处理而跳过。未自动发布。"
        }
    }
    // The App may live on the Desktop; extension and data stay in their paired project.
    var extensionDirectory: URL { store.root.deletingLastPathComponent().appendingPathComponent("EdgeExtension") }
    func revealExtension() {
        guard FileManager.default.fileExists(atPath: extensionDirectory.appendingPathComponent("manifest.json").path) else {
            error = "未找到本地扩展文件夹，请保留原项目中的 EdgeExtension 目录。"; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([extensionDirectory])
    }
    func openExtensionManager() { Task { do { try await browserOpener(URL(string: "edge://extensions/")!) } catch { self.error = error.localizedDescription } } }
    func goReply(_ snapshot: InteractionItem) async {
        guard openingID == nil else { return }
        openingID = snapshot.id; defer { openingID = nil }
        error = nil; message = nil
        do {
            let url = try ManualReplyRules.intentURL(postID: snapshot.id, text: snapshot.replyText)
            _ = try store.markOpened(snapshot.id, expectedText: snapshot.replyText, expectedSource: snapshot.post.text)
            lastHandoffURL = url; reload()
            if RunConfiguration.isTest { message = "QA：已归入「已处理」；未打开浏览器、未改剪贴板、没有发送。"; return }
            try await browserOpener(url)
            message = "已归入「已处理」，并请求 Edge 打开预填回复。请在 X 核对后亲自点「回复」，无需回来登记。已处理不代表已发送；文案可在「已处理」中找回。"
        } catch {
            let handoffSaved = items.first { $0.id == snapshot.id }?.state == .opened
            self.error = error.localizedDescription + (handoffSaved ? " 此条已归入「已处理」，不代表已发送。可在那里查看文案；确认未发送后可移回待处理。" : "")
        }
    }
    static func openInEdge(_ url: URL) async throws {
        let edge = URL(fileURLWithPath: "/Applications/Microsoft Edge.app")
        guard FileManager.default.fileExists(atPath: edge.path) else { throw InteractionError.invalid("未找到 Microsoft Edge。可复制文案并手动打开原帖；App 不会代发。") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: edge, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if app != nil { continuation.resume() }
                else { continuation.resume(throwing: InteractionError.invalid("未能确认 Edge 已打开，请手动核对；不会自动重试。")) }
            }
        }
    }
    func copyReply(_ text: String) {
        if RunConfiguration.isTest { message = "QA：模拟复制，系统剪贴板未修改。"; return }
        NSPasteboard.general.clearContents()
        message = NSPasteboard.general.setString(text, forType: .string) ? "已复制文案，请自行在 X 核对后粘贴。" : "复制失败，可选中文字手动复制。"
    }
    func resolveNotSent(_ id: String) { perform { try store.resolveNotSent(id) } }
    func record(_ id: String, url: String, text: String) -> Bool {
        do { try store.recordManual(id, url: url, finalText: text); reload(); error = nil; message = "已保存人工确认记录（非 API 回执）"; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

extension AppModel {
    func refreshInteractions(automatic: Bool = false) async {
        let center = interactions
        guard !center.isFetching else { return }
        guard !RunConfiguration.isTest else { center.error = "QA 模式不读取真实 X 时间线，请用粘贴导入验收"; center.stop(); return }
        center.isFetching = true; defer { center.isFetching = false }
        do {
            let (access, account) = try await authorizedAccount()
            if automatic && center.autoAccountID != account.userID { throw InteractionError.invalid("X 账号发生变化，自动读取已暂停，请重新开启") }
            let posts = try await xClient.followingPosts(accountID: account.userID, accessToken: access)
            // A user pausing while a request is in flight may still receive its read-only result, but no generation follows.
            let count = try center.store.collect(posts, accountID: account.userID, fetchedAt: Date()); center.reload()
            center.error = nil; center.message = "读取最新一页（最多 25 条），新增 \(count) 条；不是「为你推荐」，不保证覆盖所有漏看的帖子"
            if center.autoRefresh { center.autoAccountID = account.userID; center.nextRefresh = Date().addingTimeInterval(15 * 60) }
            if center.autoDraft && (!automatic || center.autoRefresh) && !isBusy && center.generatingID == nil,
               let next = center.items.first(where: { $0.state == .unread && ["医学", "AI"].contains($0.post.category) && $0.post.sourceAccountID == account.userID }) {
                center.generate(next)
            }
        } catch { center.error = "读取暂停：\(error.localizedDescription)"; center.autoRefresh = false; center.nextRefresh = nil }
    }
}
