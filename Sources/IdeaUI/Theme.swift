import AppKit
import SwiftUI
import IdeaCore

/// 3 套可选配色（design.md v1.0 §7.2）。只换颜色和项目标记形状，不做深色模式。
public enum Palette: String, CaseIterable, Identifiable, Sendable {
    case milkCoffee, spotBrown, periwinkle
    public var id: String { rawValue }
    public static let `default` = Palette.milkCoffee

    var title: String {
        switch self {
        case .milkCoffee: return L("奶咖", "Latte")
        case .spotBrown: return L("斑点棕", "Cocoa")
        case .periwinkle: return L("长春花", "Periwinkle")
        }
    }

    struct Tokens {
        let canvas, block, hover, selected, sidebarSelected, onSidebarSelected, lineSoft: UInt32
        let textPrimary, textSecondary, textTertiary, primary, primaryFg, accent: UInt32
        /// 未选 tag 胶囊底（奶咖下用纯白）
        let tagCanvas: UInt32
        /// 项目 8 色：原色 + 选中 tag 浅底
        let repoColors: [(UInt32, UInt32)]
        /// 侧栏选中行的项目标记是否改用 primary（斑点棕深底）
        let markerOnSelectedUsesPrimary: Bool
        let shapes: Bool
    }

    static let leopard: [(UInt32, UInt32)] = [
        (0xB9C84A, 0xEDF1D0), (0x5B3A2B, 0xD4CCC8), (0xE8692A, 0xF9D8C8), (0x6FA8DC, 0xDAE8F6),
        (0xE0808F, 0xF7DEE2), (0xF2A93B, 0xFCE9CC), (0x7D6B66, 0xDDD9D7), (0xC2A98F, 0xEFE9E2),
    ]

    var tokens: Tokens {
        switch self {
        case .milkCoffee:
            return Tokens(canvas: 0xFFFDF9, block: 0xF4EFE7, hover: 0xF4EFE7, selected: 0xF1EBE2, sidebarSelected: 0xE6DCCF,
                          onSidebarSelected: 0x2E2622, lineSoft: 0xE8E1D6, textPrimary: 0x2E2622, textSecondary: 0x6E6259,
                          textTertiary: 0xA89D93, primary: 0xD8E26A, primaryFg: 0x2E2622, accent: 0xE8692A, tagCanvas: 0xFFFFFF,
                          repoColors: Self.leopard, markerOnSelectedUsesPrimary: false, shapes: false)
        case .spotBrown:
            return Tokens(canvas: 0xFFFFFF, block: 0xF8F6F3, hover: 0xF8F6F3, selected: 0xF3EEE9, sidebarSelected: 0x5B3A2B,
                          onSidebarSelected: 0xFBF6EE, lineSoft: 0xECE7E2, textPrimary: 0x2B2420, textSecondary: 0x6B6058,
                          textTertiary: 0xA69C95, primary: 0xD8E26A, primaryFg: 0x2B2420, accent: 0xE8692A, tagCanvas: 0xFFFFFF,
                          repoColors: Self.leopard, markerOnSelectedUsesPrimary: true, shapes: false)
        case .periwinkle:
            return Tokens(canvas: 0xFFFFFF, block: 0xF1F3FE, hover: 0xF1F3FE, selected: 0xEEF1FD, sidebarSelected: 0xDDF28C,
                          onSidebarSelected: 0x1F2233, lineSoft: 0xE3E7F8, textPrimary: 0x1F2233, textSecondary: 0x5B6078,
                          textTertiary: 0x9CA1B8, primary: 0xD4F06A, primaryFg: 0x1F2233, accent: 0x2A47B8, tagCanvas: 0xFFFFFF,
                          repoColors: [(0xC8E65A, 0xF1F8D4), (0x2A47B8, 0xC8CFED), (0x8FA0EE, 0xE2E6FB), (0xEE8FDD, 0xFBE2F6),
                                       (0xD94BC0, 0xF5D0EF), (0x7FD6BC, 0xDEF4EE), (0xF7C948, 0xFDF1CF), (0xF08A5D, 0xFBE1D5)],
                          markerOnSelectedUsesPrimary: false, shapes: true)
        }
    }

    static func load() -> Palette { UserDefaults.standard.string(forKey: "palette").flatMap(Palette.init(rawValue:)) ?? .default }
}

/// 颜色 token：按当前主题取值。切换主题后各窗口根视图用 `.id(palette)` 整体重绘。
public enum Theme {
    nonisolated(unsafe) static var current: Palette = Palette.load()
    static var t: Palette.Tokens { current.tokens }

    static func c(_ hex: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: a)
    }
    static func ns(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    static func hexString(_ hex: UInt32) -> String { String(format: "#%06X", hex) }

    static var canvas: Color { c(t.canvas) }
    static var tagCanvas: Color { c(t.tagCanvas) }
    static var block: Color { c(t.block) }
    static var hover: Color { c(t.hover) }
    static var selected: Color { c(t.selected) }
    static var sidebarSelected: Color { c(t.sidebarSelected) }
    static var onSidebarSelected: Color { c(t.onSidebarSelected) }
    static var lineSoft: Color { c(t.lineSoft) }
    static var textPrimary: Color { c(t.textPrimary) }
    static var textSecondary: Color { c(t.textSecondary) }
    static var textTertiary: Color { c(t.textTertiary) }
    static var primary: Color { c(t.primary) }
    static var primaryFg: Color { c(t.primaryFg) }
    static var accent: Color { c(t.accent) }
    static let success = c(0xA9BF73)
    static let danger = c(0xC4473C)
    static let dangerBg = c(0xF6E7E6)
    static var inbox: Color { c(t.textTertiary) }
    static var shadow: Color { c(t.textPrimary, 0.12) }

    static var nsTextPrimary: NSColor { ns(t.textPrimary) }
    static var nsTextSecondary: NSColor { ns(t.textSecondary) }
    static var nsAccent: NSColor { ns(t.accent) }
    static var textPrimaryHex: String { hexString(t.textPrimary) }
    static var textSecondaryHex: String { hexString(t.textSecondary) }

    /// 项目颜色存的是序号，换主题按序号取新色
    static func repoColor(_ r: Repo) -> Color { r.isInbox ? inbox : c(t.repoColors[max(0, r.colorIndex) % 8].0) }
    static func repoTint(_ r: Repo) -> Color { r.isInbox ? selected : c(t.repoColors[max(0, r.colorIndex) % 8].1) }
}

/// 项目标记：奶咖 / 斑点棕为「豹斑」椭圆（10×8，转 −18°）；长春花按序号用 8 种小形状。未归类为虚线圈。
struct RepoMarker: View {
    let repo: Repo
    var size: CGFloat = 10
    /// 侧栏选中行（斑点棕深底上改用 primary）
    var onSelectedSidebar = false

    var color: Color {
        if onSelectedSidebar && Theme.t.markerOnSelectedUsesPrimary { return Theme.primary }
        return Theme.repoColor(repo)
    }

    var body: some View {
        Group {
            if repo.isInbox {
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.6])).foregroundStyle(Theme.inbox)
                    .frame(width: size, height: size)
            } else if Theme.t.shapes {
                MarkerShape(kind: max(0, repo.colorIndex) % 8).fill(color).frame(width: size, height: size)
            } else {
                Ellipse().fill(color).frame(width: size, height: size * 0.8).rotationEffect(.degrees(-18))
            }
        }
        .frame(width: size, height: size)
    }
}

/// 长春花的 8 种小形状：圆、八边形、胶囊、歪方块、叶子、心、星、团子
struct MarkerShape: Shape {
    let kind: Int
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, cx = r.midX, cy = r.midY
        switch kind {
        case 0: return Path(ellipseIn: r)
        case 1: return polygon(sides: 8, in: r, rotation: .pi / 8)
        case 2: return Path(roundedRect: CGRect(x: r.minX, y: cy - h * 0.3, width: w, height: h * 0.6), cornerRadius: h * 0.3)
        case 3:
            let p = Path(roundedRect: r.insetBy(dx: w * 0.12, dy: w * 0.12), cornerRadius: w * 0.18)
            return p.applying(CGAffineTransform(translationX: -cx, y: -cy).concatenating(.init(rotationAngle: .pi / 12)).concatenating(.init(translationX: cx, y: cy)))
        case 4:
            var p = Path()
            p.move(to: CGPoint(x: r.minX + w * 0.1, y: r.maxY - h * 0.1))
            p.addQuadCurve(to: CGPoint(x: r.maxX - w * 0.05, y: r.minY + h * 0.05), control: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.minX + w * 0.1, y: r.maxY - h * 0.1), control: CGPoint(x: r.maxX, y: r.maxY))
            return p
        case 5:
            var p = Path()
            p.move(to: CGPoint(x: cx, y: r.maxY))
            p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.35), control1: CGPoint(x: cx - w * 0.15, y: r.maxY - h * 0.15), control2: CGPoint(x: r.minX, y: r.minY + h * 0.65))
            p.addArc(center: CGPoint(x: r.minX + w * 0.25, y: r.minY + h * 0.3), radius: w * 0.25, startAngle: .degrees(170), endAngle: .degrees(0), clockwise: false)
            p.addArc(center: CGPoint(x: r.maxX - w * 0.25, y: r.minY + h * 0.3), radius: w * 0.25, startAngle: .degrees(180), endAngle: .degrees(10), clockwise: false)
            p.addCurve(to: CGPoint(x: cx, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.minY + h * 0.65), control2: CGPoint(x: cx + w * 0.15, y: r.maxY - h * 0.15))
            return p
        case 6:
            var p = Path()
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let rad = (i % 2 == 0 ? w / 2 : w / 4.4)
                let pt = CGPoint(x: cx + cos(a) * rad, y: cy + sin(a) * rad)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            return p
        default:
            var p = Path()
            p.addEllipse(in: CGRect(x: r.minX, y: cy - h * 0.1, width: w * 0.62, height: h * 0.6))
            p.addEllipse(in: CGRect(x: r.minX + w * 0.38, y: r.minY + h * 0.05, width: w * 0.62, height: h * 0.6))
            return p
        }
    }

    func polygon(sides: Int, in r: CGRect, rotation: CGFloat) -> Path {
        var p = Path()
        for i in 0..<sides {
            let a = rotation + CGFloat(i) * 2 * .pi / CGFloat(sides)
            let pt = CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

extension View {
    func cardShadow() -> some View { shadow(color: Theme.shadow, radius: 18, x: 0, y: 10) }
}

/// 窗口根视图：主题切换时整体重绘
struct ThemedRoot<Content: View>: View {
    @Environment(AppModel.self) var app
    let content: Content
    var body: some View { content.id(app.palette) }
}

/// 相对时间：今天 10:42 / 昨天 / 11月12日
enum RelTime {
    static func string(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        let en = Lang.current == .en
        f.locale = Locale(identifier: en ? "en_US_POSIX" : "zh_CN")
        if cal.isDateInToday(d) { f.dateFormat = en ? "'Today' HH:mm" : "今天 HH:mm" }
        else if cal.isDateInYesterday(d) { f.dateFormat = en ? "'Yesterday' HH:mm" : "昨天 HH:mm" }
        else if cal.component(.year, from: d) == cal.component(.year, from: now) { f.dateFormat = en ? "MMM d HH:mm" : "M月d日 HH:mm" }
        else { f.dateFormat = en ? "MMM d, yyyy" : "yyyy年M月d日" }
        return f.string(from: d)
    }
}
