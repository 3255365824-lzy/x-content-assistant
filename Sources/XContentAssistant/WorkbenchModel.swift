import AppKit
import AuthenticationServices
import Combine
import Foundation
import XContentAssistantCore

@MainActor final class DraftEditor: ObservableObject {
    @Published var draft: DraftManifest
    @Published var text: String
    @Published var sourceURL: String
    @Published var includeURL: Bool
    @Published var card: CardConfig
    @Published var saveState = "已保存"
    @Published var dirty = false
    private var saving = false
    private var debounce: Task<Void, Never>?
    let runtime: LocalRuntimeClient
    init(_ draft: DraftManifest, runtime: LocalRuntimeClient) {
        self.draft = draft; self.runtime = runtime; text = draft.postText; sourceURL = draft.sourceURL ?? ""; includeURL = draft.includeSourceURL
        card = draft.card ?? CardConfig(hook: draft.postText.components(separatedBy: .newlines).first ?? "", fact: draft.evidence)
    }
    var editable: Bool { draft.status == .queued || draft.status == .failed }
    var finalText: String { XTextRules.composedText(postText: text, sourceURL: sourceURL, includeSourceURL: includeURL) }
    var validation: (valid: Bool, weightedLength: Int, message: String) { XTextRules.validate(postText: text, sourceURL: sourceURL, includeSourceURL: includeURL) }
    func changed() {
        guard editable else { return }; dirty = true; saveState = "等待保存…"; debounce?.cancel()
        debounce = Task { try? await Task.sleep(for: .milliseconds(700)); guard !Task.isCancelled else { return }; _ = await flush() }
    }
    @discardableResult func flush() async -> Bool {
        while saving { if Task.isCancelled { return false }; try? await Task.sleep(for: .milliseconds(50)) }
        guard dirty else { return true }; saving = true; defer { saving = false }
        while dirty {
            dirty = false; saveState = "保存中…"
            do {
                let body = try JSONSerialization.data(withJSONObject: ["expectedRevision": draft.revision, "postText": text,
                    "sourceURL": sourceURL.isEmpty ? NSNull() : sourceURL as Any, "includeSourceURL": includeURL,
                    "card": try JSONSerialization.jsonObject(with: JSONEncoder().encode(card))])
                draft = try await runtime.call("api/v1/drafts/\(draft.id)/update", method: "PATCH", body: body, as: DraftManifest.self)
                saveState = "已保存"
            } catch { dirty = true; saveState = "保存失败：\(error.localizedDescription)"; return false }
        }
        return true
    }
    func accept(_ value: DraftManifest) {
        guard !dirty && !saving else { return }; draft = value; text = value.postText; sourceURL = value.sourceURL ?? ""; includeURL = value.includeSourceURL; card = value.card ?? card
    }
}

@MainActor final class AppModel: NSObject, ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case dashboard = "今天", inbox = "素材箱", queue = "创作台", interactions = "刷推互动", schedule = "内容日历", history = "历史记录", settings = "设置"
        var id: String { rawValue }
        var icon: String {
            switch self { case .dashboard: "sun.max"; case .inbox: "tray.full"; case .queue: "square.and.pencil"; case .interactions: "bubble.left.and.bubble.right"; case .schedule: "calendar"; case .history: "clock.arrow.circlepath"; case .settings: "gearshape" }
        }
    }
    @Published var section: Section = .dashboard
    @Published var health = RuntimeHealth()
    @Published var drafts: [DraftManifest] = []
    @Published var materials: [MaterialItem] = []
    @Published var jobs: [GenerationJob] = []
    @Published var schedule = ScheduleConfig()
    @Published var clientID = ""
    @Published var xAccount: XAccount?
    @Published var isConnected = false
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published var selectedDraftID: String?
    @Published var selectedMaterialID: String?
    @Published var previewURL: URL?
    @Published var showGenerate = false
    @Published var generateMaterialID: String?
    @Published var pendingPublish: PublicationSnapshot?
    @Published var publishingIDs: Set<String> = []
    @Published var dueDraftID: String?
    @Published var preparingPublish = false
    @Published var search = ""
    @Published var searchPresented = false
    @Published var showHotDrafts = false
    @Published var showOriginalDrafts = false
    let runtime: LocalRuntimeClient
    let xClient: XAPIClient
    let keychain: any TokenStore
    let interactions: InteractionModel
    let hotMaterials: HotMaterialModel
    let originalIdeas: OriginalIdeaModel
    private let preferences: UserDefaults
    private var editors: [String: DraftEditor] = [:]
    private var timer: Timer?
    private var authSession: ASWebAuthenticationSession?
    private var lastRunSlot: String?
    private var seenDue: Set<String> = []
    private let openedAt = Date()
    private var refreshing = false
    var isBusy: Bool { jobs.contains(where: \.isActive) }
    var queue: [DraftManifest] { drafts.filter { $0.status != .published && !$0.archived }.sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order } }
    var nextRunText: String { ScheduleRules.nextRun(after: Date(), config: schedule)?.formatted(date: .omitted, time: .shortened) ?? "未启用" }
    init(runtime: LocalRuntimeClient = LocalRuntimeClient(), xClient: XAPIClient = XAPIClient(), keychain: any TokenStore = KeychainStore(), autoStart: Bool = true, testPreferences: UserDefaults? = nil) {
        self.runtime = runtime; self.xClient = xClient; self.keychain = keychain
        interactions = InteractionModel(root: RunConfiguration.value("XCONTENT_INTERACTIONS_ROOT").map { URL(fileURLWithPath: $0) } ?? runtime.runtimeRoot.appendingPathComponent("content-library/.state/interactions"))
        hotMaterials = HotMaterialModel(interaction: interactions)
        originalIdeas = OriginalIdeaModel(interaction: interactions, hot: hotMaterials)
        // The QA bundle has its own bundle identifier and therefore its own standard domain.
        // A named suite can return nil (including when it equals the app domain).
        preferences = testPreferences ?? .standard
        super.init(); clientID = preferences.string(forKey: "x.clientID") ?? ""
        if let data = preferences.data(forKey: "schedule"), let saved = try? JSONDecoder().decode(ScheduleConfig.self, from: data) { schedule = saved }
        schedule.maxPerRun = 1
        if RunConfiguration.isTest { schedule.enabled = false }
        lastRunSlot = preferences.string(forKey: "lastRunSlot"); isConnected = !RunConfiguration.isTest && keychain.load(key: "accessToken") != nil
        guard autoStart else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in await self?.tick() } }
        Task { await refresh() }
    }
    func stopScheduler() { timer?.invalidate(); timer = nil; originalIdeas.shutdown(); hotMaterials.shutdown(); interactions.stop(); interactions.shutdownDiscovery() }
    func editor(_ draft: DraftManifest) -> DraftEditor {
        if let existing = editors[draft.id] { return existing }; let value = DraftEditor(draft, runtime: runtime); editors[draft.id] = value; return value
    }
    func flushAll() async -> Bool {
        guard await originalIdeas.flush() else { return false }
        guard await hotMaterials.flush() else { return false }
        for editor in editors.values where editor.dirty { if !(await editor.flush()) { return false } }; return true
    }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }; health = await runtime.health()
        do {
            try await recoverReceipts(); try await runtime.reconcilePublishing(); drafts = try await runtime.listDrafts(); materials = try await runtime.listMaterials()
            jobs = try await runtime.call("api/v1/generation-jobs", as: [GenerationJob].self)
            for draft in drafts { editors[draft.id]?.accept(draft) }
        } catch { if health.draftEngine { errorMessage = error.localizedDescription } }
    }
    func showDraft(_ id: String) { selectedDraftID = id; section = drafts.first(where: { $0.id == id })?.status == .published ? .history : .queue }
    func replace(_ value: DraftManifest) {
        if let i = drafts.firstIndex(where: { $0.id == value.id }) { drafts[i] = value } else { drafts.insert(value, at: 0) }; editors[value.id]?.accept(value)
    }
    func tick() async {
        await hotMaterials.tick(otherModelBusy: isBusy)
        await interactions.reloadAsync()
        if isBusy { await refresh() }
        if let slot = ScheduleRules.slotKey(for: Date(), config: schedule), slot != lastRunSlot {
            lastRunSlot = slot; preferences.set(slot, forKey: "lastRunSlot"); if !isBusy { await generate(style: schedule.style) }
        }
        for draft in queue {
            if let due = draft.plannedAt, due >= openedAt, due <= Date(), dueDraftID == nil {
                let reminderKey = "\(draft.id):\(due.timeIntervalSince1970)"
                if !seenDue.contains(reminderKey) { seenDue.insert(reminderKey); dueDraftID = draft.id }
            }
        }
        if interactions.shouldRefresh && !isBusy { await refreshInteractions(automatic: true) }
    }
    func savePreferences() {
        preferences.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "x.clientID"); schedule.times = ScheduleRules.normalizedTimes(schedule.times); schedule.maxPerRun = 1
        preferences.set(try? JSONEncoder().encode(schedule), forKey: "schedule")
    }
    func startRuntime() { do { try runtime.openRuntimeScript("start.sh"); notice = "正在启动本地服务，请稍后刷新" } catch { errorMessage = error.localizedDescription } }
    func stopRuntime() { do { try runtime.openRuntimeScript("stop.sh"); notice = "已请求停止专用服务，OrbStack 和 Ollama 保持运行" } catch { errorMessage = error.localizedDescription } }
    func openN8N() { NSWorkspace.shared.open(runtime.n8nBaseURL) }
    func generateNow() async { await generate(style: schedule.style) }
    func generate(style: String, materialID: String? = nil, draftID: String? = nil, action: String? = nil) async {
        guard !originalIdeas.generating else { notice = "自拟灵感正在写作，请完成后再生成图文稿"; return }
        guard hotMaterials.generatingID == nil else { notice = "热门素材正在加工，请完成后再生成图文稿"; return }
        guard interactions.generatingID == nil else { notice = "回复正在生成，请完成后再生成素材稿"; return }
        if let draftID, let editor = editors[draftID], !(await editor.flush()) { errorMessage = editor.saveState; return }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["async": true, "requestID": UUID().uuidString, "style": style, "materialID": materialID as Any? ?? NSNull(), "draftID": draftID as Any? ?? NSNull(), "action": action as Any? ?? NSNull(), "maxPerRun": 1])
            let job = try await runtime.submitJob(body: body); jobs.insert(job, at: 0); notice = "已加入生成队列，完成后会出现在创作台"
        } catch { errorMessage = error.localizedDescription }
    }
    func chooseFiles(_ category: DraftCategory) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importFiles(panel.urls, category: category) }
    }
    func importFiles(_ urls: [URL], category: DraftCategory) {
        do {
            var target: URL?; for url in urls { target = try runtime.importMaterial(file: url, category: category) }
            notice = "素材已收好；相同文件会定位已有素材，不重复复制"
            Task { await refresh(); section = .inbox; if let target { selectedMaterialID = materials.first(where: { (try? runtime.localMaterialFile($0)) == target })?.id } }
        } catch { errorMessage = error.localizedDescription }
    }
    func patchMaterial(_ item: MaterialItem, values: [String: Any]) async {
        do {
            let body = try JSONSerialization.data(withJSONObject: values)
            let updated = try await runtime.call("api/v1/materials/\(item.id)", method: "PATCH", body: body, as: MaterialItem.self)
            if let index = materials.firstIndex(where: { $0.id == item.id }) { materials[index] = updated }; notice = "素材信息已保存"
        } catch { errorMessage = error.localizedDescription }
    }
    func patchDraft(_ draft: DraftManifest, values: [String: Any]) async {
        if let editor = editors[draft.id], !(await editor.flush()) { errorMessage = editor.saveState; return }
        do { let body = try JSONSerialization.data(withJSONObject: values); replace(try await runtime.call("api/v1/drafts/\(draft.id)/update", method: "PATCH", body: body, as: DraftManifest.self)) }
        catch { errorMessage = error.localizedDescription }
    }
    func action(_ draft: DraftManifest, name: String, values: [String: Any] = [:]) async {
        do { let body = try JSONSerialization.data(withJSONObject: values); replace(try await runtime.call("api/v1/drafts/\(draft.id)/\(name)", method: "POST", body: body, as: DraftManifest.self)) }
        catch { errorMessage = error.localizedDescription }
    }
    func moveDraft(_ source: String, before target: String) async {
        var ids = queue.map(\.id); guard let origin = ids.firstIndex(of: source), source != target else { return }; ids.remove(at: origin)
        if let destination = ids.firstIndex(of: target) { ids.insert(source, at: destination) }
        for (index, id) in ids.enumerated() { if let draft = drafts.first(where: { $0.id == id }), draft.status == .queued || draft.status == .failed { await patchDraft(draft, values: ["order": index]) } }
    }
    func preview(_ material: MaterialItem) { previewURL = try? runtime.localMaterialFile(material) }
    func reveal(_ material: MaterialItem) { if let url = try? runtime.localMaterialFile(material) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func copyText(_ editor: DraftEditor) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(editor.finalText, forType: .string); notice = "已复制最终文案" }
    func copyImage(_ editor: DraftEditor) async {
        guard await editor.flush() else { errorMessage = editor.saveState; return }
        let draft = editor.draft
        if let asset = draft.media.first, let image = NSImage(contentsOf: runtime.localFile(for: draft, asset: asset)) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]); notice = "已复制配图" }
    }
    func export(_ editor: DraftEditor) async {
        guard await editor.flush() else { errorMessage = editor.saveState; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "导出到此处"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        do {
            let folder = root.appendingPathComponent("X图文-\(editor.draft.id)-\(UUID().uuidString.prefix(5))"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try editor.finalText.write(to: folder.appendingPathComponent("文案.txt"), atomically: true, encoding: .utf8)
            let notes = "# 来源与依据\n\n\(editor.draft.sourceTitle ?? "本地素材")\n\(editor.draft.sourceDate ?? "来源日期未提供")\n\(editor.sourceURL)\n\n\(editor.draft.evidence)\n\n导出不是发布，请自行核对后上传配图。"
            try notes.write(to: folder.appendingPathComponent("来源.md"), atomically: true, encoding: .utf8)
            if let asset = editor.draft.media.first { try FileManager.default.copyItem(at: runtime.localFile(for: editor.draft, asset: asset), to: folder.appendingPathComponent(asset.relativePath)) }
            NSWorkspace.shared.activateFileViewerSelecting([folder]); notice = "已导出图文包，草稿仍未发布"
        } catch { errorMessage = error.localizedDescription }
    }
    func storeToken(_ token: XTokenResponse) throws {
        try keychain.save(token.accessToken, key: "accessToken"); if let refresh = token.refreshToken { try keychain.save(refresh, key: "refreshToken") }
        try keychain.save(String(Date().addingTimeInterval(Double(token.expiresIn ?? 7200)).timeIntervalSince1970), key: "expiresAt"); isConnected = true
    }
    func authorizedAccount() async throws -> (String, XAccount) {
        var access = keychain.load(key: "accessToken"); let expiry = Double(keychain.load(key: "expiresAt") ?? "0") ?? 0
        if access == nil || expiry < Date().timeIntervalSince1970 + 60 {
            guard let refresh = keychain.load(key: "refreshToken"), !clientID.isEmpty else { throw XClientError.authenticationRequired }
            let token = try await xClient.refresh(clientID: clientID, refreshToken: refresh); try storeToken(token); access = token.accessToken
        }
        guard let access else { throw XClientError.authenticationRequired }
        do { let account = try await xClient.currentUser(accessToken: access); xAccount = account; return (access, account) } catch { xAccount = nil; throw error }
    }
    func preparePublish(_ editor: DraftEditor) async {
        guard !preparingPublish, !publishingIDs.contains(editor.draft.id) else { return }; preparingPublish = true; defer { preparingPublish = false }
        guard await editor.flush() else { errorMessage = editor.saveState; return }; guard editor.validation.valid else { errorMessage = editor.validation.message; return }
        do {
            let account: XAccount
            if RunConfiguration.isTest { account = XAccount(username: "local_preview_QA_no_post", userID: "qa-local-only") }
            else { (_, account) = try await authorizedAccount() }
            let image = try editor.draft.media.first.map { try Data(contentsOf: runtime.localFile(for: editor.draft, asset: $0)) }
            pendingPublish = PublicationSnapshot(draft: editor.draft, account: account, imageData: image)
        } catch { errorMessage = error.localizedDescription }
    }
    func publish(_ snapshot: PublicationSnapshot) async {
        let draft = snapshot.draft
        guard !publishingIDs.contains(draft.id), !RunConfiguration.isTest else { return }
        publishingIDs.insert(draft.id); pendingPublish = nil; defer { publishingIDs.remove(draft.id) }; var began = false, submitted = false
        do {
            let (access, current) = try await authorizedAccount()
            guard current.userID == snapshot.account.userID else { throw RuntimeClientError.http(status: 409, message: "账号已变化，请重新检查确认页") }
            let body = try JSONSerialization.data(withJSONObject: ["expectedRevision": draft.revision, "accountID": current.userID, "imageHash": snapshot.imageHash as Any? ?? NSNull()])
            replace(try await runtime.call("api/v1/drafts/\(draft.id)/begin-publishing", method: "POST", body: body, as: DraftManifest.self)); began = true
            var mediaID: String?; if let data = snapshot.imageData { mediaID = try await xClient.uploadPNG(data, accessToken: access) }; submitted = true
            let result = try await xClient.createPost(text: snapshot.finalText, mediaID: mediaID, madeWithAI: draft.media.first?.madeWithAI ?? false, accessToken: access)
            var mark = PublishMark(postID: result.id, postURL: "https://x.com/i/web/status/\(result.id)", finalTextHash: TextHasher.sha256(snapshot.finalText), includedSourceURL: draft.includeSourceURL, mediaID: mediaID); mark.finalText = snapshot.finalText
            try runtime.journalReceipt(id: draft.id, mark: mark)
            replace(try await runtime.markPublished(id: draft.id, mark: mark)); try runtime.acknowledgeReceipt(id: draft.id); notice = "已发布，回执已保存"
        } catch {
            if began { let uncertain: Bool; if case XClientError.http = error { uncertain = false } else { uncertain = submitted }; await action(draft, name: uncertain ? "needs-confirmation" : "failed", values: ["message": error.localizedDescription]) }
            errorMessage = error.localizedDescription
        }
    }
    func recoverReceipts() async throws {
        for (id, data) in try runtime.pendingReceipts() { let _: DraftManifest = try await runtime.call("api/v1/drafts/\(id)/mark-published", method: "POST", body: data, as: DraftManifest.self); try runtime.acknowledgeReceipt(id: id) }
    }
    func connectX() {
        guard !RunConfiguration.isTest else { errorMessage = "隔离验收模式禁用真实 X 授权和发布"; return }
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty else { errorMessage = "请先填写 Client ID"; return }; savePreferences(); let pair = PKCEPair.make(); let redirect = "xcontentassistant://oauth/callback"
        do {
            let url = try xClient.authorizationURL(clientID: clientID, redirectURI: redirect, pkce: pair)
            authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "xcontentassistant") { [weak self] callback, error in
                Task { @MainActor in
                    guard let self else { return }; self.authSession = nil
                    guard error == nil, let callback, let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), parts.queryItems?.first(where: { $0.name == "state" })?.value == pair.state, let code = parts.queryItems?.first(where: { $0.name == "code" })?.value else { self.errorMessage = "授权取消或回调无效"; return }
                    do { self.xAccount = nil; let token = try await self.xClient.exchangeCode(clientID: self.clientID, code: code, redirectURI: redirect, verifier: pair.verifier); try self.storeToken(token); _ = try await self.authorizedAccount(); self.notice = "X 账号已连接" } catch { self.errorMessage = error.localizedDescription }
                }
            }
            authSession?.presentationContextProvider = self; authSession?.start()
        } catch { errorMessage = error.localizedDescription }
    }
    func disconnectX() { interactions.stop(); for key in ["accessToken", "refreshToken", "expiresAt"] { keychain.delete(key: key) }; isConnected = false; xAccount = nil }
}

extension AppModel: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if Thread.isMainThread { return MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() } }
        return DispatchQueue.main.sync { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    }
}
