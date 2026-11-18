import AppKit
import SwiftUI

/// 产品名「Sparkling」后的双四角星（design v1.5 §7.8b）：边长 = 字号 × 0.66，间距 0.08em，底边贴基线再上移 0.02em，颜色跟文字。
/// 只用在界面自己绘制的产品名上；文件夹名、路径、窗口标题、CFBundleName 不加。
enum SparkleMark {
    static let name = "Sparkling"
    static let svg = #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="707 197 150 150" width="150" height="150"><path fill="#000" d="M796 226 C 805.6 276.4, 805.6 276.4, 856 286 C 805.6 295.6, 805.6 295.6, 796 346 C 786.4 295.6, 786.4 295.6, 736 286 C 786.4 276.4, 786.4 276.4, 796 226 Z"/><path fill="#000" d="M733.0 197.8 C 737.032 218.968, 737.032 218.968, 758.2 223.0 C 737.032 227.032, 737.032 227.032, 733.0 248.2 C 728.968 227.032, 728.968 227.032, 707.8 223.0 C 728.968 218.968, 728.968 218.968, 733.0 197.8 Z"/></svg>
"""#
    /// 单色模板图（viewBox 150 × 150）
    static let template: NSImage? = {
        guard let img = NSImage(data: Data(svg.utf8)) else { return nil }
        img.isTemplate = true
        return img
    }()

    static func side(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.66 }
    static func gap(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.08 }
    static func lift(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.02 }

    /// 已着色的星：画布宽 = 间距 + 边长，星靠右，左边留出 0.08em 间距
    static func image(fontSize: CGFloat, color: NSColor) -> NSImage {
        let s = side(fontSize), g = gap(fontSize)
        let img = NSImage(size: NSSize(width: g + s, height: s), flipped: false) { _ in
            guard let t = template else { return false }
            let r = NSRect(x: g, y: 0, width: s, height: s)
            t.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        return img
    }

    /// 把文案里的每个「Sparkling」后面接上星（AppKit：菜单 attributedTitle 用）
    static func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var rest = Substring(text)
        while let r = rest.range(of: name) {
            out.append(NSAttributedString(string: String(rest[..<r.upperBound]), attributes: attrs))
            let a = NSTextAttachment()
            let img = image(fontSize: font.pointSize, color: color)
            a.image = img
            a.bounds = NSRect(x: 0, y: lift(font.pointSize), width: img.size.width, height: img.size.height)
            out.append(NSAttributedString(attachment: a))
            rest = rest[r.upperBound...]
        }
        out.append(NSAttributedString(string: String(rest), attributes: attrs))
        return out
    }

    /// 菜单项：普通 / 高亮两套颜色，在 menu(_:willHighlight:) 里切换
    static func apply(to item: NSMenuItem, highlighted: Bool = false) {
        guard item.title.contains(name) else { return }
        let color: NSColor = !item.isEnabled ? .disabledControlTextColor : (highlighted ? .selectedMenuItemTextColor : .labelColor)
        item.attributedTitle = attributed(item.title, font: .menuFont(ofSize: 0), color: color)
    }
}

/// SwiftUI：文案中的「Sparkling」后接星，颜色跟 foregroundStyle 走（模板图）
struct SparklingText: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        let parts = text.components(separatedBy: SparkleMark.name)
        var t = Text("")
        for (i, p) in parts.enumerated() {
            t = t + Text(p)
            if i < parts.count - 1 {
                t = t + Text(SparkleMark.name)
                if let img = mark { t = t + Text(Image(nsImage: img).renderingMode(.template)).baselineOffset(SparkleMark.lift(size)) }
            }
        }
        return t.font(.system(size: size, weight: weight))
    }

    /// 模板图：左侧透明 0.08em 当间距
    var mark: NSImage? {
        let img = SparkleMark.image(fontSize: size, color: .black)
        img.isTemplate = true
        return img
    }
}
