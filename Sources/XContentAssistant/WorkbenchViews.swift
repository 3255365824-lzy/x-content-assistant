import AppKit
import SwiftUI
import QuickLook
import XContentAssistantCore

extension DraftCategory { var tint: Color { self == .medical ? .orange : .indigo } }
extension DraftStatus {
    var label: String { switch self { case .queued: "待发"; case .publishing: "发布中"; case .published: "已发"; case .needsConfirmation: "需核对"; case .failed: "失败" } }
    var symbol: String { switch self { case .queued: "circle.dotted"; case .publishing: "arrow.up.circle"; case .published: "checkmark.circle"; case .needsConfirmation: "exclamationmark.triangle"; case .failed: "xmark.circle" } }
}
struct Panel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { Text(title).font(.headline); content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.05)))
    }
}
struct CategoryBadge: View {
    let category: DraftCategory
    var selected = false
    var body: some View { Text(category.rawValue).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4).background((selected ? Color.white : category.tint).opacity(0.12), in: Capsule()).foregroundStyle(selected ? Color.white : category.tint) }
}
struct ImportMenu: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Menu { Button("医学素材…") { model.chooseFiles(.medical) }; Button("AI 素材…") { model.chooseFiles(.ai) } }
        label: { Label("导入素材", systemImage: "plus") }
    }
}
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").font(.title2).foregroundStyle(.white).frame(width: 38, height: 38).background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading) { Text("X 素材助手").font(.headline); Text("LOCAL STUDIO · 0.3.9").font(.system(size: 9, weight: .medium)).tracking(1.3).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(18)
                List(selection: $model.section) {
                    ForEach(AppModel.Section.allCases.filter { $0 != .settings }) { item in
                        Label(item.rawValue, systemImage: item.icon).padding(.vertical, 5).tag(item)
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.health.allReady ? "本地服务就绪" : "服务需要检查", systemImage: model.health.allReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(model.health.allReady ? .green : .orange)
                    Button { model.section = .settings } label: { Label("设置与连接", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                }.padding(18)
            }.navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 230)
        } detail: {
            Group {
                switch model.section {
                case .dashboard: TodayView()
                case .inbox: MaterialsHubView()
                case .queue: CreationHubView()
                case .interactions: InteractionsView(center: model.interactions)
                case .history: StudioView(history: true)
                case .schedule: CalendarView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(model.section.rawValue)
            .toolbar {
                ToolbarItemGroup { ImportMenu(); Button { model.generateMaterialID = nil; model.showGenerate = true } label: { Label("立即生成", systemImage: "sparkles") }; Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") } }
            }
            .searchable(text: $model.search, isPresented: $model.searchPresented, prompt: "搜索素材、草稿、回复")
        }
        .tint(.indigo)
        .quickLookPreview($model.previewURL)
        .sheet(isPresented: $model.showGenerate) { GenerationSheet() }
        .sheet(item: $model.pendingPublish) { PublishConfirmation(snapshot: $0) }
        .alert("需要处理", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("知道了") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .alert("到了计划发帖时间", isPresented: Binding(get: { model.dueDraftID != nil }, set: { if !$0 { model.dueDraftID = nil } })) {
            Button("查看草稿") { if let id = model.dueDraftID { model.showDraft(id) }; model.dueDraftID = nil }
            Button("稍后", role: .cancel) { model.dueDraftID = nil }
        } message: { Text("这是提醒，不会自动发布。请核对文字、配图和账号。") }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                HStack { Image(systemName: "checkmark.circle"); Text(notice); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    .font(.callout).padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.1), radius: 12).padding(20)
                    .task(id: notice) { try? await Task.sleep(for: .seconds(5)); if model.notice == notice { model.notice = nil } }
            }
        }
        .onChange(of: model.section) { _, _ in model.search = ""; Task { _ = await model.flushAll() } }
    }
}

struct TodayView: View {
    @EnvironmentObject var model: AppModel
    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(Date.now.formatted(.dateTime.month().day().weekday())).font(.subheadline).foregroundStyle(.secondary)
                        Text("把有意思的，慢慢发出去。").font(.system(size: 29, weight: .bold))
                        Text("收藏素材，写点轻知识。每一条，由你最后决定。").foregroundStyle(.secondary)
                    }; Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        Button { model.showGenerate = true } label: { Label("立即生成", systemImage: "sparkles") }.buttonStyle(.borderedProminent).controlSize(.large)
                        ImportMenu().controlSize(.large)
                    }
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    metric("新素材", "\(model.materials.filter { $0.status == .new && $0.archived != true }.count)", "tray", .inbox)
                    metric("待发草稿", "\(model.queue.count)", "square.and.pencil", .queue)
                    metric("需要核对", "\(model.drafts.filter { $0.status == .needsConfirmation || $0.status == .failed }.count)", "exclamationmark.triangle", .queue)
                    metric("下次生成", model.nextRunText, "clock", .schedule)
                }
                if !model.health.allReady {
                    Panel(title: "先把本地服务准备好") {
                        Text("素材和草稿只留在这台 Mac。启动后即可生成，不需要云端模型密钥。").foregroundStyle(.secondary)
                        HStack { Button("启动本地服务") { model.startRuntime() }.buttonStyle(.borderedProminent); Button("查看诊断") { model.section = .settings } }
                    }
                }
                if !model.jobs.isEmpty { JobPanel() }
                HStack { Text("最近的灵感").font(.title2.bold()); Spacer(); Button("全部草稿 →") { model.section = .queue }.buttonStyle(.plain).foregroundStyle(.indigo) }
                if model.queue.isEmpty {
                    ContentUnavailableView("从一份素材开始", systemImage: "tray.and.arrow.down", description: Text("把图片或文档拖进素材箱，挑一份生成第一条草稿。"))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .top)], spacing: 18) {
                        ForEach(Array(model.queue.prefix(6))) { draft in
                            Button { model.showDraft(draft.id) } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    AssetView(draft: draft).frame(height: 185).frame(maxWidth: .infinity).background(draft.category.tint.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 10))
                                    HStack { CategoryBadge(category: draft.category); Spacer(); Label(draft.status.label, systemImage: draft.status.symbol).font(.caption).foregroundStyle(.secondary) }
                                    Text(draft.postText).font(.body.weight(.medium)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(15).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(30)
        }
    }
    func metric(_ title: String, _ value: String, _ icon: String, _ section: AppModel.Section) -> some View {
        Button { model.section = section } label: { Panel(title: title) { HStack { Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)); Spacer(); Image(systemName: icon).font(.title2).foregroundStyle(.indigo.opacity(0.7)) } } }.buttonStyle(.plain)
    }
}
struct JobPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Panel(title: "生成任务") {
            ForEach(Array(model.jobs.prefix(3))) { job in
                HStack(alignment: .top, spacing: 12) {
                    if job.isActive { ProgressView().controlSize(.small) } else { Image(systemName: job.status == "completed" ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(job.status == "completed" ? .green : .orange) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(job.stage).font(.callout.weight(.medium)); Text(job.error ?? job.result?.message ?? "排队 → 提取 → 生成 → 校验 → 配图").font(.caption).foregroundStyle(.secondary)
                    }; Spacer()
                    if let id = job.result?.drafts.first?.id { Button("查看") { model.showDraft(id) } }
                }
            }
        }
    }
}
struct GenerationSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var style = "bold_opinion"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("写一条新内容", systemImage: "sparkles").font(.title2.bold())
            Text("依据本地素材生成，不足以核对时会停下来请你补充。").foregroundStyle(.secondary)
            Picker("素材", selection: $model.generateMaterialID) {
                Text("自动选择一份新素材").tag(nil as String?)
                ForEach(model.materials.filter { $0.archived != true }) { item in Text(URL(fileURLWithPath: item.relativePath).lastPathComponent).tag(item.id as String?) }
            }
            Picker("表达风格", selection: $style) { Text("观点 / 反常识").tag("bold_opinion"); Text("轻科普 / 小常识").tag("knowledge") }.pickerStyle(.segmented)
            Text("每次生成一条 · qwen3:8b · 仅本机运行").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("开始生成") { let id = model.generateMaterialID; dismiss(); Task { await model.generate(style: style, materialID: id) } }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 490)
    }
}

struct MaterialsView: View {
    @EnvironmentObject var model: AppModel
    @State var category = "全部"
    @State var status = "全部"
    @State var favoriteOnly = false
    @State var archived = false
    @State var tagFilter = "全部"
    var visible: [MaterialItem] {
        model.materials.filter { item in
            (category == "全部" || item.category.rawValue == category) && (status == "全部" || item.status.displayName == status) && (tagFilter == "全部" || (item.tags ?? []).contains(tagFilter)) && (!favoriteOnly || item.favorite == true) && (item.archived == true) == archived && (model.search.isEmpty || [item.relativePath, item.notes ?? "", (item.tags ?? []).joined(separator: " ")].joined(separator: " ").localizedCaseInsensitiveContains(model.search))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("分类", selection: $category) { ForEach(["全部", "医学", "AI"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 210)
                Picker("状态", selection: $status) { ForEach(["全部", "新素材", "已生成草稿", "需要补充说明", "处理失败"], id: \.self) { Text($0) } }.frame(width: 155)
                Toggle("收藏", isOn: $favoriteOnly).toggleStyle(.button)
                Toggle("已归档", isOn: $archived).toggleStyle(.button)
                Menu { Button("全部标签") { tagFilter = "全部" }; ForEach(Array(Set(model.materials.flatMap { $0.tags ?? [] })).sorted(), id: \.self) { tag in Button(tag) { tagFilter = tag } } } label: { Label(tagFilter == "全部" ? "标签" : tagFilter, systemImage: "tag") }.fixedSize()
                Spacer()
                Text("\(visible.count) 份素材").font(.caption).foregroundStyle(.secondary)
            }.padding(18)
            Divider()
            GeometryReader { layout in
            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) { dropTarget(.medical); dropTarget(.ai) }.padding(12)
                    List(visible, selection: $model.selectedMaterialID) { item in
                        HStack(spacing: 10) {
                            Image(systemName: ["PNG", "JPG", "JPEG", "HEIC"].contains(item.fileType) ? "photo" : "doc.text").font(.title2).foregroundStyle(item.category.tint).frame(width: 32)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(URL(fileURLWithPath: item.relativePath).lastPathComponent).lineLimit(2).font(.callout.weight(.medium))
                                Text(item.status.displayName + " · " + item.fileType).font(.caption).foregroundStyle(.secondary)
                            }; Spacer(); if item.favorite == true { Image(systemName: "star.fill").foregroundStyle(.orange) }
                        }.padding(.vertical, 6).tag(item.id)
                    }.listStyle(.inset).onKeyPress(.space) { if let item = visible.first(where: { $0.id == model.selectedMaterialID }) { model.preview(item); return .handled }; return .ignored }
                }.frame(minWidth: 260, idealWidth: 310, maxWidth: 370).frame(height: layout.size.height)
                if let item = visible.first(where: { $0.id == model.selectedMaterialID }) { MaterialInspector(item: item).id(item.id) }
                else { ContentUnavailableView("收好灵感，再慢慢整理", systemImage: "tray", description: Text("拖入图片或文档，或点击右上角导入素材。")) }
            }.frame(width: layout.size.width, height: layout.size.height)
            }
        }
    }
    func dropTarget(_ category: DraftCategory) -> some View {
        Label("拖入" + category.rawValue, systemImage: "plus").font(.caption.weight(.medium)).frame(maxWidth: .infinity).padding(14)
            .background(category.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(category.tint.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4])))
            .dropDestination(for: URL.self) { urls, _ in model.importFiles(urls, category: category); return true }
    }
}
struct MaterialInspector: View {
    @EnvironmentObject var model: AppModel
    let item: MaterialItem
    @State var notes = ""
    @State var tags = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { CategoryBadge(category: item.category); Spacer(); Button { Task { await model.patchMaterial(item, values: ["favorite": item.favorite != true]) } } label: { Image(systemName: item.favorite == true ? "star.fill" : "star") }.buttonStyle(.borderless).tint(.orange) }
                Text(URL(fileURLWithPath: item.relativePath).lastPathComponent).font(.title2.bold()).textSelection(.enabled)
                Label(item.status.displayName, systemImage: item.status == .needsNote || item.status == .failed ? "exclamationmark.circle" : "doc.badge.clock").foregroundStyle(.secondary)
                if let reason = item.reason, !reason.isEmpty { Text(reason).font(.callout).foregroundStyle(.orange) }
                if let url = try? model.runtime.localMaterialFile(item), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Button { model.preview(item) } label: { Label("空格或点击预览文档", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, minHeight: 90) }.buttonStyle(.bordered)
                }
                HStack { Button("快速预览") { model.preview(item) }; Button("打开原文件") { if let url = try? model.runtime.localMaterialFile(item) { NSWorkspace.shared.open(url) } }; Button("Finder") { model.reveal(item) }; Spacer(); Text(item.modifiedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                Panel(title: "整理与补充") {
                    TextField("标签，用逗号分隔", text: $tags).textFieldStyle(.roundedBorder)
                    TextEditor(text: $notes).font(.body).frame(minHeight: 90).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("备注会作为用户补充说明提供给本地模型，不能替代可靠来源。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("保存说明") { Task { await model.patchMaterial(item, values: ["notes": notes, "tags": tags.replacingOccurrences(of: "，", with: ",").components(separatedBy: ",")]) } }
                        Spacer(); Button(item.archived == true ? "恢复素材" : "归档素材") { Task { await model.patchMaterial(item, values: ["archived": item.archived != true]) } }
                    }
                }
                Button { Task { await model.patchMaterial(item, values: ["notes": notes, "tags": tags.components(separatedBy: ",")]); model.generateMaterialID = item.id; model.showGenerate = true } } label: { Label("用这份素材生成", systemImage: "sparkles").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
                if !item.draftIDs.isEmpty { Panel(title: "关联草稿") { ForEach(item.draftIDs, id: \.self) { id in Button { model.showDraft(id) } label: { Text(model.drafts.first(where: { $0.id == id })?.postText ?? id).lineLimit(2) }.buttonStyle(.link) } } }
            }.padding(24)
        }.frame(maxWidth: .infinity).onAppear { notes = item.notes ?? ""; tags = (item.tags ?? []).joined(separator: ", ") }
    }
}
