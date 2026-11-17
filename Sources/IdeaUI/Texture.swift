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

    /// 平铺块图片；素材里的 #37352F 换成主题正文色
    func image(colorHex: String = "#37352F") -> NSImage? {
        guard let svg else { return nil }
        let key = rawValue + colorHex
        if let img = Self.cache[key] { return img }
        let data = Data(svg.replacingOccurrences(of: "#37352F", with: colorHex).utf8)
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
            if let img = texture.image(colorHex: Theme.textPrimaryHex) {
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
