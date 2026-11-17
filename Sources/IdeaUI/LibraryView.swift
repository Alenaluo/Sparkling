import AppKit
import SwiftUI
import IdeaCore

enum SidebarItem: Hashable {
    /// v2：所有项目的灵感（design §11.3）
    case all
    /// v2：剪贴板历史
    case clipboard
    case inbox
    case repo(String)
}

/// 主窗口最近一次可撤销的操作
enum LibraryUndo {
    case moved(Idea, from: Repo)
    case trashed(trashURL: URL, original: Idea)
}

/// 仓库弹窗：新建 / 设置
enum RepoSheetMode: Identifiable {
    case create
    case edit(Repo)
    var id: String { if case let .edit(r) = self { return r.id }; return "new" }
}

/// design.md v0.7 §5：两栏（侧栏 + 按日期分组的列表），原地编辑，仓库设置用弹窗。
struct LibraryView: View {
    @Environment(AppModel.self) var app
    var openSettings: () -> Void
    /// v2 剪贴板页「存成灵感」：打开记录面板预填
    var saveClip: (ClipItem) -> Void = { _ in }

    @State private var sidebar: SidebarItem? = .inbox
    @State private var selectedID: String?
    @State private var editingID: String?
    @State private var hoveredID: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @FocusState private var editorFocused: Bool
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var undo: LibraryUndo?
    @State private var movingID: String?
    @State private var deletingRepo: Repo?
    @State private var repoSheet: RepoSheetMode?
    @State private var errorAlert: String?
    /// D19 双击改名
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var renameCancelled = false
    @FocusState private var renameFocused: Bool
    /// 改名不生效时：圈闪红 150ms；随后在名字下方弹轻提示气泡 2 秒
    @State private var renameFlash = false
    @State private var renameInTitle = false
    @State private var renameBubble: (id: String, inTitle: Bool, text: String)?
    @State private var bubbleVisible = false
    @State private var bubbleToken = 0
    /// 退出编辑时发现文件被外部改过
    @State private var conflict: (idea: Idea, text: String)?
    @Environment(\.controlActiveState) private var activeState

    var currentRepo: Repo {
        if case let .repo(id) = sidebar { return app.library.repo(id: id) ?? app.library.inbox }
        return app.library.inbox
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var showingAll: Bool { sidebar == .all && !isSearching }
    /// ⌘F 全局搜索不搜剪贴板：搜索时照常显示灵感结果
    var onClipboardPage: Bool { sidebar == .clipboard && !isSearching }
    var listedIdeas: [Idea] {
        if isSearching || sidebar == .all { return TextSearch.search(isSearching ? query : "", in: app.library.ideas) }
        return app.library.ideas(in: currentRepo)
    }
    var groups: [DateGroup] { DateGrouping.groups(listedIdeas) }
    var flatIDs: [String] { groups.flatMap { $0.ideas.map(\.id) } }
    func idea(_ id: String?) -> Idea? { id.flatMap { i in app.library.ideas.first { $0.id == i } } }

    var body: some View {
        VStack(spacing: 0) {
            if let err = app.loadError {
                HStack(spacing: 10) {
                    Text(err).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                    Button("重新选择…") { openSettings() }.buttonStyle(DangerButton())
                    Button("在原位置新建") { try? app.store.ensureRoot(); app.reload() }.buttonStyle(DangerButton())
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.dangerBg)
            }
            HStack(spacing: 0) {
                sidebarView.frame(width: 200)
                if onClipboardPage {
                    ClipboardPage(clip: app.clipboard, onSaveAsIdea: saveClip)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    listView.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { toastView }
        .background { shortcuts }
        .sheet(item: $repoSheet) { mode in
            RepoSheet(mode: mode, onClose: { created in
                repoSheet = nil
                if let created { sidebar = .repo(created.id) }
            }, onDelete: { repo in
                repoSheet = nil
                DispatchQueue.main.async { deletingRepo = repo }
            })
        }
        .alert(deletingRepo.map { "删除「\($0.displayName)」？" } ?? "", isPresented: Binding(get: { deletingRepo != nil }, set: { if !$0 { deletingRepo = nil } }), presenting: deletingRepo) { repo in
            Button("取消", role: .cancel) { deletingRepo = nil }
            Button("删除", role: .destructive) { deleteRepo(repo) }
        } message: { repo in
            Text("其中 \(app.library.count(in: repo)) 条灵感会移到未归类，文件夹本身会被删除。")
        }
        .alert(errorAlert ?? "", isPresented: Binding(get: { errorAlert != nil }, set: { if !$0 { errorAlert = nil } })) {
            Button("好") { errorAlert = nil }
        }
        .onChange(of: sidebar) { _, _ in selectedID = nil; editingID = nil }
        .onChange(of: editorFocused) { _, focused in
            guard !focused, let editing = editingID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !editorFocused && editingID == editing && movingID == nil { endEditing() }
            }
        }
        .onChange(of: activeState) { _, state in if state != .key { endEditing() } }
        .onChange(of: renameFocused) { _, focused in if !focused && renamingID != nil { commitRename() } }
        .alert("文件已在别处修改", isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })) {
            Button("用我的覆盖") {
                if let c = conflict { do { let u = try app.store.updateIdea(c.idea, body: c.text, force: true); app.replace(c.idea, with: u) } catch { errorAlert = error.localizedDescription } }
                conflict = nil
            }
            Button("载入新版本") { app.reload(); conflict = nil }
        } message: { Text("这条灵感的文件在 App 外被改过。") }
        .onChange(of: query) { _, _ in selectedID = nil; editingID = nil }
    }

    // MARK: 侧栏

    var sidebarItems: [SidebarItem] { [.all, .clipboard, .inbox] + app.library.repos.map { .repo($0.id) } }

    var sidebarView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("搜索全部 ⌘F", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { query = ""; searchFocused = false; listFocused = true }
                    .onKeyPress(.downArrow) { listFocused = true; selectedID = flatIDs.first; return .handled }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(searchFocused ? Theme.accent : .clear, lineWidth: 2))
            .padding(.horizontal, 12).padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // v2（design §11.3）：「全部灵感」「剪贴板」在最上，下面空 10 再是未归类和项目
                    topRow("全部灵感", icon: "tray.full", count: app.library.ideas.count, item: .all)
                    topRow("剪贴板", icon: "doc.on.clipboard", count: app.clipboard.items.count, item: .clipboard)
                    Color.clear.frame(height: 10)
                    sidebarRow(app.library.inbox, item: .inbox)
                        .contextMenu {
                            Button("在 Finder 中显示") { reveal(app.root.appendingPathComponent(LibraryStore.inboxFolder)) }
                        }
                    HStack {
                        Text("项目").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button { repoSheet = .create } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("新建项目 ⌘N")
                    }
                    .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                    ForEach(app.library.repos) { repo in
                        sidebarRow(repo, item: .repo(repo.id))
                            .contextMenu {
                                Button("项目设置…  ⌘I") { repoSheet = .edit(repo) }
                                Button("在 Finder 中显示") { reveal(app.root.appendingPathComponent(repo.folder)) }
                                Button("新建项目…  ⌘N") { repoSheet = .create }
                                Divider()
                                Button("删除项目…", role: .destructive) { deletingRepo = repo }
                            }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { endEditing() })
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { stepSidebar(-1); return .handled }
            .onKeyPress(.downArrow) { stepSidebar(1); return .handled }
        }
        .background(Theme.block)
    }

    func stepSidebar(_ d: Int) {
        let items = sidebarItems
        let i = sidebar.flatMap { items.firstIndex(of: $0) } ?? 0
        sidebar = items[max(0, min(items.count - 1, i + d))]
    }

    func topRow(_ title: String, icon: String, count: Int, item: SidebarItem) -> some View {
        let on = sidebar == item
        let fg = on ? Theme.onSidebarSelected : Theme.textPrimary
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? fg : Theme.textSecondary).frame(width: 16, height: 16)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(fg).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(on ? fg : Theme.textSecondary)
        }
        .padding(.horizontal, 10).frame(minHeight: 30)
        .background(on ? Theme.sidebarSelected : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { endEditing(); query = ""; sidebar = item }
    }

    func sidebarRow(_ repo: Repo, item: SidebarItem) -> some View {
        let on = sidebar == item
        let fg = on ? Theme.onSidebarSelected : Theme.textPrimary
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            RepoMarker(repo: repo, size: 10, onSelectedSidebar: on).frame(width: 12)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            if renamingID == repo.id {
                renameField(size: 13, weight: .medium)
            } else {
                // 项目名自动换行，不截断
                Text(repo.displayName).font(.system(size: 13, weight: .medium)).foregroundStyle(fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let n = app.library.count(in: repo)
            if n > 0 || !repo.isInbox {
                Text("\(n)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(on ? fg : Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 30)
        .background(on ? Theme.sidebarSelected : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .overlay(alignment: .bottomLeading) {
            renameBubbleView(for: repo.id, inTitle: false).fixedSize().offset(x: 30, y: 30)
        }
        .zIndex(renameBubble?.id == repo.id ? 1 : 0)
        // 单击立即切换；不用 onTapGesture(count: 2)，否则每次单击都要等双击超时才响应（11-18 侧栏点项目很慢）
        .onTapGesture {
            if isDoubleClick { endEditing(); sidebar = item; startRename(repo) } else { endEditing(); sidebar = item }
        }
    }

    // MARK: 列表（按日期分组，分组标题吸顶）

    var listView: some View {
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    HStack(alignment: .firstTextBaseline) {
                        if !isSearching && !showingAll && renamingID == currentRepo.id {
                            renameField(size: 22, weight: .bold)
                        } else {
                            Text(isSearching ? "搜索「\(query)」" : showingAll ? "全部灵感" : currentRepo.displayName)
                                .font(.system(size: 22, weight: .bold)).kerning(-0.22).lineSpacing(6)
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                .onTapGesture(count: 2) { if !isSearching && !showingAll { startRename(currentRepo, inTitle: true) } }
                        }
                        Spacer()
                        Text("\(listedIdeas.count) 条").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(minHeight: 28)
                    .overlay(alignment: .bottomLeading) {
                        renameBubbleView(for: currentRepo.id, inTitle: true).fixedSize().offset(y: 30)
                    }
                    .zIndex(1)
                    .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 20)

                    if groups.isEmpty {
                        // 剩余区域 = 列表区高度 − 顶部 28 − 标题 28 − 20
                        emptyState.frame(maxWidth: .infinity).frame(height: max(220, geo.size.height - 76))
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { gi, group in
                        Section {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(group.ideas) { idea in row(idea).id(idea.id) }
                            }
                        } header: {
                            Text(group.title)
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .padding(.horizontal, 40)
                                .background(Theme.canvas)
                                .padding(.top, gi == 0 ? 0 : 24)
                                .background(Theme.canvas)
                        }
                    }
                    Color.clear.frame(height: 24)
                }
                // 底纹跟内容一起滚；内容不满一屏时也铺满
                .frame(minHeight: geo.size.height, alignment: .top)
                // 只有点到真正的空白（背景层）才退出编辑；按钮、卡片优先处理点击
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { endEditing() })
                .background(TexturedBackground(texture: app.texture))
            }
            .background(Theme.canvas)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { step(-1, proxy); return .handled }
            .onKeyPress(.downArrow) { step(1, proxy); return .handled }
            .onKeyPress(.return) { if let s = selectedID { editingID = s; return .handled }; return .ignored }
            .onKeyPress(.escape) {
                if isSearching { query = ""; return .handled }
                return .ignored
            }
        }
        }
    }

    func step(_ delta: Int, _ proxy: ScrollViewProxy) {
        let ids = flatIDs
        guard !ids.isEmpty else { return }
        editingID = nil
        let i = selectedID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        let next = ids[max(0, min(ids.count - 1, i + delta))]
        selectedID = next
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(next, anchor: .center) }
    }

    @ViewBuilder func row(_ idea: Idea) -> some View {
        let isSelected = selectedID == idea.id
        Group {
            if editingID == idea.id {
                EditCard(idea: idea, focused: $editorFocused,
                         onMove: { movingID = idea.id }, onTrash: { trash(idea) },
                         onClose: { endEditing() },
                         onConflict: { i, t in conflict = (i, t) })
            } else {
                // 开头是图片 / 文件卡片时，时间和卡片顶部对齐
                HStack(alignment: IdeaAttachments.parse(idea.body).isEmpty ? .firstTextBaseline : .top, spacing: 16) {
                    Text(DateGrouping.time(idea.created))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, alignment: .leading)
                    rowBody(idea)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isSearching || showingAll, let repo = app.library.repo(folder: idea.repoFolder) { repoChip(repo) }
                }
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background((isSelected ? Theme.selected : (hoveredID == idea.id ? Theme.block : .clear)), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .onHover { hoveredID = $0 ? idea.id : (hoveredID == idea.id ? nil : hoveredID) }
                .onTapGesture {
                    if isDoubleClick { selectedID = idea.id; editingID = idea.id } else { endEditing(); selectedID = idea.id; listFocused = true }
                }
                .contextMenu {
                    Button("编辑  ⏎") { selectedID = idea.id; editingID = idea.id }
                    Button("移动到…  ⌘M") { selectedID = idea.id; movingID = idea.id }
                    Button("在 Finder 中显示") { reveal(idea.url) }
                    Button("拷贝内容  ⌘C") { copy(idea) }
                    Divider()
                    Button("删除  ⌘⌫") { trash(idea) }
                }
            }
        }
        .padding(.horizontal, 26)
        .popover(isPresented: Binding(get: { movingID == idea.id }, set: { if !$0 { movingID = nil } }), arrowEdge: .trailing) {
            MovePicker(idea: idea, repos: app.library.allRepos, onPick: { target in movingID = nil; move(idea, to: target) }, onCancel: { movingID = nil })
        }
    }

    /// 正文：开头的图片 / 文件链接按卡片显示（和剪贴板一致），其余文字照旧
    @ViewBuilder func rowBody(_ idea: Idea) -> some View {
        let att = IdeaAttachments.parse(idea.body)
        if att.isEmpty {
            bodyText(idea.body)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                AttachmentCards(att: att, baseDir: idea.url.deletingLastPathComponent())
                if !att.text.isEmpty { bodyText(att.text) }
            }
        }
    }

    func bodyText(_ text: String) -> some View {
        highlighted(text)
            .font(.system(size: 14)).lineSpacing(5)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(3)
    }

    /// 当前点击是否双击的第二下（配合单个 onTapGesture，单击不用等双击超时）
    var isDoubleClick: Bool { (NSApp.currentEvent?.clickCount ?? 1) >= 2 }

    func repoChip(_ repo: Repo) -> some View {
        HStack(spacing: 4) {
            RepoMarker(repo: repo, size: 8)
            Text(repo.displayName).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 20)
        .background(Theme.repoTint(repo), in: Capsule())
        .fixedSize()
    }

    /// 搜索命中词加下划线
    func highlighted(_ text: String) -> Text {
        guard isSearching else { return Text(text) }
        var attr = AttributedString(text)
        for term in query.split(whereSeparator: \.isWhitespace) {
            var start = attr.startIndex
            while start < attr.endIndex, let r = attr[start...].range(of: String(term), options: [.caseInsensitive, .widthInsensitive]) {
                attr[r].underlineStyle = .single
                attr[r].underlineColor = NSColor(Theme.accent)
                start = r.upperBound
            }
        }
        return Text(attr)
    }

    @ViewBuilder var emptyState: some View {
        if isSearching {
            VStack(spacing: 8) {
                Image(systemName: "cloud.rain").font(.system(size: 36)).foregroundStyle(Theme.textTertiary)
                Text("没有找到「\(query)」").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
        } else {
            VStack(spacing: 0) {
                EmptyCup().frame(width: 64)
                Text(currentRepo.isInbox && !showingAll ? "还空着 ✓" : "还空着")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .padding(.top, 16)
                if !currentRepo.isInbox || showingAll {
                    Text(showingAll ? "按 \(HotkeyCenter.shared.current?.display ?? Hotkey.load().display) 记一条，就会出现在这里" : "按 \(HotkeyCenter.shared.current?.display ?? Hotkey.load().display) 记一条，选「\(currentRepo.displayName)」就装进这里")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .padding(.top, 6)
                }
            }
        }
    }

    /// 退出编辑态（D17）：卡片收起时自动保存；让输入框交出焦点
    func endEditing() {
        if renamingID != nil { NSApp.keyWindow?.makeFirstResponder(nil) }
        guard editingID != nil else { return }
        editingID = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        listFocused = true
    }

    // MARK: 双击改名（D19）

    /// 原地输入框：尺寸与原文字一致，白底 + 2pt accent 圈，进入时全选原名
    func renameField(size: CGFloat, weight: Font.Weight) -> some View {
        TextField("", text: $renameText)
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(Theme.textPrimary)
            .focused($renameFocused)
            .onSubmit { commitRename() }
            .onExitCommand { renameCancelled = true; renamingID = nil }
            .padding(.horizontal, 4)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(renameFlash ? Theme.danger : Theme.accent, lineWidth: 2))
            .padding(.horizontal, -4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「未归类」「全部灵感」不可改名
    func startRename(_ repo: Repo, inTitle: Bool = false) {
        guard !repo.isInbox else { return }
        renameInTitle = inTitle
        endEditing()
        renameText = repo.folder
        renameCancelled = false
        renamingID = repo.id
        DispatchQueue.main.async {
            renameFocused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
    }

    /// ⏎ 或点别处确认；空名 / 重名 / 非法 → 恢复原名并轻提示
    func commitRename() {
        guard let id = renamingID, !renameCancelled, !renameFlash, let repo = app.library.repo(id: id) else {
            if !renameFlash { renamingID = nil }
            return
        }
        switch RenamePolicy.decide(renameText, repo: repo, others: app.library.repos) {
        case .unchanged:
            renamingID = nil
        case let .rejected(msg):
            // 圈变红闪 150ms → 恢复原名 → 名字下方弹轻提示
            renameFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                renameFlash = false
                renameText = repo.folder
                renamingID = nil
                showRenameBubble(id: id, text: msg)
            }
        case let .rename(name):
            renamingID = nil
            do {
                let updated = try app.store.updateRepo(repo, name: name, shortcode: repo.shortcode, description: repo.description, in: app.library)
                app.reload()
                if sidebar == .repo(id) { sidebar = .repo(updated.id) }
                log.info("renamed \(repo.folder, privacy: .public) → \(updated.folder, privacy: .public)")
            } catch {
                showToast("改名失败：\(error.localizedDescription)，已恢复原名")
            }
        }
    }

    func showRenameBubble(id: String, text: String) {
        bubbleToken += 1
        let token = bubbleToken
        renameBubble = (id, renameInTitle, text)
        bubbleVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard token == bubbleToken else { return }
            withAnimation(.easeOut(duration: 0.25)) { bubbleVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if token == bubbleToken { renameBubble = nil } }
        }
    }

    /// 轻提示气泡：白底、高 24、圆角 8、12pt 正文色字、左侧 6pt danger 圆点、弹层投影；不抢焦点、不挡输入
    @ViewBuilder func renameBubbleView(for id: String, inTitle: Bool) -> some View {
        if let b = renameBubble, b.id == id, b.inTitle == inTitle {
            HStack(spacing: 6) {
                Circle().fill(Theme.danger).frame(width: 6, height: 6)
                Text(b.text).font(.system(size: 12)).foregroundStyle(Theme.textPrimary).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: Theme.shadow, radius: 12, x: 0, y: 6)
            .opacity(bubbleVisible ? 1 : 0)
            .allowsHitTesting(false)
            .alignmentGuide(.top) { d in d[.top] - 6 }
        }
    }

    // MARK: 操作

    func move(_ idea: Idea, to target: Repo) {
        guard target.folder != idea.repoFolder else { return }
        let from = app.library.repo(folder: idea.repoFolder) ?? app.library.inbox
        let next = neighbor(of: idea.id)
        do {
            let moved = try app.store.moveIdea(idea, to: target)
            withAnimation(.easeOut(duration: 0.18)) { app.replace(idea, with: moved) }
            undo = .moved(moved, from: from)
            editingID = nil
            selectedID = isSearching ? moved.id : next
            showToast("已移到 \(target.displayName) · ⌘Z 撤销")
        } catch { errorAlert = "移动失败：\(error.localizedDescription)" }
    }

    func trash(_ idea: Idea) {
        let next = neighbor(of: idea.id)
        do {
            let url = try app.store.trashIdea(idea)
            withAnimation(.easeOut(duration: 0.18)) { app.remove(idea) }
            if let url { undo = .trashed(trashURL: url, original: idea) }
            editingID = nil
            selectedID = next
            listFocused = true
            showToast("已移到废纸篓 · ⌘Z 撤销")
        } catch { errorAlert = "删除失败：\(error.localizedDescription)" }
    }

    /// 删除 / 移走后选中下一条（没有就上一条）
    func neighbor(of id: String) -> String? {
        let ids = flatIDs
        guard let i = ids.firstIndex(of: id) else { return nil }
        if i + 1 < ids.count { return ids[i + 1] }
        return i > 0 ? ids[i - 1] : nil
    }

    func performUndo() {
        guard let u = undo else { return }
        undo = nil
        do {
            switch u {
            case let .moved(idea, from):
                let back = try app.store.moveIdea(idea, to: from)
                app.replace(idea, with: back)
                selectedID = back.id
                showToast("已撤销移动")
            case let .trashed(trashURL, original):
                try app.store.restore(from: trashURL, to: original.url)
                app.reload()
                selectedID = original.id
                showToast("已从废纸篓放回")
            }
        } catch { errorAlert = "撤销失败：\(error.localizedDescription)" }
    }

    func copy(_ idea: Idea) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(idea.body, forType: .string)
        showToast("已拷贝")
    }

    func deleteRepo(_ repo: Repo) {
        deletingRepo = nil
        do {
            let n = try app.store.deleteRepo(repo)
            app.reload()
            sidebar = .inbox
            showToast("已删除「\(repo.displayName)」，\(n) 条灵感移到未归类")
        } catch { errorAlert = "删除项目失败：\(error.localizedDescription)" }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func showToast(_ s: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.easeOut(duration: 0.18)) { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if token == toastToken { withAnimation(.easeIn(duration: 0.25)) { toast = nil } }
        }
    }

    @ViewBuilder var toastView: some View {
        if let toast {
            Text(toast).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16).frame(height: 40)
                .background(Theme.canvas, in: Capsule()).cardShadow()
                .padding(.bottom, 20)
                .transition(.opacity)
        }
    }

    var textInputFocused: Bool { editorFocused || searchFocused || renameFocused }

    /// 主窗口快捷键（design §6.4）。输入框有焦点时，⌘⌫ / ⌘Z / ⌘C 交还给输入框。
    var shortcuts: some View {
        Group {
            Button("") { searchFocused = true }.keyboardShortcut("f")
            Button("") { repoSheet = .create }.keyboardShortcut("n")
            // 剪贴板页有自己的 ⌘S / ⌘⌫，这几项让给它和输入框
            Group {
                Button("") { if let s = selectedID { movingID = s } }.keyboardShortcut("m")
                Button("") {
                    if textInputFocused { NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil) }
                    else if let i = idea(selectedID) { trash(i) }
                }.keyboardShortcut(.delete, modifiers: .command)
                Button("") {
                    if textInputFocused { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { performUndo() }
                }.keyboardShortcut("z")
                Button("") {
                    if textInputFocused { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    else if let i = idea(selectedID) { copy(i) }
                }.keyboardShortcut("c")
                Button("") { if !currentRepo.isInbox && !showingAll { repoSheet = .edit(currentRepo) } }.keyboardShortcut("i")
            }
            .disabled(onClipboardPage)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }
}

// MARK: - 原地编辑卡片

struct EditCard: View {
    @Environment(AppModel.self) var app
    let idea: Idea
    var focused: FocusState<Bool>.Binding
    var onMove: () -> Void
    var onTrash: () -> Void
    var onClose: () -> Void
    /// 退出时文件已被外部改过：交给窗口弹窗处理（卡片此时已收起）
    var onConflict: (Idea, String) -> Void

    @State private var text = ""
    @State private var original = ""
    @State private var current: Idea?
    @State private var saveTask: Task<Void, Never>?
    /// 正文开头的图片 / 文件：编辑时照样显示成卡片，输入框只编辑后面的文字，保存时拼回去
    @State private var att = IdeaAttachments()

    /// 输入框文字 → 完整正文
    func full(_ t: String) -> String { att.isEmpty ? t : att.compose(text: t) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: att.isEmpty ? .firstTextBaseline : .top, spacing: 16) {
                Text(DateGrouping.time(idea.created))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                if !att.isEmpty { AttachmentCards(att: att, baseDir: idea.url.deletingLastPathComponent()) }
                TextEditor(text: $text)
                    .font(.system(size: 15)).lineSpacing(7)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(minHeight: 48)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused(focused)
                    .onChange(of: text) { _, new in scheduleSave(new) }
                    .onKeyPress(.escape) { onClose(); return .handled }
                    .onExitCommand { onClose() }
                }
            }
            // D17：编辑态不显示「已自动保存 · Esc 收起」之类提示，只留按钮
            HStack(spacing: 8) {
                Spacer()
                Button("移动到…  ⌘M") { commitOnExit(); onMove() }.buttonStyle(CardButton())
                Button("删除  ⌘⌫") { saveTask?.cancel(); onTrash() }.buttonStyle(CardButton(danger: true))
            }
            .padding(.leading, 60)
        }
        .padding(.top, 16).padding(.bottom, 14).padding(.horizontal, 14)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.lineSoft, lineWidth: 1))
        .shadow(color: Theme.c(Theme.t.textPrimary, 0.06), radius: 10, x: 0, y: 6)
        // 点卡片内空白不算「点外面」：背景层吞掉点击，按钮在前景照常可点
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { focused.wrappedValue = true })
        .onAppear {
            att = IdeaAttachments.parse(idea.body)
            text = att.isEmpty ? idea.body : att.text
            original = idea.body; current = idea
            DispatchQueue.main.async { focused.wrappedValue = true }
        }
        .onDisappear { commitOnExit() }
    }

    func scheduleSave(_ value: String) {
        let value = full(value)
        guard let c = current, EditExitPolicy.shouldAutosave(value, onDisk: c.body) else { saveTask?.cancel(); return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { _ = write(value) }
        }
    }

    /// 退出编辑：保存；正文清空则恢复编辑前内容（D17）
    func commitOnExit() {
        saveTask?.cancel()
        // 已被移走或删除：不能在原路径重新写出文件
        guard let c = current, FileManager.default.fileExists(atPath: c.url.path) else { return }
        if case let .write(body) = EditExitPolicy.decide(original: original, onDisk: c.body, edited: full(text)) {
            if !write(body) { onConflict(c, body) }
        }
        log.info("edit exit \(c.url.lastPathComponent, privacy: .public)")
    }

    /// 写回文件；外部改过时返回 false
    @discardableResult
    func write(_ value: String) -> Bool {
        guard let c = current else { return true }
        do {
            let updated = try app.store.updateIdea(c, body: value, force: false)
            app.replace(c, with: updated)
            current = updated
            return true
        } catch LibraryError.modifiedExternally {
            return false
        } catch {
            log.error("update failed \(error.localizedDescription, privacy: .public)")
            return true
        }
    }
}

struct CardButton: ButtonStyle {
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(danger ? Theme.danger : Theme.textPrimary)
            .padding(.horizontal, 10).frame(height: 30)
            .background((danger ? Theme.dangerBg : Theme.selected).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: - 仓库设置 / 新建仓库弹窗（design §5.3）

struct RepoSheet: View {
    @Environment(AppModel.self) var app
    let mode: RepoSheetMode
    var onClose: (Repo?) -> Void
    var onDelete: (Repo) -> Void

    @State private var name = ""
    @State private var shortcode = ""
    @State private var desc = ""
    @State private var nameError: String?
    @State private var shortcodeError: String?
    @State private var shortcodeEdited = false
    @FocusState private var field: Int?

    var editing: Repo? { if case let .edit(r) = mode { return app.library.repo(id: r.id) ?? r }; return nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if let r = editing {
                    RepoMarker(repo: r, size: 10)
                    Text("项目设置 · \(r.displayName)")
                } else {
                    Text("新建项目")
                }
            }
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)

            formRow("名称", error: nameError, hint: nil) { input($name, tag: 0, placeholder: "必填") }
            formRow("短码", error: shortcodeError, hint: "输入 @\(shortcode.isEmpty ? "短码" : shortcode) 直接存到这里") {
                input($shortcode, tag: 1, placeholder: "自动生成").frame(width: 160)
            }
            formRow("描述", error: nil, hint: "给自己看的一两句说明") { input($desc, tag: 2, placeholder: "", axis: .vertical) }

            HStack(spacing: 8) {
                if let r = editing {
                    Button("删除项目…") { onDelete(r) }.buttonStyle(DangerButton())
                    Spacer()
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([app.root.appendingPathComponent(r.folder)]) }
                        .buttonStyle(SecondaryButton())
                    Button("完成") { finish() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button("取消") { onClose(nil) }.buttonStyle(SecondaryButton())
                    Button("创建") { finish() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.canvas)
        .onAppear {
            if let r = editing { name = r.folder; shortcode = r.shortcode; desc = r.description }
            field = 0
        }
        .onChange(of: name) { _, n in
            if editing == nil && !shortcodeEdited { shortcode = Pinyin.initials(n) }
            validate()
        }
        .onChange(of: shortcode) { _, _ in validate() }
        .onChange(of: field) { old, _ in if old != nil, editing != nil { commit() } }
        .onExitCommand { if editing != nil { finish() } else { onClose(nil) } }
    }

    func formRow<C: View>(_ label: String, error: String?, hint: String?, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 48, alignment: .leading).padding(.top, 9)
            VStack(alignment: .leading, spacing: 4) {
                content()
                if let error { Text(error).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger) }
                else if let hint { Text(hint).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary) }
            }
        }
    }

    func input(_ text: Binding<String>, tag: Int, placeholder: String, axis: Axis = .horizontal) -> some View {
        TextField(placeholder, text: text, axis: axis)
            .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
            .lineLimit(axis == .vertical ? 4 : 1)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(minHeight: 34)
            .background(Theme.block, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(field == tag ? Theme.accent : .clear, lineWidth: 2))
            .focused($field, equals: tag)
            .onChange(of: text.wrappedValue) { _, _ in if tag == 1, field == 1 { shortcodeEdited = true } }
            .onSubmit { finish() }
    }

    /// 即时校验：名称非法 / 重名、短码重复
    @discardableResult
    func validate() -> Bool {
        nameError = nil; shortcodeError = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = FileNamer.repoNameProblem(trimmed) { nameError = p }
        else if app.library.repos.contains(where: { $0.id != editing?.id && $0.folder.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            nameError = "已经有叫「\(trimmed)」的项目"
        }
        let sc = shortcode.trimmingCharacters(in: .whitespaces).lowercased()
        if !sc.isEmpty, let other = app.library.repos.first(where: { $0.id != editing?.id && $0.shortcode.lowercased() == sc }) {
            shortcodeError = "已被 \(other.displayName) 使用"
        }
        return nameError == nil && shortcodeError == nil
    }

    /// 失焦即保存（编辑模式）；校验失败不保存
    @discardableResult
    func commit() -> Repo? {
        guard validate(), let live = editing else { return nil }
        if name == live.folder && shortcode == live.shortcode && desc == live.description { return live }
        do {
            let updated = try app.store.updateRepo(live, name: name, shortcode: shortcode, description: desc, in: app.library)
            app.reload()
            return updated
        } catch {
            nameError = error.localizedDescription
            return nil
        }
    }

    /// 完成 / 创建 / ⏎ / Esc：校验失败时不关闭
    func finish() {
        if editing != nil {
            guard validate(), commit() != nil else { return }
            onClose(nil)
        } else {
            guard validate() else { return }
            do {
                let r = try app.store.createRepo(name: name, shortcode: shortcode.isEmpty ? nil : shortcode, description: desc, in: app.library)
                app.reload()
                onClose(r)
            } catch {
                nameError = error.localizedDescription
            }
        }
    }
}

// MARK: - 移动浮层（出现在条目右侧）

struct MovePicker: View {
    let idea: Idea
    let repos: [Repo]
    var onPick: (Repo) -> Void
    var onCancel: () -> Void
    @State private var filter = ""
    @State private var highlight = 0
    @FocusState private var focused: Bool

    var items: [Repo] { RepoMatcher(repos: repos).match(filter) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("移动到…", text: $filter).textFieldStyle(.plain).focused($focused)
                    .onSubmit { pick(highlight) }
                    .onKeyPress(.upArrow) { highlight = max(0, highlight - 1); return .handled }
                    .onKeyPress(.downArrow) { highlight = min(items.count - 1, highlight + 1); return .handled }
                    .onKeyPress(.tab) { pick(highlight); return .handled }
                    .onExitCommand { onCancel() }
                    .onChange(of: filter) { _, _ in highlight = 0 }
            }
            .font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).frame(height: 32)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, repo in
                let isCurrent = repo.folder == idea.repoFolder
                HStack(spacing: 8) {
                    RepoMarker(repo: repo, size: 10)
                    Text(repo.displayName + (isCurrent ? "（当前）" : "")).lineLimit(1)
                    Spacer()
                    if let n = shortcutNumber(repo) { Text("⌘\(n)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isCurrent ? Theme.textTertiary : Theme.textPrimary)
                .padding(.horizontal, 10).frame(height: 32)
                .background(i == highlight ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { pick(i) }
            }
        }
        .padding(8).frame(width: 300)
        .background(Theme.canvas)
        .background {
            Group {
                ForEach(0..<10, id: \.self) { n in
                    Button("") { if let r = repoForNumber(n) { choose(r) } }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }.opacity(0).frame(width: 0, height: 0)
        }
        .onAppear { focused = true }
    }

    /// 编号与面板 tag 栏一致：⌘0 = 收件箱，⌘1–9 = 前 9 个仓库
    func shortcutNumber(_ r: Repo) -> Int? {
        if r.isInbox { return 0 }
        guard let i = repos.filter({ !$0.isInbox }).firstIndex(of: r), i < 9 else { return nil }
        return i + 1
    }

    func repoForNumber(_ n: Int) -> Repo? {
        if n == 0 { return repos.first { $0.isInbox } }
        let list = repos.filter { !$0.isInbox }
        return list.indices.contains(n - 1) ? list[n - 1] : nil
    }

    func pick(_ i: Int) { if items.indices.contains(i) { choose(items[i]) } }
    func choose(_ r: Repo) { if r.folder != idea.repoFolder { onPick(r) } }
}
