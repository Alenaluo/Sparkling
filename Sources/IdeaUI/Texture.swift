import IdeaCore
import AppKit
import SwiftUI

/// 背景底纹（design.md §7.7）：只铺在呼出面板书写区和主窗口列表区的白底上。
public enum Texture: String, CaseIterable, Identifiable, Sendable {
    case dots, wave, grid, ring, none
    public var id: String { rawValue }
    public static let `default` = Texture.dots

    var title: String {
        switch self {
        case .dots: return L("点阵", "Dots")
        case .wave: return L("刺绣波纹", "Stitches")
        case .grid: return L("点状方格", "Dot Grid")
        case .ring: return L("点点圆环", "Dot Rings")
        case .none: return L("无", "None")
        }
    }

    var svg: String? {
        switch self {
        case .dots: return TextureAssets.dots
        case .wave: return TextureAssets.wave
        case .grid: return TextureAssets.grid
        case .ring: return TextureAssets.ring
        case .none: return nil
        }
    }

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    /// 平铺块图片；素材里的 #37352F 换成主题正文色；opacity 非空时统一改透明度（柔黄：白色 37.5%）
    func image(colorHex: String = "#37352F", opacity: Double? = nil) -> NSImage? {
        guard var svg else { return nil }
        let key = rawValue + colorHex + (opacity.map { "\($0)" } ?? "")
        if let img = Self.cache[key] { return img }
        svg = svg.replacingOccurrences(of: "#37352F", with: colorHex)
        if let opacity { svg = svg.replacingOccurrences(of: #"opacity="[0-9.]+""#, with: "opacity=\"\(opacity)\"", options: .regularExpression) }
        let data = Data(svg.utf8)
        guard let img = NSImage(data: data), img.size.width > 0 else { return nil }
        Self.cache[key] = img
        return img
    }

    static func load() -> Texture { UserDefaults.standard.string(forKey: "texture").flatMap(Texture.init(rawValue:)) ?? .default }
}

/// 白底 + 平铺底纹
struct TexturedBackground: View {
    let texture: Texture
    var body: some View {
        ZStack {
            Theme.canvas
            if let img = Theme.t.butter ? texture.image(colorHex: "#FFFFFF", opacity: 0.375) : texture.image(colorHex: Theme.textPrimaryHex) {
                Image(nsImage: img).resizable(resizingMode: .tile)
            }
        }
    }
}

/// 项目为空的空状态：用户手绘咖啡杯，线色 = text.secondary
struct EmptyCup: View {
    var body: some View {
        if let img = NSImage(data: Data(TextureAssets.emptyCup.replacingOccurrences(of: "currentColor", with: Theme.textSecondaryHex).utf8)) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        }
    }
}

/// 空状态插画「女孩低头看空水洼」（design §5.4）：模板图，按 text.secondary 着色；主窗口高 160，剪贴板面板高 120
struct EmptyGirl: View {
    var height: CGFloat = 160
    static let image: NSImage? = {
        guard let d = Data(base64Encoded: EmptyGirlAsset.png), let img = NSImage(data: d) else { return nil }
        img.isTemplate = true
        return img
    }()
    var body: some View {
        if let img = Self.image {
            Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .foregroundStyle(Theme.textSecondary)
                .frame(height: height)
                .accessibilityLabel(L("还空着", "Nothing here yet"))
        }
    }
}
