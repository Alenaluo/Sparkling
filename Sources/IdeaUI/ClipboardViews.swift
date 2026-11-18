import AppKit
import SwiftUI
import IdeaCore

// MARK: - 剪贴板面板（design §11.1）

@Observable @MainActor
final class ClipPanelModel {
    var query = ""
    var selectedID: String?
    /// ⌘⌫ 删除时淡出中的条目
    var fadingID: String?
    var palette: Palette = .default
}

enum ClipLayout {
    static let panelWidth: CGFloat = 440
    static let panelHeight: CGFloat = 460
}

struct ClipPanelView: View {
    @Bindable var model: ClipPanelModel
    let clip: ClipboardModel
    let filterField: NSView
    var onCopy: (ClipItem) -> Void
    var onSelect: (ClipItem) -> Void
    var onResume: () -> Void

    var shown: [ClipItem] { clip.filter(model.query) }
    var filtering: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if clip.items.isEmpty && !filtering {
                if !clip.enabled { PausedBanner(onResume: onResume).padding(.horizontal, 16).padding(.top, 16) }
                OpticalCenter { ClipEmptyView() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    filterBox
                    if !clip.enabled { PausedBanner(onResume: onResume) }
                    Text(filtering ? L("找到 \(shown.count) 条", "\(shown.count) found") : L("剪贴板 · 最近 \(clip.items.count) 条", "Clipboard · Last \(clip.items.count)"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
                list
                footer
            }
        }
        .frame(width: ClipLayout.panelWidth, height: ClipLayout.panelHeight)
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .cardShadow()
        .padding(40)
        .fixedSize()
        .id(model.palette)
    }

    var filterBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
            TextViewHost(view: filterField).frame(height: 20)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.block, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder var list: some View {
        if shown.isEmpty {
            VStack(spacing: 6) {
                Text(L("没有找到「\(model.query)」", "No results for “\(model.query)”")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(L("筛选会查文字内容和文件名", "Filter checks text and file names")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { item in
                            ClipRow(item: item, clip: clip, query: model.query, selected: item.id == model.selectedID, large: false)
                                .opacity(model.fadingID == item.id ? 0 : 1)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onCopy(item) } else { onSelect(item) }
                                }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 12)
                .onChange(of: model.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 6) {
            KeyCap("⏎", primary: true); hint(L("复制", "Copy"))
            dot; KeyCap("⌘S"); hint(L("存成灵感", "Save as Idea"))
            dot; KeyCap("⌘⌫"); hint(L("删除", "Delete"))
            Spacer()
            KeyCap("Esc"); hint(L("关闭", "Close"))
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Theme.block)
    }

    var dot: some View { Text("·").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary) }
    func hint(_ s: String) -> some View { Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary) }
}

struct KeyCap: View {
    let label: String
    var primary = false
    init(_ label: String, primary: Bool = false) { self.label = label; self.primary = primary }
    var body: some View {
        Text(label).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(primary ? Theme.primaryFg : Theme.textPrimary)
            .padding(.horizontal, 5).frame(height: 18)
            .background(primary ? Theme.primary : Theme.canvas, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 已暂停提示条：淡黄底 + 6pt 橙点 +「打开」
struct PausedBanner: View {
    var onResume: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.c(0xE08A2E)).frame(width: 6, height: 6)
            Text(L("剪贴板记录已暂停，新的复制不会出现", "Clipboard recording is paused")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.c(0x6B5532))
            Spacer(minLength: 4)
            Button(L("打开", "Resume"), action: onResume).buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(Theme.c(0xFBF1DC), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 空状态光学居中（design v1.5 §5.4）：水平居中，上空 : 下空 = 38 : 62；放不下时贴顶。
struct OpticalCenter: Layout {
    var ratio: CGFloat = 0.38
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? s.width, height: proposal.height ?? s.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        let s = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let top = Self.top(container: bounds.height, content: s.height, ratio: ratio)
        v.place(at: CGPoint(x: bounds.midX, y: bounds.minY + top), anchor: .top, proposal: ProposedViewSize(width: bounds.width, height: s.height))
    }
    static func top(container: CGFloat, content: CGFloat, ratio: CGFloat = 0.38) -> CGFloat { max(0, (container - content) * ratio) }
}

/// 空状态：手绘剪贴板 +「还空着」
struct ClipEmptyView: View {
    /// 剪贴板面板 120，主窗口剪贴板页 160（design §5.4）
    var height: CGFloat = 120
    var body: some View {
        VStack(spacing: 0) {
            EmptyGirl(height: height)
            Spacer().frame(height: 14)
            Text(L("还空着", "Nothing here yet")).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
            Spacer().frame(height: 6)
            Text(L("复制点什么，就会出现在这里", "Copy something and it'll show up here")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// 手绘线稿剪贴板（画法同咖啡杯：圆头粗线、略带抖动），颜色 = text.secondary
struct EmptyClipboardArt: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 64, size.height / 76)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var board = Path()
            board.move(to: p(14, 12))
            board.addCurve(to: p(6, 20), control1: p(9, 12), control2: p(6, 15))
            board.addCurve(to: p(7, 66), control1: p(5.5, 36), control2: p(6.5, 52))
            board.addCurve(to: p(15, 73), control1: p(7.5, 71), control2: p(10, 73))
            board.addCurve(to: p(51, 72), control1: p(27, 73.5), control2: p(40, 73))
            board.addCurve(to: p(58, 64), control1: p(56, 71.5), control2: p(58, 69))
            board.addCurve(to: p(57, 19), control1: p(58.5, 48), control2: p(57.5, 33))
            board.addCurve(to: p(49, 12), control1: p(56.5, 14), control2: p(54, 12))
            var clip = Path()
            clip.move(to: p(21, 15))
            clip.addCurve(to: p(23, 7), control1: p(20.5, 11), control2: p(21, 8))
            clip.addCurve(to: p(28, 6), control1: p(24.5, 6.2), control2: p(26, 6))
            clip.addCurve(to: p(32, 2.5), control1: p(28.5, 3.5), control2: p(30, 2.5))
            clip.addCurve(to: p(36, 6), control1: p(34, 2.5), control2: p(35.5, 3.5))
            clip.addCurve(to: p(41, 7), control1: p(38, 6), control2: p(40, 6.2))
            clip.addCurve(to: p(43, 15), control1: p(43, 8), control2: p(43.5, 11))
            clip.addCurve(to: p(21, 15), control1: p(36, 15.6), control2: p(28, 15.6))
            var lines = Path()
            lines.move(to: p(17, 30)); lines.addCurve(to: p(46, 29.5), control1: p(27, 29.4), control2: p(37, 30.2))
            lines.move(to: p(17, 40)); lines.addCurve(to: p(41, 40.5), control1: p(25, 40.6), control2: p(33, 39.8))
            lines.move(to: p(17, 50)); lines.addCurve(to: p(33, 49.6), control1: p(22, 49.8), control2: p(28, 50.3))
            let style = StrokeStyle(lineWidth: 2.2 * s, lineCap: .round, lineJoin: .round)
            for path in [board, clip, lines] { ctx.stroke(path, with: .color(Theme.textSecondary), style: style) }
            // 右下角一颗小心（呼应咖啡杯上的心）
            var heart = Path()
            heart.move(to: p(47, 58))
            heart.addCurve(to: p(44, 52), control1: p(45, 56.5), control2: p(43, 54.5))
            heart.addCurve(to: p(47, 52.5), control1: p(45, 50.5), control2: p(46.5, 51))
            heart.addCurve(to: p(50, 52), control1: p(47.5, 51), control2: p(49, 50.5))
            heart.addCurve(to: p(47, 58), control1: p(51, 54.5), control2: p(49, 56.5))
            ctx.fill(heart, with: .color(Theme.textSecondary))
        }
        .accessibilityLabel(L("空的剪贴板", "Empty clipboard"))
    }
}

// MARK: - 条目（面板 32 / 主窗口 40）

struct ClipRow: View {
    let item: ClipItem
    let clip: ClipboardModel
    let query: String
    let selected: Bool
    /// 主窗口版：图标 40、上下内边距 10
    let large: Bool

    var iconSize: CGFloat { large ? 40 : 32 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: iconSize, height: iconSize)
            content.frame(maxWidth: .infinity, alignment: .leading)
            Text(ClipTime.label(item.date))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, large ? 10 : 8)
        .padding(.horizontal, 12)
        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder var icon: some View {
        switch item.kind {
        case .text:
            Text(L("文", "Aa")).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.textSecondary)
                .frame(width: iconSize, height: iconSize)
                .background(Theme.block, in: RoundedRectangle(cornerRadius: 7))
        case .image:
            if let img = clip.image(item) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: iconSize, height: iconSize).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.lineSoft, lineWidth: 1))
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.textSecondary)
                    .frame(width: iconSize, height: iconSize).background(Theme.block, in: RoundedRectangle(cornerRadius: 7))
            }
        case .files:
            FileIcon(path: item.paths?.first ?? "", size: iconSize)
        }
    }

    @ViewBuilder var content: some View {
        switch item.kind {
        case .text:
            Text(Highlight.attributed(item.text ?? "", query: query))
                .font(.system(size: 13)).lineSpacing(3)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2).truncationMode(.tail)
        case .image:
            Text(item.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .padding(.top, (iconSize - 18) / 2)
        case .files:
            VStack(alignment: .leading, spacing: 2) {
                Text(Highlight.attributed(item.summary, query: query))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(clip.fileDetail(item)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }
}

/// 文件图标：系统图标，右下角色块写扩展名
struct FileIcon: View {
    let path: String
    let size: CGFloat
    var body: some View {
        let ext = (path as NSString).pathExtension.uppercased()
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable().frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if !ext.isEmpty {
                    Text(String(ext.prefix(4))).font(.system(size: size > 36 ? 8 : 7, weight: .bold)).foregroundStyle(Theme.primaryFg)
                        .padding(.horizontal, 3).frame(height: size > 36 ? 13 : 11)
                        .background(Theme.primary, in: RoundedRectangle(cornerRadius: 3))
                }
            }
    }
}

/// 筛选命中字加 accent 下划线（同主窗口搜索）
enum Highlight {
    static func attributed(_ text: String, query: String) -> AttributedString {
        var a = AttributedString(text)
        for r in ClipFilter.ranges(of: query, in: text) {
            guard let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lo..<hi].underlineStyle = .single
            a[lo..<hi].underlineColor = NSColor(Theme.accent)
        }
        return a
    }
}

// MARK: - ⌘S 存成灵感：记录面板正文上方（design §11.2）

struct ClipAttachmentHeader: View {
    let item: ClipItem
    let image: NSImage?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("来自剪贴板", "From Clipboard")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8).frame(height: 20)
                .background(Theme.block, in: RoundedRectangle(cornerRadius: 6))
            switch item.kind {
            case .text: EmptyView()
            case .image: imageCard
            case .files: fileCard
            }
        }
    }

    var imageCard: some View {
        ImageCard(image: image, sizeText: "\(item.imageWidth ?? 0) × \(item.imageHeight ?? 0)")
    }

    var fileCard: some View {
        FileCard(path: item.paths?.first ?? "", name: item.summary, detail: detail)
    }
}

/// 图片卡片：宽满、最高 150、圆角 12、1pt 内描边，右下角半透明尺寸标（design §11.2；主窗口灵感里的图片同样显示）
struct ImageCard: View {
    let image: NSImage?
    let sizeText: String
    var body: some View {
        let h = CaptureModel.imageCardHeight(image)
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity).frame(height: h).clipped()
            } else {
                Theme.block.frame(height: h)
                    .overlay(Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(Theme.textTertiary))
            }
            if !sizeText.isEmpty {
                Text(sizeText)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                    .padding(8)
            }
        }
        .frame(maxWidth: 392)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.lineSoft, lineWidth: 1))
    }
}

/// 文件卡片：白底、1pt 内描边、圆角 12：图标 40 + 文件名 +「位置 · 大小」
struct FileCard: View {
    let path: String
    let name: String
    let detail: String
    var body: some View {
        HStack(spacing: 12) {
            FileIcon(path: path, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 392)
        .frame(height: 64)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.lineSoft, lineWidth: 1))
    }

    /// 「位置 · 大小」；文件已不在原处时写「找不到原文件」
    static func detail(_ path: String) -> String {
        let dir = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value else { return L("找不到原文件", "Original file not found") }
        return "\(dir) · \(ClipTime.size(size))"
    }
}

/// 主窗口灵感条目里的图片（带缓存，按文件修改时间失效）
@MainActor
enum IdeaImageCache {
    static var cache: [URL: (Date?, NSImage)] = [:]
    static func image(_ url: URL) -> NSImage? {
        let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let c = cache[url], c.0 == m { return c.1 }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache[url] = (m, img)
        return img
    }
    static func pixelSize(_ img: NSImage) -> String {
        guard let rep = img.representations.first, rep.pixelsWide > 0 else { return "" }
        return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
    }
}

// MARK: - 主窗口「剪贴板」页（design §11.3）

struct ClipboardPage: View {
    let clip: ClipboardModel
    var onSaveAsIdea: (ClipItem) -> Void
    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var listFocused: Bool

    var shown: [ClipItem] { clip.filter(query) }
    var groups: [(day: Date, title: String, items: [ClipItem])] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [ClipItem]] = [:]
        for it in shown {
            let d = cal.startOfDay(for: it.date)
            if buckets[d] == nil { order.append(d) }
            buckets[d, default: []].append(it)
        }
        return order.map { ($0, DateGrouping.title(for: $0), buckets[$0]!) }
    }
    var selected: ClipItem? { shown.first { $0.id == selectedID } }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        header.padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 20)
                        if !clip.enabled {
                            PausedBanner(onResume: { clip.enabled = true }).padding(.horizontal, 40).padding(.bottom, 16)
                        }
                        if shown.isEmpty {
                            OpticalCenter { empty }.frame(maxWidth: .infinity).frame(height: max(220, geo.size.height - 76))
                        }
                        ForEach(Array(groups.enumerated()), id: \.element.day) { gi, g in
                            Section {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(g.items) { item in row(item).id(item.id) }
                                }
                                .padding(.horizontal, 28)
                            } header: {
                                Text(g.title)
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
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
                .background(Theme.canvas)
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.upArrow) { step(-1, proxy); return .handled }
                .onKeyPress(.downArrow) { step(1, proxy); return .handled }
                .onKeyPress(.return) { if let s = selected { clip.copy(s); return .handled }; return .ignored }
                .background { shortcuts }
            }
        }
        .onChange(of: query) { _, _ in if selected == nil { selectedID = nil } }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L("剪贴板", "Clipboard")).font(.system(size: 22, weight: .bold)).kerning(-0.22).foregroundStyle(Theme.textPrimary)
            Text(L("最近 \(clip.items.count) 条 · 只存在这台 Mac 上", "Last \(clip.items.count) · stored only on this Mac")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                TextField(L("筛选…", "Filter…"), text: $query).textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
                    .onExitCommand { query = "" }
            }
            .padding(.horizontal, 10).frame(width: 160, height: 28)
            .background(Theme.block, in: RoundedRectangle(cornerRadius: 9))
            Button(clip.enabled ? L("暂停记录", "Pause") : L("继续记录", "Resume")) { clip.enabled.toggle() }
                .buttonStyle(GhostButton())
            // 用户 11-18 要求：清空也放在这里（同偏好设置，二次确认）
            Button(L("清空", "Clear")) { confirmClearClipboard(clip) }
                .buttonStyle(GhostButton(danger: true))
                .disabled(clip.items.isEmpty)
        }
        .frame(minHeight: 28)
    }

    func row(_ item: ClipItem) -> some View {
        let on = item.id == selectedID
        return HStack(alignment: .center, spacing: 0) {
            ClipRow(item: item, clip: clip, query: query, selected: false, large: true)
            if on {
                HStack(spacing: 6) {
                    Button(L("复制 ⏎", "Copy ⏎")) { clip.copy(item) }.buttonStyle(SmallButton())
                    Button(L("存成灵感 ⌘S", "Save as Idea ⌘S")) { onSaveAsIdea(item) }.buttonStyle(SmallButton())
                    Button(L("删除", "Delete")) { delete(item) }.buttonStyle(SmallButton(danger: true))
                }
                .padding(.trailing, 12)
            }
        }
        .background(on ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = item.id; listFocused = true }
    }

    @ViewBuilder var empty: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(spacing: 6) {
                Text(L("没有找到「\(query)」", "No results for “\(query)”")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(L("筛选会查文字内容和文件名", "Filter checks text and file names")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
        } else {
            ClipEmptyView(height: 160)
        }
    }

    /// 页内快捷键：⌘S 存成灵感、⌘⌫ 删除（只在选中条目时生效）
    var shortcuts: some View {
        Group {
            Button("") { if let s = selected { onSaveAsIdea(s) } }.keyboardShortcut("s")
            Button("") { if let s = selected { delete(s) } }.keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
        .disabled(selected == nil)
    }

    func step(_ d: Int, _ proxy: ScrollViewProxy) {
        let ids = groups.flatMap { $0.items.map(\.id) }
        guard !ids.isEmpty else { return }
        let i = selectedID.flatMap { ids.firstIndex(of: $0) } ?? (d > 0 ? -1 : ids.count)
        let next = ids[max(0, min(ids.count - 1, i + d))]
        selectedID = next
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(next, anchor: .center) }
    }

    func delete(_ item: ClipItem) {
        let ids = shown.map(\.id)
        let i = ids.firstIndex(of: item.id) ?? 0
        let next = ids.indices.contains(i + 1) ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil)
        withAnimation(.easeOut(duration: 0.15)) { clip.delete(item) }
        selectedID = next
    }
}

struct SmallButton: ButtonStyle {
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(danger ? Theme.danger : Theme.textPrimary)
            .padding(.horizontal, 10).frame(height: 26)
            .background((danger ? Theme.dangerBg : Theme.canvas).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct GhostButton: ButtonStyle {
    var danger = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(danger ? Theme.danger : Theme.textPrimary)
            .opacity(enabled ? 1 : 0.4)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Theme.hover.opacity(configuration.isPressed ? 1 : 0.001), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.lineSoft, lineWidth: 1))
    }
}

/// 灵感正文开头的图片 / 文件卡片（列表和编辑卡片共用）
struct AttachmentCards: View {
    let att: IdeaAttachments
    let baseDir: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(att.images, id: \.self) { rel in
                let url = baseDir.appendingPathComponent(rel)
                let img = IdeaImageCache.image(url)
                ImageCard(image: img, sizeText: img.map(IdeaImageCache.pixelSize) ?? "")
                    .contentShape(Rectangle())
                    .contextMenu { Button(L("打开图片", "Open Image")) { NSWorkspace.shared.open(url) } }
            }
            ForEach(att.files, id: \.path) { f in
                FileCard(path: f.path, name: f.name, detail: FileCard.detail(f.path))
                    .contextMenu {
                        Button(L("打开文件", "Open File")) { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }
                        Button(L("在 Finder 中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                    }
            }
        }
    }
}

/// 清空剪贴板历史的确认框：默认焦点在「取消」（偏好设置和主窗口剪贴板页共用）
@MainActor
func confirmClearClipboard(_ clip: ClipboardModel) {
    let a = NSAlert()
    a.messageText = L("清空全部 \(clip.items.count) 条剪贴板记录？", "Clear all \(clip.items.count) clipboard \(clip.items.count == 1 ? "item" : "items")?")
    a.informativeText = L("清空后不能找回。灵感不受影响。", "This can't be undone. Your ideas aren't affected.")
    a.addButton(withTitle: L("取消", "Cancel"))
    let clear = a.addButton(withTitle: L("清空", "Clear"))
    clear.hasDestructiveAction = true
    if a.runModal() == .alertSecondButtonReturn { clip.clear() }
}
