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
