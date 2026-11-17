import AppKit
import SwiftUI
import IdeaCore

/// 筛选框：无边框、无焦点圈
final class ClipFilterField: NSTextField {
    static func make() -> ClipFilterField {
        let f = ClipFilterField(frame: NSRect(x: 0, y: 0, width: 360, height: 20))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.placeholderString = "输入筛选…"
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.lineBreakMode = .byTruncatingTail
        return f
    }
}

/// v2 剪贴板面板（design §11.1）：全局 ⌥⇧V 呼出，和记录面板同一张卡片、同一位置。
@MainActor
public final class ClipboardController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let clip: ClipboardModel
    let app: AppModel
    let model = ClipPanelModel()
    let panel = FloatingPanel()
    let filterField = ClipFilterField.make()
    var hosting: NSHostingView<ClipPanelView>!

    /// ⌘S：把选中条目交给记录面板（同一位置切换）
    var onSaveAsIdea: (ClipItem) -> Void = { _ in }
    /// 切到记录面板时不当作「点到别处」
    var switching = false

    public init(clip: ClipboardModel, app: AppModel) {
        self.clip = clip
        self.app = app
        super.init()
        filterField.delegate = self
        hosting = NSHostingView(rootView: ClipPanelView(
            model: model, clip: clip, filterField: filterField,
            onCopy: { [weak self] item in self?.select(item.id); self?.copySelected() },
            onSelect: { [weak self] item in self?.select(item.id) },
            onResume: { [weak self] in self?.clip.enabled = true }))
        panel.contentView = hosting
        panel.delegate = self
        panel.keyEquivalentHandler = { [weak self] e in self?.handleKeyEquivalent(e) ?? false }
    }

    public var isVisible: Bool { panel.isVisible }
    public func toggle() { isVisible ? hide() : show() }

    /// 当前筛选后的条目
    var shown: [ClipItem] { clip.filter(model.query) }
    var selected: ClipItem? { shown.first { $0.id == model.selectedID } }

    // MARK: 显示 / 隐藏

    /// selecting：Esc 从记录面板回来时选中原条目，并保留筛选
    public func show(selecting id: String? = nil, keepQuery: Bool = false) {
        if model.palette != app.palette { model.palette = app.palette }
        if !keepQuery { model.query = ""; filterField.stringValue = "" }
        model.fadingID = nil
        let list = shown
        model.selectedID = list.first(where: { $0.id == id })?.id ?? list.first?.id

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = hosting.fittingSize
        let vf = screen.visibleFrame
        // 卡片中心在屏幕高度 45% 处（同记录面板）
        let centerY = vf.maxY - vf.height * 0.45
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        hosting.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        focusFilter()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        log.info("clipboard panel shown items=\(self.clip.items.count)")
    }

    /// 打开即聚焦筛选框（SwiftUI 可能稍后才把它放进窗口，放进来了再聚焦一次）
    func focusFilter() {
        if filterField.window === panel { panel.makeFirstResponder(filterField) }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.filterField.window === self.panel,
                      self.panel.firstResponder !== self.filterField.currentEditor() else { return }
                self.panel.makeFirstResponder(self.filterField)
            }
        }
    }

    public func hide(animated: Bool = true) {
        guard panel.isVisible else { return }
        guard animated else { panel.orderOut(nil); panel.alphaValue = 0; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    public func windowDidResignKey(_ notification: Notification) {
        // 点到别处 = Esc
        if switching { return }
        hide()
    }

    // MARK: 按键

    public func controlTextDidChange(_ obj: Notification) {
        model.query = filterField.stringValue
        let list = shown
        if !list.contains(where: { $0.id == model.selectedID }) { model.selectedID = list.first?.id }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if textView.hasMarkedText() { return false } // 输入法组字中交给输入法
        return handle(NSStringFromSelector(sel))
    }

    /// 返回 true 表示已处理
    @discardableResult
    func handle(_ selector: String) -> Bool {
        switch selector {
        case "moveUp:": move(-1); return true
        case "moveDown:": move(1); return true
        case "insertNewline:", "insertLineBreak:": copySelected(); return true
        case "cancelOperation:": hide(); return true
        default: return false
        }
    }

    func handleKeyEquivalent(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command else { return false }
        if let tv = panel.fieldEditor(false, for: filterField) as? NSTextView, tv.hasMarkedText() { return false }
        if e.keyCode == 51 { deleteSelected(); return true }           // ⌘⌫
        if e.charactersIgnoringModifiers?.lowercased() == "s" { saveSelected(); return true } // ⌘S
        return false
    }

    func select(_ id: String) { model.selectedID = id }

    func move(_ d: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == model.selectedID } ?? 0
        model.selectedID = list[max(0, min(list.count - 1, i + d))].id
    }

    // MARK: 动作

    /// ⏎：复制回剪贴板并关闭；焦点自然回到原 App（面板不激活本 App），不自动粘贴
    func copySelected() {
        guard let item = selected else { NSSound.beep(); return }
        clip.copy(item)
        hide()
    }

    /// ⌘⌫：不确认，150ms 淡出，选中下一条
    func deleteSelected(animated: Bool = true) {
        guard let item = selected else { NSSound.beep(); return }
        let list = shown
        let i = list.firstIndex { $0.id == item.id } ?? 0
        let next = list.indices.contains(i + 1) ? list[i + 1].id : (i > 0 ? list[i - 1].id : nil)
        let finish = { [weak self] in
            guard let self else { return }
            self.clip.delete(item)
            self.model.fadingID = nil
            self.model.selectedID = next
        }
        guard animated else { finish(); return }
        withAnimation(.easeOut(duration: 0.15)) { model.fadingID = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { finish() } }
    }

    /// ⌘S：关掉剪贴板面板，同一位置换成记录面板（正文预填）
    func saveSelected() {
        guard let item = selected else { NSSound.beep(); return }
        // 先让记录面板成为 key，再收起自己：反过来的话，收起的那一刻系统会把键盘焦点还给原 App，
        // 记录面板虽然显示出来却收不到 ⏎（用户 11-18 反馈「无法保存」）
        switching = true
        onSaveAsIdea(item)
        hide(animated: false)
        switching = false
    }
}
