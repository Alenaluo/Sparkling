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

    // @ 补全浮层
    var popupItems: [Repo] = []
    var popupQuery: String = ""
    var popupHighlight = 0
    var popupOpen = false

    var selectedRepo: Repo? { selection.selected.flatMap { id in repos.first { $0.id == id } } }
    var targetName: String { selectedRepo?.displayName ?? "未归类" }

    /// tag 布局结果
    var layout: TagLayout { TagLayout.compute(repos: repos) }
    var visibleIDs: [String] { layout.rows.flatMap { $0 }.compactMap { if case let .repo(r, _) = $0 { return r.id }; return nil } }
}

// MARK: - tag 布局（最多两行，溢出时最后一个位置变成「+N · @ 搜索」）

struct TagLayout {
    enum Item: Hashable {
        case repo(Repo, index: Int)
        case overflow(Int)
    }
    var rows: [[Item]]

    /// design v1.0 §2.1：卡片 440 × 380（最小），最高 560
    static let panelWidth: CGFloat = 440
    static let minHeight: CGFloat = 380
    static let maxHeight: CGFloat = 560
    static var available: CGFloat { panelWidth - 40 }
    static let gap: CGFloat = 6
    /// 书写区除文字外占的高度：上下内边距 22 + 22，加输入框与下方留白之间的间距 6
    static let writingChrome: CGFloat = 44 + 6
    static let maxTagWidth: CGFloat = 128

    static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let cmdFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    static func width(of repo: Repo, index: Int) -> CGFloat {
        let nameW = ceil((repo.displayName as NSString).size(withAttributes: [.font: nameFont]).width)
        let cmdW = index < 9 ? 6 + ceil(("⌘\(index + 1)" as NSString).size(withAttributes: [.font: cmdFont]).width) : 0
        return min(maxTagWidth, 10 + 8 + 5 + nameW + cmdW + 10)
    }

    static func overflowWidth(_ n: Int) -> CGFloat {
        20 + ceil(("+\(n) · @ 搜索" as NSString).size(withAttributes: [.font: nameFont]).width)
    }

    static func compute(repos: [Repo], maxRows: Int = 3) -> TagLayout {
        var rows: [[Item]] = [[]]
        var x: CGFloat = 0
        for (i, repo) in repos.enumerated() {
            let w = width(of: repo, index: i)
            if x > 0 && x + gap + w > available {
                if rows.count == maxRows {
                    // 放不下：腾出位置给溢出胶囊
                    let remaining = repos.count - i
                    var last = rows[rows.count - 1]
                    var lastX = last.reduce(CGFloat(0)) { acc, item in
                        if case let .repo(r, idx) = item { return acc + (acc > 0 ? gap : 0) + width(of: r, index: idx) }
                        return acc
                    }
                    var hidden = remaining
                    while !last.isEmpty && lastX + gap + overflowWidth(hidden) > available {
                        if case let .repo(r, idx) = last.removeLast() {
                            lastX -= width(of: r, index: idx) + (last.isEmpty ? 0 : gap)
                            hidden += 1
                        }
                    }
                    last.append(.overflow(hidden))
                    rows[rows.count - 1] = last
                    return TagLayout(rows: rows)
                }
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(.repo(repo, index: i))
            x += (x > 0 ? gap : 0) + w
        }
        return TagLayout(rows: rows)
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

    /// 书写区里文字最多能占的高度：卡片最高 560 减去内边距、底栏、草稿提示
    var maxTextHeight: CGFloat {
        TagLayout.maxHeight - TagLayout.writingChrome - model.footerHeight - (model.draftRestored ? 22 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if model.draftRestored {
                    Text("已恢复未保存的草稿 · ⌘⌫ 清空")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                TextViewHost(view: textView)
                    .frame(height: min(model.textHeight, maxTextHeight))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    }

    @ViewBuilder var footer: some View {
        if let err = model.errorMessage {
            VStack(alignment: .leading, spacing: 4) {
                Text("没存上：\(err)").font(.system(size: 13, weight: .semibold))
                Text("⏎ 重试 · ⌘, 换位置").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Theme.dangerBg)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if model.repos.isEmpty {
                    Button(action: onOpenLibrary) {
                        Text("还没有项目，全部装进未归类 · 去全部灵感里建一个")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(alignment: .leading, spacing: TagLayout.gap) {
                        ForEach(Array(model.layout.rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: TagLayout.gap) {
                                ForEach(row, id: \.self) { item in tagView(item) }
                            }
                        }
                    }
                }
                HStack(spacing: 0) {
                    destination
                    Spacer(minLength: 8)
                    Text("⏎ 保存")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.primaryFg)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Theme.primary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Theme.block)
        }
    }

    /// 底行左侧落点：「装进 ■ X」（11 / 600，「装进」次要色）
    var destination: some View {
        HStack(spacing: 5) {
            Text("装进").foregroundStyle(Theme.textSecondary)
            if let r = model.selectedRepo {
                RepoMarker(repo: r, size: 9)
                Text(r.displayName).lineLimit(1).truncationMode(.tail)
            } else {
                RepoMarker(repo: Library().inbox, size: 9)
                Text("未归类")
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
            Button { onTag(repo) } label: {
                HStack(spacing: 5) {
                    RepoMarker(repo: repo, size: 9)
                    Text(repo.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                    if index < 9 {
                        Text("⌘\(index + 1)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.leading, 1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .frame(maxWidth: TagLayout.maxTagWidth)
                .background(isOn ? Theme.repoTint(repo) : Theme.tagCanvas, in: Capsule())
                .scaleEffect(isOn ? 1 : 1)
                .animation(.easeInOut(duration: 0.12), value: isOn)
            }
            .buttonStyle(.plain)
        case let .overflow(n):
            Button(action: onOverflow) {
                Text("+\(n) · @ 搜索")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Theme.tagCanvas, in: Capsule())
            }
            .buttonStyle(.plain)
        }
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
                Text("没有叫 \(model.popupQuery) 的项目")
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
            Text("已装进").foregroundStyle(Theme.textSecondary)
            Text("「\(repo?.displayName ?? "未归类")」").foregroundStyle(Theme.textPrimary)
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
