// 由 docs/idea-notes/assets/brand/app-icon-noshadow.svg 生成 Resources/AppIcon.icns（design v1.5 §7.8）。
// 用法（在 idea-notes/ 下）：swift scripts/make-icon.swift ../docs/idea-notes/assets/brand/app-icon-noshadow.svg < /dev/null
// 投影按 app-icon.svg 的参数自己画（dy 12、模糊 14、黑 18%，1024 网格），不依赖 SVG 滤镜支持。
import AppKit

let args = CommandLine.arguments
guard args.count > 1, let svg = NSImage(contentsOfFile: args[1]) else { print("读不到 SVG"); exit(1) }
let iconset = "build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px) / 1024
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.set()
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
print("ok \(iconset)")
