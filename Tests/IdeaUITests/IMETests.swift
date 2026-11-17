import AppKit
import Foundation
import Testing
@testable import IdeaUI
@testable import IdeaCore

/// tech.md §11.5 A2：输入法组字（marked text）时回车 / Esc / Tab 不触发保存、关窗、切 tag。
@MainActor
@Suite(.serialized) struct IMETests {
    let root: URL
    let capture: CaptureController
    let app: AppModel

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sparkling-ui-\(UUID().uuidString)")
        setenv("SPARKLING_ROOT", root.path, 1)
        app = AppModel()
        _ = try app.store.createRepo(name: "播放器重构", shortcode: "pr", in: app.library)
        app.reload()
        _ = try app.store.createRepo(name: "数据看板", in: app.library)
        app.reload()
        capture = CaptureController(app: app)
        capture.show()
    }

    var inboxCount: Int { (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Inbox").path).filter { $0.hasSuffix(".md") }.count) ?? 0 }
    var tv: IdeaTextView { capture.textView }

    @discardableResult
    func command(_ sel: Selector) -> Bool { capture.textView(tv, doCommandBy: sel) }

    @Test func enterDuringCompositionDoesNotSave() {
        tv.setMarkedText("ling", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(tv.hasMarkedText())
        #expect(command(#selector(NSResponder.insertNewline(_:))) == false) // 交给输入法
        #expect(inboxCount == 0)
        #expect(capture.isVisible)

        tv.insertText("灵", replacementRange: NSRange(location: NSNotFound, length: 0)) // 选词上屏
        #expect(!tv.hasMarkedText())
        #expect(command(#selector(NSResponder.insertNewline(_:))) == true)
        #expect(inboxCount == 1)
        let file = try! FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Inbox"), includingPropertiesForKeys: nil).first { $0.pathExtension == "md" }!
        #expect(try! String(contentsOf: file, encoding: .utf8).hasSuffix("灵\n"))
    }

    @Test func escAndTabDuringComposition() {
        tv.setMarkedText("bo", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(command(#selector(NSResponder.cancelOperation(_:))) == false)
        #expect(capture.isVisible)
        #expect(command(#selector(NSResponder.insertTab(_:))) == false)
        #expect(capture.model.selection.selected == nil)
        // ⌘1 也放行给输入法
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        #expect(capture.handleKeyEquivalent(e) == false)
        #expect(capture.model.selection.selected == nil)
    }

    @Test func tagKeysWithoutComposition() {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19)!
        #expect(capture.handleKeyEquivalent(e))
        #expect(capture.model.selectedRepo?.folder == "数据看板")
        #expect(capture.handleKeyEquivalent(e)) // 再按一次取消
        #expect(capture.model.selection.selected == nil)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(capture.model.selectedRepo?.folder == "播放器重构")
        command(#selector(NSResponder.insertBacktab(_:)))
        #expect(capture.model.selection.selected == nil)
    }

    @Test func mentionConfirmAndSave() {
        tv.insertText("@pr", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(capture.model.popupOpen)
        #expect(capture.model.popupItems.first?.folder == "播放器重构")
        // 组字中回车不确认浮层
        tv.setMarkedText("zi", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(command(#selector(NSResponder.insertNewline(_:))) == false)
        tv.unmarkText()
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.textStorage?.replaceCharacters(in: NSRange(location: 3, length: (tv.string as NSString).length - 3), with: "")
        capture.updatePopup()
        #expect(command(#selector(NSResponder.insertNewline(_:))) == true) // 确认补全
        #expect(capture.model.selectedRepo?.folder == "播放器重构")
        #expect(tv.string == "")
        tv.insertText("字幕字号可调 #交互", replacementRange: NSRange(location: NSNotFound, length: 0))
        command(#selector(NSResponder.insertNewline(_:)))
        let dir = root.appendingPathComponent("播放器重构")
        let file = try! FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.pathExtension == "md" && $0.lastPathComponent != "_repo.md" }!
        #expect(try! String(contentsOf: file, encoding: .utf8).hasSuffix("\n字幕字号可调 #交互\n"))
        // 保存后下一次呼出是全新的未选中状态
        capture.show()
        #expect(capture.model.selection.selected == nil)
        #expect(tv.string == "")
    }

    @Test func emailDoesNotTrigger() {
        tv.insertText("发给 a@b.com", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!capture.model.popupOpen)
    }

    @Test func blindTypeShortcodeSpace() {
        tv.insertText("@pr", replacementRange: NSRange(location: NSNotFound, length: 0))
        // 模拟按空格：走 shouldChangeText 委托
        let allowed = capture.textView(tv, shouldChangeTextIn: NSRange(location: 3, length: 0), replacementString: " ")
        #expect(allowed == false)
        #expect(capture.model.selectedRepo?.folder == "播放器重构")
        #expect(tv.string == "")
    }

    @Test func draftKeepsTextAndTag() {
        tv.insertText("半截想法", replacementRange: NSRange(location: NSNotFound, length: 0))
        capture.model.selection.selected = app.repos[1].id
        command(#selector(NSResponder.cancelOperation(_:)))
        capture.show()
        #expect(tv.string == "半截想法")
        #expect(capture.model.selectedRepo?.folder == "数据看板")
        #expect(capture.model.draftRestored)
    }

    /// 回归：面板曾因 fittingSize 为 0 变成 0×0 窗口，热键生效但看不见
    @Test func panelHasRealSize() {
        // 卡片 440 × 380（外加 40 阴影边距）
        #expect(abs(capture.panel.frame.width - (440 + 80)) < 0.5)
        #expect(abs(capture.panel.frame.height - (380 + 80)) < 0.5)
        let top = capture.panel.frame.maxY
        // 几行字不加高
        tv.insertText("第一行\n第二行\n第三行", replacementRange: NSRange(location: NSNotFound, length: 0))
        capture.updateHeight()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(abs(capture.panel.frame.height - (380 + 80)) < 0.5)
        // 写满后向下长、顶边不动，最高 560
        tv.insertText(String(repeating: "很长的一行字\n", count: 40), replacementRange: NSRange(location: NSNotFound, length: 0))
        capture.updateHeight()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(abs(capture.panel.frame.height - (560 + 80)) < 0.5)
        #expect(abs(capture.panel.frame.maxY - top) < 1)
    }

    @Test func emptySubmitDoesNotSave() {
        tv.insertText("   ", replacementRange: NSRange(location: NSNotFound, length: 0))
        command(#selector(NSResponder.insertNewline(_:)))
        #expect(inboxCount == 0)
        #expect(capture.isVisible)
    }
}

@Suite struct TextureTests {
    @Test func allTexturesLoad() {
        for t in Texture.allCases where t != .none {
            let img = t.image(colorHex: "#123456")
            #expect(img != nil, "\(t.rawValue)")
        }
        #expect(Texture.dots.image()?.size == NSSize(width: 16, height: 16))
        #expect(Texture.wave.image()?.size == NSSize(width: 180, height: 90))
        #expect(Texture.none.image() == nil)
    }
}

@Suite(.serialized) struct PaletteTests {
    @Test func tokensPerPalette() {
        #expect(Palette.allCases.count == 3)
        for p in Palette.allCases { #expect(p.tokens.repoColors.count == 8) }
        #expect(Palette.spotBrown.tokens.sidebarSelected == 0x5B3A2B)
        #expect(Palette.spotBrown.tokens.markerOnSelectedUsesPrimary)
        #expect(Palette.periwinkle.tokens.shapes)
        #expect(!Palette.milkCoffee.tokens.shapes)
    }

    /// 项目颜色存序号，换主题按序号取新色
    @Test func repoColorFollowsIndex() {
        let saved = Theme.current
        defer { Theme.current = saved }
        Theme.current = .periwinkle
        #expect(Theme.t.repoColors[3].0 == 0xEE8FDD)
        Theme.current = .milkCoffee
        #expect(Theme.t.repoColors[3].0 == 0x6FA8DC)
    }

    @Test func copyD15() {
        #expect(Library().inbox.displayName == "未归类")
        #expect(FileNamer.repoNameProblem("未归类") != nil)
        #expect(EmptyCupLoads.ok)
    }
}

enum EmptyCupLoads {
    static var ok: Bool { NSImage(data: Data(TextureAssets.emptyCup.replacingOccurrences(of: "currentColor", with: "#6E6259").utf8)) != nil }
}
