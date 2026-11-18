import AppKit
import SwiftUI
import Observation
import IdeaCore

/// 呼出面板的界面状态。
@Observable @MainActor
final class CaptureModel {
    var repos: [Repo] = []
    var selection = TagSelection()
    var textHeight: CGFloat = 22
    var footerHeight: CGFloat = 100
    var texture: Texture = .default
    var palette: Palette = .default
    var isEmpty = true
    var draftRestored = false
    var errorMessage: String?
    var rootMissing = false

    /// v2 ⌘S 存成灵感：来自剪贴板的条目（只在面板里显示「来自剪贴板」，不写进文件）
    var clip: ClipItem?
    var clipImage: NSImage?
    var clipDetail = ""
    /// 正文上方「来自剪贴板」标签 + 图片 / 文件卡片占的高度
    var clipHeaderHeight: CGFloat {
        guard let clip else { return 0 }
        var h: CGFloat = 20 + 6
        switch clip.kind {
        case .text: break
        case .image: h += Self.imageCardHeight(clipImage) + 10
        case .files: h += 64 + 10
        }
        return h
    }
    static func imageCardHeight(_ img: NSImage?) -> CGFloat {
        guard let img, img.size.width > 0 else { return 150 }
        return min(150, 392 * img.size.height / img.size.width)
    }

    // @ 补全浮层
    var popupItems: [Repo] = []
    var popupQuery: String = ""
    var popupHighlight = 0
    var popupOpen = false

    var selectedRepo: Repo? { selection.selected.flatMap { id in repos.first { $0.id == id } } }
    var targetName: String { selectedRepo?.displayName ?? L("未归类", "Unsorted") }

    /// D20 面板里新建项目
    var creatingRepo = false
    var newRepoName = ""
    var createError: String?
    /// 重名时高亮已有 tag（150ms）
    var flashID: String?

    /// tag 布局结果（正常态可见的项目数在输入态保持不变，避免 tag 跳动）
    var layout: TagLayout {
        let normal = TagLayout.compute(repos: repos, trailing: TagLayout.addWidth)
        guard creatingRepo else { return normal }
        return TagLayout.compute(repos: repos, trailing: TagLayout.inputWidth(newRepoName), maxRows: 4, shown: normal.shownCount)
    }
    var visibleIDs: [String] { layout.rows.flatMap { $0 }.compactMap { if case let .repo(r, _) = $0 { return r.id }; return nil } }
    /// 下一个自动分配的颜色序号（输入胶囊左侧预览）
    var nextColorIndex: Int { repos.count % LibraryStore.paletteCount }
}

// MARK: - tag 布局（最多 3 行；溢出时「+N · @ 搜索」；末尾常驻「＋ ⌘N」或新建输入胶囊）

struct TagLayout: Equatable {
    enum Item: Hashable {
        case repo(Repo, index: Int)
        case overflow(Int)
        /// 末尾：正常态是「＋ ⌘N」，输入态是新建输入胶囊
        case trailing
    }
    var rows: [[Item]]
    var shownCount: Int { rows.flatMap { $0 }.filter { if case .repo = $0 { return true }; return false }.count }

    /// design v1.0 §2.1：卡片 440 × 380（最小），最高 560
    static let panelWidth: CGFloat = 440
    static let minHeight: CGFloat = 380
    static let maxHeight: CGFloat = 560
    static var available: CGFloat { panelWidth - 40 }
    static let gap: CGFloat = 6
    /// 书写区除文字外占的高度：上下内边距 22 + 22，加输入框与下方留白之间的间距 6
    static let writingChrome: CGFloat = 44 + 6
    static let maxTagWidth: CGFloat = 180

    static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let cmdFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    static func width(of repo: Repo, index: Int) -> CGFloat {
        let nameW = ceil((repo.displayName as NSString).size(withAttributes: [.font: nameFont]).width)
        let cmdW = index < 9 ? 6 + ceil(("⌘\(index + 1)" as NSString).size(withAttributes: [.font: cmdFont]).width) : 0
        return min(maxTagWidth, 10 + 8 + 5 + nameW + cmdW + 10)
    }

    /// 英文只写 "+N · @"（design §12.3），悬停提示 "Type @ to search projects"
    static func overflowText(_ n: Int) -> String { L("+\(n) · @ 搜索", "+\(n) · @") }

    static func overflowWidth(_ n: Int) -> CGFloat {
        20 + ceil((TagLayout.overflowText(n) as NSString).size(withAttributes: [.font: nameFont]).width)
    }

    /// 「＋ ⌘N」胶囊宽度
    static var addWidth: CGFloat {
        let plus = ceil(("＋" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .regular)]).width)
        let cmd = ceil(("⌘N" as NSString).size(withAttributes: [.font: cmdFont]).width)
        return 10 + plus + 5 + cmd + 10
    }

    /// 输入胶囊：最小 128，随文字变宽，最宽 260
    static func inputWidth(_ text: String) -> CGFloat {
        let t = text.isEmpty ? L("新项目名", "New project") : text
        let w = ceil((t as NSString).size(withAttributes: [.font: nameFont]).width)
        return min(260, max(128, 10 + 8 + 6 + w + 14))
    }

    /// 前 k 个项目 +（溢出胶囊）+ 末尾元素能否排进 maxRows 行
    static func flow(_ widths: [(Item, CGFloat)], maxRows: Int) -> [[Item]]? {
        var rows: [[Item]] = [[]]
        var x: CGFloat = 0
        for (item, w) in widths {
            if x > 0 && x + gap + w > available {
                if rows.count == maxRows { return nil }
                rows.append([]); x = 0
            }
            rows[rows.count - 1].append(item)
            x += (x > 0 ? gap : 0) + w
        }
        return rows
    }

    /// shown 给定时固定显示前 shown 个项目（输入态保持 tag 不跳动）
    static func compute(repos: [Repo], trailing: CGFloat = 0, maxRows: Int = 3, shown: Int? = nil) -> TagLayout {
        func items(_ k: Int) -> [(Item, CGFloat)] {
            var list = repos.prefix(k).enumerated().map { (Item.repo($0.element, index: $0.offset), width(of: $0.element, index: $0.offset)) }
            if k < repos.count { list.append((.overflow(repos.count - k), overflowWidth(repos.count - k))) }
            if trailing > 0 { list.append((.trailing, trailing)) }
            return list
        }
        if let shown, let rows = flow(items(min(shown, repos.count)), maxRows: maxRows) { return TagLayout(rows: rows) }
        for k in stride(from: repos.count, through: 0, by: -1) {
            if let rows = flow(items(k), maxRows: maxRows) { return TagLayout(rows: rows) }
        }
        return TagLayout(rows: [items(0).map(\.0)])
    }
}

// MARK: - 面板

struct CapturePanelView: View {
    @Bindable var model: CaptureModel
    let textView: NSView
    var onTag: (Repo) -> Void
    var onOverflow: () -> Void
    var onOpenLibrary: () -> Void
    var onOpenSettings: () -> Void
    /// D20：点「＋」/ ⏎ 创建 / Esc 取消
    var onAdd: () -> Void = {}
    var onCreate: () -> Void = {}
    var onCancelCreate: () -> Void = {}
    /// 点「⏎ 保存」也能保存
    var onSubmit: () -> Void = {}
    @FocusState private var newNameFocused: Bool

    /// 书写区里文字最多能占的高度：卡片最高 560 减去内边距、底栏、草稿提示
    var maxTextHeight: CGFloat {
        TagLayout.maxHeight - TagLayout.writingChrome - model.footerHeight - (model.draftRestored ? 22 : 0) - model.clipHeaderHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if model.draftRestored {
                    Text(L("已恢复未保存的草稿 · ⌘⌫ 清空", "Draft restored · ⌘⌫ to clear"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let clip = model.clip {
                    ClipAttachmentHeader(item: clip, image: model.clipImage, detail: model.clipDetail)
                }
                TextViewHost(view: textView)
                    .frame(height: min(model.textHeight, maxTextHeight))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(alignment: .bottomTrailing) {
                // 柔黄：书写区右下角小芽，距右 16、距底 10，在文字下层、跟着书写区底部走（design v1.5 §7.2）
                if Theme.t.butter { ButterSprout().padding(.trailing, 16).padding(.bottom, 10) }
            }
            .background(TexturedBackground(texture: model.texture))

            footer
                .background(GeometryReader { g in
                    Color.clear.preference(key: FooterHeightKey.self, value: g.size.height)
                })
        }
        .frame(width: TagLayout.panelWidth)
        .frame(minHeight: TagLayout.minHeight)
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .cardShadow()
        .padding(40)
        .fixedSize()
        .onPreferenceChange(FooterHeightKey.self) { h in
            if abs(model.footerHeight - h) > 0.5 { model.footerHeight = h }
        }
        .id(model.palette)
        .onChange(of: model.creatingRepo) { _, on in
            if on { DispatchQueue.main.async { newNameFocused = true } }
        }
    }

    @ViewBuilder var footer: some View {
        if let err = model.errorMessage {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("没存上：\(err)", "Couldn't save — \(err)")).font(.system(size: 13, weight: .semibold))
                Text(L("⏎ 重试 · ⌘, 换位置", "⏎ Retry · ⌘, Change location")).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Theme.dangerBg)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if model.repos.isEmpty && !model.creatingRepo {
                    Button(action: onOpenLibrary) {
                        Text(L("还没有项目，全部装进未归类 · 去全部灵感里建一个", "No projects yet — everything goes to Unsorted · Create one in All Ideas"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: TagLayout.gap) {
                    ForEach(Array(model.layout.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: TagLayout.gap) {
                            ForEach(row, id: \.self) { item in tagView(item) }
                        }
                    }
                }
                HStack(spacing: 0) {
                    if model.creatingRepo {
                        // 输入态：底行换成键位提示
                        if let err = model.createError {
                            Text(err).foregroundStyle(Theme.danger)
                        } else {
                            Text(L("⏎ 创建并选中 · Esc 取消", "⏎ Create & select · Esc Cancel")).foregroundStyle(Theme.textPrimary)
                        }
                        Spacer(minLength: 0)
                    } else {
                        destination
                        Spacer(minLength: 8)
                        Button(action: onSubmit) {
                            Text(L("⏎ 保存", "⏎ Save"))
                                .foregroundStyle(Theme.primaryFg)
                                .padding(.horizontal, 8).frame(height: 22)
                                .background(Theme.primary, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(minHeight: 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Theme.block)
        }
    }

    /// 底行左侧落点：「装进 ■ X」（11 / 600，「装进」次要色）
    var destination: some View {
        HStack(spacing: 5) {
            Text(L("装进", "Into")).foregroundStyle(Theme.textSecondary)
            if let r = model.selectedRepo {
                RepoMarker(repo: r, size: 9)
                Text(r.displayName).lineLimit(1).truncationMode(.tail)
                    .frame(width: TextWidth.capped(r.displayName, size: 13, weight: .semibold, max: 220), alignment: .leading)
            } else {
                RepoMarker(repo: Library().inbox, size: 9)
                Text(L("未归类", "Unsorted"))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.textPrimary)
        .animation(.easeInOut(duration: 0.15), value: model.selection)
    }

    @ViewBuilder func tagView(_ item: TagLayout.Item) -> some View {
        switch item {
        case let .repo(repo, index):
            let isOn = model.selection.selected == repo.id
            // 柔黄：不显示圆点；选中 = 森林绿实底 + 柔黄字，⌘N 同字色（design v1.5 §7.2）
            let butter = Theme.t.butter
            let fg = butter && isOn ? Theme.canvas : Theme.textPrimary
            Button { onTag(repo) } label: {
                HStack(spacing: 5) {
                    if !butter { RepoMarker(repo: repo, size: 9) }
                    Text(repo.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(fg)
                        .lineLimit(1).truncationMode(.tail)
                    if index < 9 {
                        Text("⌘\(index + 1)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(isOn ? fg : Theme.textSecondary)
                            .padding(.leading, 1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .frame(maxWidth: TagLayout.maxTagWidth)
                .background(isOn ? (butter ? Theme.primary : Theme.repoTint(repo)) : Theme.tagCanvas, in: Capsule())
                .overlay(Capsule().stroke(model.flashID == repo.id ? Theme.accent : .clear, lineWidth: 2))
                .animation(.easeInOut(duration: 0.12), value: isOn)
                .animation(.easeInOut(duration: 0.15), value: model.flashID)
            }
            .buttonStyle(.plain)
        case let .overflow(n):
            Button(action: onOverflow) {
                Text(TagLayout.overflowText(n))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Theme.tagCanvas, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(L("输入 @ 搜索项目", "Type @ to search projects"))
        case .trailing:
            if model.creatingRepo { newRepoInput } else { addChip }
        }
    }

    /// 「＋ ⌘N」：无底色、1pt line.soft 内描边、次要色字
    var addChip: some View {
        Button(action: onAdd) {
            HStack(spacing: 5) {
                Text("＋").font(.system(size: 15))
                Text("⌘N").font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10).frame(height: 26)
            .overlay(Capsule().strokeBorder(Theme.lineSoft, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("新建项目 ⌘N", "New Project ⌘N"))
    }

    /// 新建输入胶囊：白底、2pt accent 圈、左侧预览下一个自动分配的颜色
    var newRepoInput: some View {
        HStack(spacing: 6) {
            RepoMarker(repo: Repo(id: "new", folder: "new", shortcode: "", description: "", created: Date(),
                                  colorIndex: model.nextColorIndex, isInbox: false), size: 9)
            TextField(L("新项目名", "New project"), text: Binding(get: { model.newRepoName }, set: { model.newRepoName = $0; model.createError = nil }))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .focused($newNameFocused)
                .onSubmit(onCreate)
                .onExitCommand(perform: onCancelCreate)
        }
        .padding(.horizontal, 10)
        .frame(width: TagLayout.inputWidth(model.newRepoName), height: 26)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().stroke(Theme.accent, lineWidth: 2))
    }
}

struct FooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 把 AppKit 的输入框嵌进 SwiftUI
struct TextViewHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - @ 补全浮层

struct MentionPopupView: View {
    @Bindable var model: CaptureModel
    var onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.popupItems.isEmpty {
                Text(L("没有叫 \(model.popupQuery) 的项目", "No project named “\(model.popupQuery)”"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 12)
            } else {
                ForEach(Array(model.popupItems.prefix(6).enumerated()), id: \.offset) { i, repo in
                    HStack(spacing: 8) {
                        RepoMarker(repo: repo, size: 9)
                        Text(repo.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        if !repo.shortcode.isEmpty {
                            Text("@\(repo.shortcode)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(i == model.popupHighlight ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(i) }
                }
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cardShadow()
        .padding(24)
        .fixedSize()
    }
}

// MARK: - HUD

struct HUDView: View {
    let repo: Repo?
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.primary).frame(width: 20, height: 20)
                Text("✦").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.primaryFg)
            }
            Text(L("已装进", "Tucked into")).foregroundStyle(Theme.textSecondary)
            let name = L("「\(repo?.displayName ?? "未归类")」", repo?.displayName ?? "Unsorted")
            // HUD 最宽 360（design §12.3）：项目名过长截断
            Text(name).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: TextWidth.capped(name, size: 13, weight: .semibold, max: 360 - 32 - 28 - TextWidth.capped(L("已装进", "Tucked into"), size: 13, weight: .semibold, max: 200) - 16))
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Theme.canvas, in: Capsule())
        .cardShadow()
        .padding(30)
        .fixedSize()
    }
}

/// 单行文字宽度（超过 max 截断用）
enum TextWidth {
    static func capped(_ s: String, size: CGFloat, weight: NSFont.Weight, max: CGFloat) -> CGFloat {
        let w = ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width) + 1
        return min(w, max)
    }
}

/// 柔黄主题的线稿小芽（80 × 60），不接收点击
struct ButterSprout: View {
    static let image = NSImage(data: Data(TextureAssets.butterSprout.utf8))
    var body: some View {
        if let img = Self.image {
            Image(nsImage: img).resizable().frame(width: 80, height: 60).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
