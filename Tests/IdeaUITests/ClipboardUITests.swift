import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import IdeaUI
@testable import IdeaCore

/// v2 剪贴板：第二个全局快捷键（tech.md §13 V2）
@MainActor
@Suite struct ClipHotkeyTests {
    @Test func defaultsAndConflict() {
        #expect(HotkeySlot.clipboard.defaultHotkey.display == "⌥⇧V")
        #expect(HotkeySlot.capture.defaultHotkey == .default)
        #expect(HotkeySlot.clipboard.defaultsKey != HotkeySlot.capture.defaultsKey)
        let v = Hotkey.clipboardDefault
        #expect(HotkeyCenter.conflictMessage(v, slot: .capture, other: v) == "⌥⇧V 已用作剪贴板快捷键，请换一个")
        #expect(HotkeyCenter.conflictMessage(v, slot: .clipboard, other: v) == "⌥⇧V 已用作呼出快捷键，请换一个")
        #expect(HotkeyCenter.conflictMessage(v, slot: .clipboard, other: .default) == nil)
    }
}

/// 读剪贴板（tech.md §13 V3；C2 C3 C7 C8 C9 C10 的读取部分）。用私有 NSPasteboard，不碰系统剪贴板。
@MainActor
@Suite(.serialized) struct ClipMonitorTests {
    let dir: URL
    let pb: NSPasteboard
    let defaults: UserDefaults
    let clip: ClipboardModel

    init() {
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sparkling-clip-\(UUID().uuidString)")
        pb = NSPasteboard(name: NSPasteboard.Name("sparkling-test-\(UUID().uuidString)"))
        defaults = UserDefaults(suiteName: "sparkling-test-\(UUID().uuidString)")!
        clip = ClipboardModel(dir: dir, defaults: defaults, pasteboard: pb)
    }

    func copyText(_ s: String, extraType: String? = nil) {
        pb.clearContents()
        pb.setString(s, forType: .string)
        if let t = extraType { pb.setData(Data(), forType: NSPasteboard.PasteboardType(t)) }
    }

    static func png(_ w: Int, _ h: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func textImageFiles() throws {
        copyText("一段文字")
        #expect(clip.ingest(frontBundleID: "com.apple.Safari")?.kind == .text)
        // C2 截图到剪贴板：只有图片类型
        pb.clearContents()
        pb.setData(Self.png(64, 48), forType: .png)
        let img = clip.ingest(frontBundleID: nil)
        #expect(img?.kind == .image && img?.imageWidth == 64 && img?.imageHeight == 48)
        #expect(clip.image(img!) != nil)
        // C3 Finder 复制文件：有文件 URL（也带文件名字符串）→ 记成文件
        let f = dir.deletingLastPathComponent().appendingPathComponent("方案 \(UUID().uuidString.prefix(4)).txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        pb.clearContents()
        pb.writeObjects([f as NSURL])
        pb.setString(f.lastPathComponent, forType: .string)
        let file = clip.ingest(frontBundleID: "com.apple.finder")
        #expect(file?.kind == .files && file?.summary == f.lastPathComponent)
        #expect(clip.items.map(\.kind) == [.files, .image, .text])
    }

    /// C7：相同内容只一条
    @Test func duplicate() {
        copyText("同一段"); clip.ingest(frontBundleID: nil)
        copyText("同一段"); clip.ingest(frontBundleID: nil)
        #expect(clip.items.count == 1)
    }

    /// C8：密码管理器标记的敏感内容不记录；C9：排除名单里的 App 不记录
    @Test func skipsConcealedAndExcluded() {
        copyText("hunter2", extraType: "org.nspasteboard.ConcealedType")
        #expect(clip.ingest(frontBundleID: nil) == nil)
        copyText("一次性", extraType: "org.nspasteboard.TransientType")
        #expect(clip.ingest(frontBundleID: nil) == nil)
        copyText("钥匙串里的密码")
        #expect(clip.ingest(frontBundleID: "com.apple.keychainaccess") == nil)
        clip.excluded.append("com.example.secret")
        copyText("秘密")
        #expect(clip.ingest(frontBundleID: "com.example.secret") == nil)
        #expect(clip.items.isEmpty)
        #expect(defaults.stringArray(forKey: "clipExcluded")?.contains("com.example.secret") == true)
    }

    /// C10：关闭记录后不记录；清空后列表为空且文件夹无残留
    @Test func disabledAndClear() {
        clip.enabled = false
        copyText("关着")
        #expect(clip.ingest(frontBundleID: nil) == nil)
        clip.enabled = true
        copyText("开着"); clip.ingest(frontBundleID: nil)
        pb.clearContents(); pb.setData(Self.png(4, 4), forType: .png); clip.ingest(frontBundleID: nil)
        #expect(clip.items.count == 2)
        clip.clear()
        #expect(clip.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// C6：上限 10，复制 12 次只留 10 条；上限夹在 10–500
    @Test func limit() {
        clip.limit = 10
        for i in 0..<12 { copyText("第 \(i) 条"); clip.ingest(frontBundleID: nil) }
        #expect(clip.items.count == 10)
        #expect(clip.items.first?.text == "第 11 条")
        clip.limit = 3
        #expect(clip.limit == 10)
        clip.limit = 2000
        #expect(clip.limit == 500)
    }

    /// C4 写回部分：⏎ 把条目写回剪贴板
    @Test func copyBack() {
        copyText("第一条"); clip.ingest(frontBundleID: nil)
        copyText("第二条"); clip.ingest(frontBundleID: nil)
        clip.copy(clip.items[1])
        #expect(pb.string(forType: .string) == "第一条")
        // 下次轮询读到同一内容：不重复，提到最前
        clip.ingest(frontBundleID: nil)
        #expect(clip.items.map(\.text) == ["第一条", "第二条"])
    }

    @Test func pollUsesChangeCount() {
        clip.poll()
        #expect(clip.items.isEmpty)
        copyText("新复制")
        clip.poll()
        #expect(clip.items.count == 1)
        clip.poll()
        #expect(clip.items.count == 1)
    }
}
