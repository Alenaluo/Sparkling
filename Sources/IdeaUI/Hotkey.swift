import AppKit
import Carbon.HIToolbox
import os

let log = Logger(subsystem: "local.sparkling", category: "app")

/// 一个全局快捷键：Carbon 键码 + Carbon 修饰键掩码。
public struct Hotkey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    /// 默认 ⇧⌥Space：⌥Space 常被 Claude / ChatGPT / Raycast 等占用，⌃⌥Space 是系统「下一个输入法」
    public static let `default` = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(shiftKey | optionKey))
    static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers & Self.modifierMask }

    init?(event: NSEvent) {
        var m: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        // 至少要有 ⌘ / ⌥ / ⌃ 之一
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    public var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let s = special[Int(code)] { return s }
        // 其余按当前键盘布局翻译
        if let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            return data.withUnsafeBytes { raw -> String in
                guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "?" }
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                return len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "?"
            }
        }
        return "?"
    }

    /// 与已启用的系统快捷键（Spotlight、切换输入法等）冲突
    public var conflictsWithSystem: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let arr = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        for item in arr {
            guard (item[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (item[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (item[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { continue }
            if code == keyCode && (mods & Self.modifierMask) == modifiers { return true }
        }
        return false
    }

    /// v2 剪贴板面板默认 ⌥⇧V
    public static let clipboardDefault = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey | optionKey))

    // 持久化
    static let defaultsKey = "hotkey"
    public static func load(_ slot: HotkeySlot = .capture) -> Hotkey {
        guard let d = UserDefaults.standard.data(forKey: slot.defaultsKey), let h = try? JSONDecoder().decode(Hotkey.self, from: d) else { return slot.defaultHotkey }
        return h
    }
    func save(_ slot: HotkeySlot = .capture) { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: slot.defaultsKey) }
}

/// 全局快捷键的用途：1 = 呼出记录面板，2 = 剪贴板面板（v2）
public enum HotkeySlot: UInt32, CaseIterable, Sendable {
    case capture = 1, clipboard = 2
    var defaultsKey: String { self == .capture ? Hotkey.defaultsKey : "clipHotkey" }
    public var defaultHotkey: Hotkey { self == .capture ? .default : .clipboardDefault }
    var other: HotkeySlot { self == .capture ? .clipboard : .capture }
    var title: String { self == .capture ? "呼出快捷键" : "剪贴板快捷键" }
}

/// Carbon 全局热键注册。无需辅助功能权限。
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var refs: [HotkeySlot: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var handlers: [HotkeySlot: () -> Void] = [:]
    private(set) var registered: [HotkeySlot: Hotkey] = [:]

    /// 记录面板（slot 1）
    var onFire: (() -> Void)? { get { handlers[.capture] } set { handlers[.capture] = newValue } }
    var current: Hotkey? { registered[.capture] }
    func current(_ slot: HotkeySlot) -> Hotkey? { registered[slot] }
    func setHandler(_ slot: HotkeySlot, _ f: @escaping () -> Void) { handlers[slot] = f }

    /// 与另一个用途的快捷键相同？（比对已注册的，没注册就比对已保存的）
    static func conflictMessage(_ hk: Hotkey, slot: HotkeySlot, other: Hotkey?) -> String? {
        guard let other, other == hk else { return nil }
        return "\(hk.display) 已用作\(slot.other.title)，请换一个"
    }

    /// 注册；返回 nil 表示成功，否则返回错误说明。
    @discardableResult
    func register(_ hk: Hotkey, slot: HotkeySlot = .capture) -> String? {
        installHandler()
        unregister(slot)
        if let msg = Self.conflictMessage(hk, slot: slot, other: registered[slot.other] ?? Hotkey.load(slot.other)) { return msg }
        if hk.conflictsWithSystem { return "\(hk.display) 已被系统快捷键占用" }
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x53504B4C), id: slot.rawValue) // 'SPKL'
        let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, id, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            log.error("hotkey register failed \(status)")
            return "\(hk.display) 已被其他 App 占用"
        }
        refs[slot] = newRef
        registered[slot] = hk
        log.info("hotkey \(slot.rawValue) registered \(hk.display, privacy: .public)")
        return nil
    }

    func unregister(_ slot: HotkeySlot = .capture) {
        if let ref = refs[slot] { UnregisterEventHotKey(ref) }
        refs[slot] = nil
        registered[slot] = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let t = CFAbsoluteTimeGetCurrent()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let slot = HotkeySlot(rawValue: hkID.id) ?? .capture
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fired(slot, at: t) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    var lastFire: CFAbsoluteTime = 0
    private func fired(_ slot: HotkeySlot, at t: CFAbsoluteTime) {
        lastFire = t
        log.info("hotkey \(slot.rawValue) fired")
        handlers[slot]?()
    }
}
