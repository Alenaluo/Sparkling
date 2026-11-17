import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
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

/// 剪贴板面板（§13 V4）与 ⌘S 存成灵感（§13 V5）：在进程内跑真实的 ClipboardController / CaptureController
@MainActor
@Suite(.serialized) struct ClipPanelTests {
    let root: URL
    let app: AppModel
    let pb: NSPasteboard
    let clip: ClipboardModel
    let panel: ClipboardController
    let capture: CaptureController
    let repo: Repo

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sparkling-clipui-\(UUID().uuidString)")
        setenv("SPARKLING_ROOT", root.path, 1)
        app = AppModel()
        repo = try app.store.createRepo(name: "播放器重构", in: app.library)
        app.reload()
        pb = NSPasteboard(name: NSPasteboard.Name("sparkling-test-\(UUID().uuidString)"))
        clip = ClipboardModel(dir: root.appendingPathComponent(".clipboard"), defaults: UserDefaults(suiteName: "sparkling-test-\(UUID().uuidString)")!, pasteboard: pb)
        panel = ClipboardController(clip: clip, app: app)
        capture = CaptureController(app: app)
        capture.clipboard = clip
        panel.onSaveAsIdea = { [capture] item in capture.showPrefilled(item) }
        capture.onClipCancel = { [panel] item in panel.show(selecting: item.id, keepQuery: true) }
    }

    func add(_ s: String) { pb.clearContents(); pb.setString(s, forType: .string); clip.ingest(frontBundleID: nil) }
    func type(_ q: String) {
        panel.filterField.stringValue = q
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }
    var repoDir: URL { root.appendingPathComponent(repo.folder) }
    func mdFiles(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix("_") }
    }

    @Test func showSelectsFirstAndFocusesFilter() async throws {
        add("旧的"); add("新的")
        panel.show()
        try await Task.sleep(for: .milliseconds(100))
        #expect(panel.isVisible)
        #expect(panel.selected?.text == "新的")
        #expect(panel.panel.firstResponder === panel.filterField.currentEditor())
        #expect(panel.hosting.fittingSize.width >= ClipLayout.panelWidth)
        #expect(abs(panel.hosting.fittingSize.height - (ClipLayout.panelHeight + 80)) < 1)
    }

    /// C12：实时筛选；⌘⌫ 删除后不再出现
    @Test func filterAndDelete() async throws {
        add("播放器 想法"); add("数据看板"); add("播放器 bug")
        panel.show()
        type("播放器")
        #expect(panel.shown.count == 2)
        #expect(panel.selected?.text == "播放器 bug")
        panel.handle("moveDown:")
        #expect(panel.selected?.text == "播放器 想法")
        panel.handle("moveDown:") // 到底不越界
        #expect(panel.selected?.text == "播放器 想法")
        panel.deleteSelected(animated: false)
        #expect(panel.shown.map(\.text) == ["播放器 bug"])
        #expect(panel.selected?.text == "播放器 bug")
        type("")
        #expect(clip.items.map(\.text) == ["播放器 bug", "数据看板"])
        // ⌘⌫ 走 keyEquivalent
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        #expect(panel.handleKeyEquivalent(e))
        try await Task.sleep(for: .milliseconds(300))
        #expect(clip.items.count == 1)
    }

    /// C4：⏎ 把选中条目写回剪贴板并关闭
    @Test func enterCopiesAndCloses() async throws {
        add("第一条"); add("第二条")
        panel.show()
        panel.handle("moveDown:")
        panel.handle("insertNewline:")
        #expect(pb.string(forType: .string) == "第一条")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!panel.isVisible)
        panel.show()
        panel.handle("cancelOperation:")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!panel.isVisible)
    }

    /// C5 文字：⌘S 预填正文，选项目 ⏎ 存入
    @Test func saveTextAsIdea() {
        add("一个想法")
        panel.show()
        panel.saveSelected()
        #expect(capture.isVisible)
        #expect(capture.model.clip?.text == "一个想法")
        #expect(capture.textView.string == "一个想法")
        #expect(!capture.model.draftRestored)
        capture.model.selection.toggle(repo.id)
        capture.submit()
        let files = mdFiles(repoDir)
        #expect(files.count == 1)
        let s = try! String(contentsOf: files[0], encoding: .utf8)
        #expect(s.hasSuffix("一个想法\n"))
        #expect(!s.contains("来自剪贴板"))
        #expect(capture.model.clip == nil)
    }

    /// C5 图片：拷进 <项目>/assets/，.md 引用相对路径
    @Test func saveImageAsIdea() throws {
        pb.clearContents(); pb.setData(ClipMonitorTests.png(30, 20), forType: .png); clip.ingest(frontBundleID: nil)
        panel.show()
        panel.saveSelected()
        #expect(capture.model.clip?.kind == .image)
        #expect(capture.textView.string.isEmpty)
        #expect(capture.textView.placeholder == "给这张图写一句…")
        capture.model.selection.toggle(repo.id)
        capture.textView.string = "首页截图"
        capture.submit()
        let files = mdFiles(repoDir)
        #expect(files.count == 1)
        let s = try String(contentsOf: files[0], encoding: .utf8)
        let assets = try FileManager.default.contentsOfDirectory(atPath: repoDir.appendingPathComponent("assets").path)
        #expect(assets.count == 1)
        #expect(s.contains("![](assets/\(assets[0]))\n\n首页截图"))
        #expect(files[0].lastPathComponent.hasSuffix("-首页截图.md"))
        #expect(capture.textView.placeholder == IdeaTextView.defaultPlaceholder)
        // 主窗口数据源里有它，assets 不被当成项目
        #expect(app.library.ideas.contains { $0.url.lastPathComponent == files[0].lastPathComponent })
        app.reload()
        #expect(!app.repos.contains { $0.folder == "assets" })
    }

    /// C5 文件：只写链接，不复制文件；正文可以为空
    @Test func saveFileAsIdea() throws {
        let f = root.appendingPathComponent("资料 v2.pdf")
        try Data([1]).write(to: f)
        pb.clearContents(); pb.writeObjects([f as NSURL]); clip.ingest(frontBundleID: nil)
        panel.show()
        panel.saveSelected()
        #expect(capture.textView.placeholder == "给这个文件写一句…")
        capture.model.selection.toggle(repo.id)
        capture.submit()
        let files = mdFiles(repoDir)
        #expect(files.count == 1)
        let s = try String(contentsOf: files[0], encoding: .utf8)
        #expect(s.contains("[资料 v2.pdf](file://"))
        #expect(s.contains("%E8%B5%84%E6%96%99%20v2.pdf)"))
        let inRepo = try FileManager.default.contentsOfDirectory(atPath: repoDir.path)
        #expect(!inRepo.contains("资料 v2.pdf"))
        #expect(!inRepo.contains("assets"))
    }

    /// Esc 取消转存：回到剪贴板面板、仍选中原条目、筛选保留；原草稿不受影响
    @Test func escReturnsToClipboard() async throws {
        capture.show()
        capture.textView.string = "没写完的草稿"
        capture.hide()
        add("甲"); add("乙"); add("丙")
        panel.show()
        type("乙")
        panel.saveSelected()
        #expect(capture.textView.string == "乙")
        _ = capture.textView(capture.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(panel.isVisible)
        #expect(panel.selected?.text == "乙")
        #expect(panel.model.query == "乙")
        #expect(mdFiles(repoDir).isEmpty)
        #expect(capture.model.clip == nil)
        panel.hide(animated: false)
        capture.show()
        #expect(capture.textView.string == "没写完的草稿")
    }

    /// 空状态 / 已暂停
    @Test func emptyAndPaused() {
        clip.enabled = false
        panel.show()
        #expect(panel.shown.isEmpty)
        panel.handle("insertNewline:") // 没条目：不崩
        #expect(panel.isVisible)
        let v = ClipPanelView(model: panel.model, clip: clip, filterField: panel.filterField, onCopy: { _ in }, onSelect: { _ in }, onResume: { [clip] in clip.enabled = true })
        v.onResume()
        #expect(clip.enabled)
    }
}

/// 主窗口剪贴板页、偏好设置两页（§13 V6）：能排版、不崩；真实点击交给手测
@MainActor
@Suite(.serialized) struct ClipViewsSmokeTests {
    @Test func render() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sparkling-clipviews-\(UUID().uuidString)")
        setenv("SPARKLING_ROOT", root.path, 1)
        let app = AppModel()
        #expect(app.clipboard.store.dir.path == root.appendingPathComponent(".clipboard").path)
        let pb = NSPasteboard(name: NSPasteboard.Name("sparkling-test-\(UUID().uuidString)"))
        let clip = ClipboardModel(dir: root.appendingPathComponent(".c2"), defaults: UserDefaults(suiteName: "sparkling-test-\(UUID().uuidString)")!, pasteboard: pb)
        pb.clearContents(); pb.setString("hello", forType: .string); clip.ingest(frontBundleID: nil)
        let views: [NSView] = [
            NSHostingView(rootView: ClipboardPage(clip: clip, onSaveAsIdea: { _ in }).frame(width: 760, height: 600)),
            NSHostingView(rootView: ClipboardPage(clip: app.clipboard, onSaveAsIdea: { _ in }).frame(width: 760, height: 600)),
            NSHostingView(rootView: ClipboardSettingsPage(model: SettingsModel(), clip: clip)),
            NSHostingView(rootView: ThemedRoot(content: SettingsView(model: SettingsModel())).environment(app)),
            NSHostingView(rootView: ThemedRoot(content: LibraryView(openSettings: {})).environment(app).frame(width: 960, height: 620)),
        ]
        for v in views {
            v.frame = NSRect(x: 0, y: 0, width: 960, height: 620)
            v.layoutSubtreeIfNeeded()
            #expect(v.fittingSize.width > 0)
        }
    }
}
