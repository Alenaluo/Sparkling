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
                ClipEmptyView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    filterBox
                    if !clip.enabled { PausedBanner(onResume: onResume) }
                    Text(filtering ? "找到 \(shown.count) 条" : "剪贴板 · 最近 \(clip.items.count) 条")
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
                Text("没有找到「\(model.query)」").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("筛选会查文字内容和文件名").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
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
                                .onTapGesture(count: 2) { onCopy(item) }
                                .onTapGesture { onSelect(item) }
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
            KeyCap("⏎", primary: true); hint("复制")
            dot; KeyCap("⌘S"); hint("存成灵感")
            dot; KeyCap("⌘⌫"); hint("删除")
            Spacer()
            KeyCap("Esc"); hint("关闭")
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
            Text("剪贴板记录已暂停，新的复制不会出现").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.c(0x6B5532))
            Spacer(minLength: 4)
            Button("打开", action: onResume).buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(Theme.c(0xFBF1DC), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 空状态：手绘剪贴板 +「还空着」
struct ClipEmptyView: View {
    var body: some View {
        VStack(spacing: 0) {
            EmptyClipboardArt().frame(width: 64, height: 76)
            Spacer().frame(height: 16)
            Text("还空着").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer().frame(height: 6)
            Text("复制点什么，就会出现在这里").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
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
        .accessibilityLabel("空的剪贴板")
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
            Text("文").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.textSecondary)
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
            Text("来自剪贴板").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
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
        let h = CaptureModel.imageCardHeight(image)
        return ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity).frame(height: h).clipped()
            } else {
                Theme.block.frame(height: h)
            }
            Text("\(item.imageWidth ?? 0) × \(item.imageHeight ?? 0)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                .padding(.horizontal, 6).frame(height: 18)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.lineSoft, lineWidth: 1))
    }

    var fileCard: some View {
        HStack(spacing: 12) {
            FileIcon(path: item.paths?.first ?? "", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.summary).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.lineSoft, lineWidth: 1))
    }
}
