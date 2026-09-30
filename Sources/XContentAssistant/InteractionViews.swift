import AppKit
import SwiftUI
import XContentAssistantCore

struct InteractionsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: InteractionModel
    @State private var category = "全部"
    @State private var status: ReplyListFilter = .pending
    var visible: [InteractionItem] {
        let filtered = center.items.filter { item in
            let categoryOK = category == "全部" || (category == "医学 + AI" ? ["医学", "AI"].contains(item.post.category) : item.post.category == category)
            let statusOK = status.includes(item.state)
            return categoryOK && statusOK && (model.search.isEmpty || [item.post.text, item.post.username, item.replyText].joined(separator: " ").localizedCaseInsensitiveContains(model.search))
        }
        guard status == .pending || status == .readyToSend else { return filtered }
        let ordered = ReplyDiscoveryRules.ordered(filtered.map(\.post), policy: center.discoveryPolicy)
        let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        return ordered.compactMap { byID[$0.id] }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("先读懂，再接一句。").font(.title2.bold())
                        Text("在这里读原帖、修改文案；点一次「去 X 回复」，最后由你在 X 发送。").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await center.fetchNewPosts() } } label: { Label("获取新帖", systemImage: "sparkle.magnifyingglass") }
                        .buttonStyle(.borderedProminent).disabled(center.discoveryJob?.active == true)
                    Button("连接扩展") { center.showExtension = true }
                    Button { center.showImport = true } label: { Label("粘贴原帖", systemImage: "doc.on.clipboard") }
                    Button { Task { await center.reloadAsync() } } label: { Label("刷新本地列表", systemImage: "arrow.clockwise") }.disabled(center.loadingStore)
                        .help("仅重新读取已导入的本地记录，不获取 X 新帖")
                }
                HStack(spacing: 14) {
                    Label("手动发送 · 无 X API · 无后台代发", systemImage: "hand.tap").font(.callout)
                    Spacer()
                    Text("使用 Edge 当前登录账号，请在 X 核对").font(.caption).foregroundStyle(.secondary)
                }
                if center.loadingStore && center.items.isEmpty {
                    Label("正在读取本地互动记录；若 macOS 提示访问素材目录，请检查系统提示。", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
                }
                Text("点「去 X 回复」即移入「已处理」，无需回来登记。按钮只打开带文案的 X 页面，不会发送；无需保持 Codex 打开。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(center.discoveryMessage, systemImage: center.extensionConnected ? "link.circle.fill" : "link.circle").font(.caption)
                    Spacer()
                    Picker("来源", selection: $center.discoveryPolicy.source) {
                        Text("正在关注 · 不限话题").tag("following")
                        Text("关键词发现 · 医学/AI").tag("discover")
                    }.frame(width: 245).disabled(center.discoveryJob?.active == true || !center.preferencesLoaded)
                    Toggle("选帖后写回复", isOn: $center.autoDraft).toggleStyle(.checkbox).disabled(!center.preferencesLoaded)
                    Picker("每批最多", selection: $center.discoveryPolicy.limit) { Text("10 条").tag(10); Text("20 条").tag(20); Text("50 条").tag(50) }.frame(width: 150).disabled(!center.preferencesLoaded)
                }
                if let job = center.discoveryJob, !job.isMaterials {
                    DiscoveryJobSummary(job: job, items: center.items)
                    if job.active { Button("取消获取（保留已有回复）") { center.cancelDiscovery() }.controlSize(.small) }
                }
                HStack(spacing: 12) {
                    Button { center.prepareMissingReplies() } label: {
                        Label("补写遗漏（\(center.missingReplyCount)）", systemImage: "text.badge.plus")
                    }
                    .disabled(!center.preferencesLoaded || center.missingReplyCount == 0 || center.preparingReplies)
                    .help("补写未编辑的空回复；旧版复述失败只重写一次。不覆盖已有文案，不发送。")
                    Text("开启自动写回复后，启动 App 和获取新帖都会检查遗漏。").font(.caption).foregroundStyle(.secondary)
                }
                if let progress = center.replyBatchMessage { Text(progress).font(.caption).foregroundStyle(.secondary) }
                if let error = center.error {
                    HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).font(.callout).textSelection(.enabled); Spacer(); Button("关闭") { center.error = nil }.buttonStyle(.plain) }
                        .padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                } else if let message = center.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(20)
            Divider()
            HStack {
                Picker("分类", selection: $category) { ForEach(["全部", "医学 + AI"] + InteractionRules.categories, id: \.self) { Text($0) } }.frame(width: 170)
                Picker("状态", selection: $status) { ForEach(ReplyListFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 155)
                    .accessibilityIdentifier("reply-status-filter")
                Text("\(visible.count) 条").font(.caption).foregroundStyle(.secondary)
                Toggle("大号优先", isOn: $center.discoveryPolicy.prioritizeLargeAccounts).toggleStyle(.checkbox).disabled(!center.preferencesLoaded)
                Picker("粉丝门槛", selection: $center.discoveryPolicy.followerThreshold) {
                    Text("1 万").tag(10_000); Text("5 万").tag(50_000); Text("10 万").tag(100_000)
                }.frame(width: 130).disabled(!center.preferencesLoaded)
                Spacer()
                if center.generatingID != nil { ProgressView().controlSize(.small); Text("本机正在写回复…").font(.caption); Button("停止") { center.stop() }.controlSize(.small) }
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if status == .readyToSend {
                Text("已写好回复，发送前请检查文案。点「去 X 回复」后移入「已处理」，最后仍由你在 X 发送。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if visible.isEmpty {
                            VStack(spacing: 14) {
                                Image(systemName: "bubble.left.and.text.bubble.right").font(.largeTitle).foregroundStyle(.indigo)
                                Text(status == .readyToSend ? "还没有待发送的回复" : center.items.isEmpty ? "先收藏一条想聊的帖子" : "没有符合筛选的帖子").font(.headline)
                                Text(status == .readyToSend ? "点「补写遗漏」为已有原帖准备回复，或启用「选帖后写回复」再获取新帖；写好后会出现在这里。" : status == .pending ? "点「获取新帖」读取正在关注。去 X 回复过的条目在「已处理」里，不会再次加入。" : "可切换分类或状态，查找已收集的内容。").font(.callout).foregroundStyle(.secondary)
                                Button("获取新帖") { Task { await center.fetchNewPosts() } }.disabled(center.discoveryJob?.active == true)
                                Button("显示全部本地记录") { category = "全部"; status = .all; model.search = "" }
                                Button("粘贴原帖") { center.showImport = true }
                            }.padding(18)
                        }
                        ForEach(visible) { item in
                            Button { center.selectedID = item.id } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack { Text(item.post.category).font(.caption.bold()).foregroundStyle(item.post.category == "医学" ? .orange : .indigo); Spacer(); Text(item.state.label).font(.caption2).foregroundStyle(.secondary) }
                                    Text(item.post.text).font(.body).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(item.post.username == "作者未提供" ? item.post.origin : "@\(item.post.username)").font(.caption).foregroundStyle(.secondary)
                                    if item.post.discovery != nil {
                                        Text(ReplyDiscoveryRules.reason(item.post, policy: center.discoveryPolicy)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.padding(13).background(center.selectedID == item.id ? Color.indigo.opacity(0.1) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(center.selectedID == item.id ? .indigo.opacity(0.5) : .clear))
                            }.buttonStyle(.plain)
                        }
                    }.padding(12)
                }.frame(minWidth: 230, idealWidth: 285, maxWidth: 340)
                if let item = center.selected, visible.contains(where: { $0.id == item.id }) {
                    InteractionDetail(center: center, item: item).id(item.id).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("挑一条值得回复的内容", systemImage: "text.bubble", description: Text("原帖、依据、候选与编辑放在一起。\n引用原帖不等于事实已核实。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: visible.map(\.id), initial: true) { _, ids in center.selectVisible(ids) }
        .sheet(isPresented: $center.showImport) { InteractionImport(center: center) }
        .sheet(item: $center.recordItem) { item in InteractionReceipt(center: center, item: item) }
        .sheet(isPresented: $center.showExtension) { ExtensionConnectionSheet(center: center) }
        .task { await center.startDiscovery() }
    }
}

struct DiscoveryJobSummary: View {
    let job: DiscoveryJob
    let items: [InteractionItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if job.active { ProgressView().controlSize(.small) }
                Image(systemName: job.state == "complete" ? "checkmark.circle" : job.active ? "magnifyingglass" : "info.circle")
                Text(job.message).font(.caption).textSelection(.enabled)
            }
            if job.state == "complete" {
                DisclosureGroup("本次筛选详情 · 新增 \(job.addedIDs.count) 条 / 跳过 \(job.skipped.count) 条") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("来源：\(job.policy.source == "following" ? "正在关注 · 不限话题" : "关键词发现 · 医学/AI") · 最近 \(job.policy.maxAgeHours) 小时 · 每位作者最多 \(job.policy.maxPerAuthor) 条")
                        if let account = job.account { Text("读取账号：@\(account) · \(job.updatedAt.formatted())") }
                        let added = items.filter { job.addedIDs.contains($0.id) }
                        let largeCount = added.filter { ReplyDiscoveryRules.isLarge($0.post, policy: job.policy) }.count
                        let unknownCount = added.filter { $0.post.discovery?.followers == nil }.count
                        Text("新增中达到大号门槛 \(largeCount) 条；粉丝数未知 \(unknownCount) 条，不将蓝标或点赞数当成粉丝数。")
                        ForEach(ReplyDiscoverySkipSummary.grouped(job.skipped)) { group in
                            Text("\(group.count) 条：\(group.reason)")
                        }
                        Text("只检查本轮加载到的页面，不保证覆盖全部关注或凑满条数。被页面解析提前排除的广告、转帖或无正文内容不计入上述条数。")
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 5)
                }.font(.caption)
            }
        }
    }
}

struct InteractionDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: InteractionModel
    let item: InteractionItem
    var validation: (valid: Bool, weightedLength: Int, message: String) { XTextRules.validate(postText: item.replyText, sourceURL: nil, includeSourceURL: false) }
    var body: some View {
        VStack(spacing: 0) {
            // Stay near the list/editor, not at the far bottom-right of a long post.
            // This is the same manual handoff action; no new publication authority.
            if item.editable {
                HStack(spacing: 12) {
                    Button { Task { await center.goReply(item) } } label: {
                        Label("去 X 回复", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!validation.valid || item.state == .skipped || center.openingID != nil)
                    .accessibilityIdentifier("reply-handoff-pinned")
                    .help("使用当前编辑文案打开 Edge；最后仍由你在 X 点击回复")
                    Text("\(validation.weightedLength) / 280").font(.caption).monospacedDigit()
                        .foregroundStyle(validation.valid ? Color.secondary : .orange)
                    Spacer(minLength: 0)
                    Text("只打开网页，不会代发").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Panel(title: "原帖 · \(item.post.origin)") {
                    Text(item.post.text).textSelection(.enabled)
                    HStack {
                        Text(item.post.createdAt ?? "原帖日期未提供").font(.caption).foregroundStyle(.secondary)
                        Spacer(); Link("在 X 查看原帖 ↗", destination: item.post.url)
                    }
                    Text("这里只提供已收集的文字，引用不是事实核验。发送前请在 X 核对完整原帖、图片及上下文。").font(.caption).foregroundStyle(.secondary)
                    if let evidence = item.post.discovery {
                        Text(ReplyDiscoveryRules.reason(item.post, policy: center.discoveryPolicy)).font(.caption)
                        Text("数据观察时间：\(evidence.observedAt.formatted())；大号只是筛选偏好，不代表内容可信。").font(.caption).foregroundStyle(.secondary)
                        if let raw = evidence.followersSourceURL, let url = URL(string: raw) { Link("核对作者公开主页", destination: url) }
                    }
                }
                if let receipt = item.record {
                    Panel(title: receipt.kind == "browser_verified" ? "网页核验回执 · 非 API 回执" : receipt.kind == "simulated_browser_verified" ? "QA 模拟回执 · 没有真实发送" : "人工确认记录 · 非 API 回执") {
                        Text(receipt.finalText).textSelection(.enabled)
                        Link("查看已登记的回复 ↗", destination: URL(string: receipt.url)!)
                        Text("记录时间：\(receipt.recordedAt.formatted()) · 类型：\(receipt.kind)").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let job = item.dispatch, [.queued, .preparing, .clickCommitted, .uncertain].contains(job.state) {
                    Panel(title: "旧发送记录 · 请人工核对") {
                        Label("发送账号 @\(job.approval.account)", systemImage: "person.crop.circle")
                        Text(job.approval.text).textSelection(.enabled)
                        Text(job.reason).foregroundStyle(.secondary)
                        Label("新版不接续旧代发任务。结果不明确时保留锁定，不会自动重发。", systemImage: "lock.fill").font(.callout).foregroundStyle(.orange)
                        Button("已核对发出，登记链接") { center.recordItem = item }
                    }
                } else if item.state == .opened {
                    Panel(title: "已处理 · 已交接给你") {
                        Text(item.review?.text ?? item.replyText).textSelection(.enabled)
                        Text("点击「去 X 回复」后已从待处理列表移出，无需再登记。这里的「已处理」不代表已发送，最后仍由你在 X 点击回复。").foregroundStyle(.secondary)
                        Button("复制这条文案") { center.copyReply(item.review?.text ?? item.replyText) }
                        HStack { Button("确认未发送，移回待处理") { center.resolveNotSent(item.id) }; Button("登记已发链接（可选）") { center.recordItem = item } }
                        Text("需要继续编辑时，请先核对没有发送，再移回待处理，避免重复回复。").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Panel(title: "我的回复 · \(item.state.label)") {
                        HStack {
                            Picker("语气", selection: $center.tone) { ForEach(ReplyWritingRules.tones, id: \.self) { Text($0) } }.labelsHidden().disabled(!center.preferencesLoaded)
                            Button(item.replyText.isEmpty ? "帮我接一句" : "换个说法") { center.generate(item) }
                                .disabled(center.generatingID != nil || model.isBusy || item.state == .skipped)
                        }
                        Text("默认只接一个具体点，不强行总结或提问；重写只存候选，不覆盖你改过的字。").font(.caption).foregroundStyle(.secondary)
                        Toggle("参考浏览中学到的接话方式", isOn: $center.useStyleReference).toggleStyle(.checkbox).disabled(!center.preferencesLoaded)
                        if !center.styleReferenceMessage.isEmpty { Text(center.styleReferenceMessage).font(.caption).foregroundStyle(.secondary) }
                        TextEditor(text: Binding(get: { center.items.first(where: { $0.id == item.id })?.replyText ?? item.replyText }, set: { center.saveText(item.id, text: $0) }))
                            .font(.body).frame(minHeight: 140).scrollContentBackground(.hidden).padding(8)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).disabled(!item.editable)
                            .accessibilityLabel("回复文案")
                        HStack {
                            Text("\(validation.weightedLength) / 280 · 本地实时保存").font(.caption).foregroundStyle(validation.valid ? Color.secondary : .orange)
                            Spacer(); Button(item.state == .skipped ? "恢复待处理" : "跳过") { center.skip(item) }
                        }
                        Text("点击即归入「已处理」并打开 Edge 预填回复框，不会代你发送。真正公开发布由你在 X 点击回复。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let job = item.dispatch, [.blocked, .cancelled].contains(job.state) {
                    Label("旧代发流程已停止，文案已保留。现在请用「去 X 回复」手动发送。", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                if !item.note.isEmpty { Label(item.note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !item.candidates.isEmpty {
                    Panel(title: "候选与原文依据（不是事实认证）") {
                        ForEach(item.candidates.reversed()) { candidate in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(candidate.text).textSelection(.enabled)
                                Text("原帖摘录：\(candidate.quote)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                HStack { Text(candidate.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary); Spacer(); Button("采用这版") { center.adopt(candidate, for: item) }.disabled(!item.editable) }
                            }.padding(12).background(.indigo.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }.padding(20)
        }
        }
    }
}

struct InteractionImport: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var center: InteractionModel
    @State var url = ""
    @State var text = ""
    @State var category = "其他"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("收藏一条想回复的帖子").font(.title2.bold())
            Text("在 X 复制原帖链接和正文。图片里的关键文字也请补充进来；链接不会被自动抓取。").foregroundStyle(.secondary)
            TextField("https://x.com/作者/status/…", text: $url).textFieldStyle(.roundedBorder).accessibilityLabel("原帖链接")
            Picker("分类", selection: $category) { ForEach(InteractionRules.categories, id: \.self) { Text($0) } }
            TextEditor(text: $text).frame(height: 190).border(.quaternary).accessibilityLabel("原帖正文")
            Text("\(text.count) / 12000 字 · 请粘贴正文，不只是网址").font(.caption).foregroundStyle(.secondary)
            if let error = center.error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("加入互动箱") { if center.importPost(url: url, text: text, category: category) { dismiss() } }.buttonStyle(.borderedProminent).disabled(url.isEmpty || text.count < 8 || text.count > 12000) }
        }.padding(26).frame(width: 530)
    }
}

struct InteractionReceipt: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var center: InteractionModel
    let item: InteractionItem
    @State var url = ""
    @State var text = ""
    @State var checked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("登记已经发出的回复").font(.title2.bold())
            Text("填你自己的回复链接，不是原帖链接。如果在 X 改过文字，也请同步修改下面的记录。").foregroundStyle(.secondary)
            TextField("你发出的回复链接", text: $url).textFieldStyle(.roundedBorder).accessibilityLabel("已发回复链接")
            TextEditor(text: $text).frame(height: 150).border(.quaternary).accessibilityLabel("实际发送文字")
            Toggle("我已在 X 确认发送成功", isOn: $checked)
            Text("记录类型：人工确认。不会伪装成 API 成功回执。").font(.caption).foregroundStyle(.secondary)
            if let error = center.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存记录") { if center.record(item.id, url: url, text: text) { dismiss() } }.buttonStyle(.borderedProminent).disabled(!checked || url.isEmpty || text.isEmpty) }
        }.padding(26).frame(width: 530).onAppear { text = item.review?.text ?? item.replyText }
    }
}
