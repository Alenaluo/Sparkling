import AppKit
import SwiftUI
import IdeaCore

/// 不激活本 App、但能接收键盘输入的浮窗。
final class FloatingPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    var allowsKey = true

    init(contentRect: NSRect = .zero) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let h = keyEquivalentHandler, h(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// 输入框：系统字体 20pt、行高 30pt、无占位时画提示文字。
final class IdeaTextView: NSTextView {
    var placeholder = "Catch every little thing··"
    /// design v1.0：正文 14pt / 行高 22
    static let fontSize: CGFloat = 14
    static let lineHeight: CGFloat = 22

    static func make() -> IdeaTextView {
        let tv = IdeaTextView(frame: NSRect(x: 0, y: 0, width: 392, height: lineHeight))
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = Theme.nsTextPrimary
        tv.insertionPointColor = Theme.nsAccent
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        tv.defaultParagraphStyle = p
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: Theme.nsTextPrimary, .paragraphStyle: p,
                               .baselineOffset: (lineHeight - fontSize) / 2 - 1]
        return tv
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: Self.fontSize), .foregroundColor: Theme.nsTextSecondary]
            (placeholder as NSString).draw(at: NSPoint(x: 0, y: (Self.lineHeight - Self.fontSize) / 2 - 1), withAttributes: attrs)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    var contentHeight: CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return Self.lineHeight }
        lm.ensureLayout(for: tc)
        return max(Self.lineHeight, ceil(lm.usedRect(for: tc).height))
    }
}

/// 呼出面板：热键 → 输入 → 选仓库 → 保存。
@MainActor
public final class CaptureController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let app: AppModel
    let model = CaptureModel()
    let panel = FloatingPanel()
    let popupPanel = FloatingPanel()
    let hudPanel = FloatingPanel()
    let textView = IdeaTextView.make()
    let scrollView = NSScrollView()
    var hosting: NSHostingView<CapturePanelView>!

    var openLibrary: () -> Void = {}
    /// 呼出后很快被别的 App 抢走焦点时回调（多半是热键冲突），参数为抢焦点的 App 名
    var onSuspectedConflict: (String) -> Void = { _ in }
    var frontAppAtShow: NSRunningApplication?
    var shownAt: CFAbsoluteTime = 0
    var openSettings: () -> Void = {}

    /// 草稿（D11：正文 + 选中的 tag）
    var draftText = ""
    var draftSelection = TagSelection()
    var anchorTop: CGFloat = 0
    var dismissedMentionAt: Int?
    var hudTimer: Timer?

    public init(app: AppModel) {
        self.app = app
        super.init()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        textView.delegate = self
        hosting = NSHostingView(rootView: CapturePanelView(
            model: model, textView: scrollView,
            onTag: { [weak self] r in self?.toggleTag(r.id) },
            onOverflow: { [weak self] in self?.insertAt() },
            onOpenLibrary: { [weak self] in self?.hide(); self?.openLibrary() },
            onOpenSettings: { [weak self] in self?.hide(); self?.openSettings() },
            onAdd: { [weak self] in self?.startCreate() },
            onCreate: { [weak self] in self?.commitCreate() },
            onCancelCreate: { [weak self] in self?.cancelCreate() }))
        // 保留默认 sizingOptions：关掉后 fittingSize 为 0，面板会变成 0×0 看不见
        panel.contentView = hosting
        panel.delegate = self
        panel.keyEquivalentHandler = { [weak self] e in self?.handleKeyEquivalent(e) ?? false }

        popupPanel.allowsKey = false
        popupPanel.contentView = NSHostingView(rootView: MentionPopupView(model: model, onPick: { [weak self] i in self?.confirmPopup(index: i) }))
        hudPanel.allowsKey = false
        hudPanel.ignoresMouseEvents = true
    }

    public var isVisible: Bool { panel.isVisible }

    public func toggle() { isVisible ? hide() : show() }

    // MARK: 显示 / 隐藏

    public func show() {
        frontAppAtShow = NSWorkspace.shared.frontmostApplication
        shownAt = CFAbsoluteTimeGetCurrent()
        app.checkRoot()
        model.repos = app.repos
        model.texture = app.texture
        if model.palette != app.palette {
            model.palette = app.palette
            textView.textColor = Theme.nsTextPrimary
            textView.insertionPointColor = Theme.nsAccent
            textView.typingAttributes[.foregroundColor] = Theme.nsTextPrimary
            textView.needsDisplay = true
        }
        model.errorMessage = nil
        model.creatingRepo = false
        model.newRepoName = ""
        model.createError = nil
        model.rootMissing = app.loadError != nil
        // 草稿恢复：正文 + 选择；保存成功后为空、未选
        let restored = !draftText.isEmpty
        model.selection = draftSelection
        if let s = model.selection.selected, !model.repos.contains(where: { $0.id == s }) { model.selection.clear() }
        model.draftRestored = restored
        textView.string = draftText
        textView.undoManager?.removeAllActions()
        closePopup()
        updateHeight()

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = hosting.fittingSize
        let vf = screen.visibleFrame
        // 卡片中心在屏幕高度 45% 处（以最小高 380 计），之后加高时顶边不动、向下长
        anchorTop = vf.maxY - vf.height * 0.45 + TagLayout.minHeight / 2 + 40
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: anchorTop - size.height, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// 关闭并保留草稿（Esc / 失焦）
    public func hide() {
        draftText = textView.string
        draftSelection = model.selection
        closePopup()
        guard panel.isVisible else { return }
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

    public func windowDidBecomeKey(_ notification: Notification) {
        let lag = (CFAbsoluteTimeGetCurrent() - HotkeyCenter.shared.lastFire) * 1000
        if lag < 2000 { log.info("panel key after hotkey: \(Int(lag))ms") }
    }

    public func windowDidResignKey(_ notification: Notification) {
        // 失焦 = Esc：关闭并保留草稿（D9）
        guard panel.isVisible else { return }
        // 刚呼出就被另一个 App 激活抢走焦点：多半是它也注册了同一个快捷键
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            let elapsed = CFAbsoluteTimeGetCurrent() - shownAt
            if elapsed < 1.2, let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != frontAppAtShow?.processIdentifier,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                let name = front.localizedName ?? front.bundleIdentifier ?? "另一个 App"
                log.error("panel lost focus \(Int(elapsed * 1000))ms after show to \(name, privacy: .public)")
                onSuspectedConflict(name)
            }
        }
        hide()
    }

    func relayout() {
        guard panel.isVisible else { return }
        DispatchQueue.main.async { [self] in
            let size = hosting.fittingSize
            var f = panel.frame
            if abs(f.height - size.height) > 0.5 || abs(f.width - size.width) > 0.5 {
                f.origin.y = anchorTop - size.height
                f.origin.x = f.midX - size.width / 2
                f.size = size
                panel.setFrame(f, display: true)
            }
        }
    }

    func updateHeight() {
        let h = textView.contentHeight
        if model.textHeight != h { model.textHeight = h }
        model.isEmpty = textView.string.isEmpty
        let maxText = TagLayout.maxHeight - TagLayout.writingChrome - model.footerHeight - (model.draftRestored ? 22 : 0)
        scrollView.hasVerticalScroller = h > maxText
        if h > maxText { textView.scrollRangeToVisible(textView.selectedRange()) }
        relayout()
    }

    // MARK: 选仓库

    func toggleTag(_ id: String) {
        model.selection.toggle(id)
        model.errorMessage = nil
    }

    func insertAt() {
        panel.makeFirstResponder(textView)
        let r = textView.selectedRange()
        let ns = textView.string as NSString
        let needsSpace = r.location > 0 && !(CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(ns.character(at: r.location - 1)) ?? " "))
        textView.insertText(needsSpace ? " @" : "@", replacementRange: r)
    }

    // MARK: 按键

    func handleKeyEquivalent(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown else { return false }
        // 新建项目输入中：快捷键交给输入框（拷贝粘贴等走编辑菜单）
        if model.creatingRepo { return false }
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) else { return false }
        // 组字中一律放行给输入法
        guard SubmitKeyPolicy.allowsShortcut(hasMarkedText: textView.hasMarkedText()) else { return false }
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, let d = Int(key), (0...9).contains(d) {
            closePopup()
            if d == 0 { model.selection.clear() } else { model.selection.toggle(index: d - 1, in: model.repos.map(\.id)) }
            return true
        }
        if flags == .command {
            switch key {
            case "\u{8}", "\u{7f}": // ⌘⌫ 清空正文（选择不变）
                textView.selectAll(nil); textView.insertText("", replacementRange: textView.selectedRange())
                model.draftRestored = false
                return true
            case "o": hide(); openLibrary(); return true
            case "n": startCreate(); return true
            case ",": hide(); openSettings(); return true
            case "a": textView.selectAll(nil); return true
            case "c": textView.copy(nil); return true
            case "x": textView.cut(nil); return true
            case "v": textView.pasteAsPlainText(nil); return true
            case "z": textView.undoManager?.undo(); return true
            default: return false
            }
        }
        if flags == [.command, .shift], key == "z" { textView.undoManager?.redo(); return true }
        return false
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let cmd = KeyCommand(selector: NSStringFromSelector(commandSelector))
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        let action = SubmitKeyPolicy.action(cmd, shift: shift, hasMarkedText: textView.hasMarkedText(), popupOpen: model.popupOpen)
        log.debug("cmd \(NSStringFromSelector(commandSelector), privacy: .public) marked=\(textView.hasMarkedText()) → \(String(describing: action), privacy: .public)")
        switch action {
        case .passThrough: return false
        case .swallow: return true
        case .submit: submit(); return true
        case .newline: textView.insertNewlineIgnoringFieldEditor(nil); return true
        case .cancel: hide(); return true
        case .nextTag: model.selection.next(visible: model.visibleIDs); return true
        case .prevTag: model.selection.previous(visible: model.visibleIDs); return true
        case .popupUp: movePopup(-1); return true
        case .popupDown: movePopup(1); return true
        case .popupConfirm: confirmPopup(index: model.popupHighlight); return true
        case .popupClose:
            dismissedMentionAt = MentionParser.active(in: textView.string, cursor: textView.selectedRange().location)?.range.location
            closePopup(); return true
        }
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // 盲打：`@短码` 后直接按空格，与短码 / 名称完全相等即等同确认
        if replacementString == " ", !textView.hasMarkedText(), affectedCharRange.length == 0,
           let m = MentionParser.active(in: textView.string, cursor: affectedCharRange.location),
           let repo = RepoMatcher(repos: model.repos).exact(m.query) {
            apply(mention: m, repo: repo)
            return false
        }
        return true
    }

    public func textDidChange(_ notification: Notification) {
        if model.draftRestored && textView.string.isEmpty { model.draftRestored = false }
        updateHeight()
        updatePopup()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        updatePopup()
    }

    // MARK: @ 补全

    func updatePopup() {
        guard panel.isVisible, !textView.hasMarkedText() else {
            // 组字中保持原状（浮层不跟着拼音字母乱跳）
            return
        }
        let cursor = textView.selectedRange()
        guard cursor.length == 0, let m = MentionParser.active(in: textView.string, cursor: cursor.location) else {
            dismissedMentionAt = nil
            closePopup(); return
        }
        if dismissedMentionAt == m.range.location { closePopup(); return }
        let items = RepoMatcher(repos: model.repos).match(m.query)
        if model.popupQuery != m.query || !model.popupOpen { model.popupHighlight = 0 }
        model.popupItems = Array(items.prefix(6))
        model.popupQuery = m.query
        model.popupHighlight = min(model.popupHighlight, max(0, model.popupItems.count - 1))
        model.popupOpen = true
        positionPopup(at: m.range)
    }

    func positionPopup(at range: NSRange) {
        let rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let host = popupPanel.contentView as! NSHostingView<MentionPopupView>
        let size = host.fittingSize
        let origin = NSPoint(x: rect.minX - 24 - 6, y: rect.minY - size.height + 24 - 6)
        popupPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        if popupPanel.parent == nil { panel.addChildWindow(popupPanel, ordered: .above) }
        popupPanel.orderFront(nil)
    }

    func closePopup() {
        model.popupOpen = false
        if popupPanel.parent != nil { panel.removeChildWindow(popupPanel) }
        popupPanel.orderOut(nil)
    }

    func movePopup(_ delta: Int) {
        guard !model.popupItems.isEmpty else { return }
        model.popupHighlight = (model.popupHighlight + delta + model.popupItems.count) % model.popupItems.count
    }

    func confirmPopup(index: Int) {
        guard let m = MentionParser.active(in: textView.string, cursor: textView.selectedRange().location) else { closePopup(); return }
        guard model.popupItems.indices.contains(index) else {
            // 无匹配：关闭浮层、保留文字
            dismissedMentionAt = m.range.location
            closePopup(); return
        }
        apply(mention: m, repo: model.popupItems[index])
    }

    func apply(mention m: Mention, repo: Repo) {
        let result = MentionParser.remove(m, from: textView.string)
        let removeRange = NSRange(location: result.cursor, length: (textView.string as NSString).length - (result.text as NSString).length)
        if textView.shouldChangeText(in: removeRange, replacementString: "") {
            textView.textStorage?.replaceCharacters(in: removeRange, with: "")
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: result.cursor, length: 0))
        model.selection.selected = repo.id
        closePopup()
        updateHeight()
    }

    // MARK: 面板里新建项目（D20）

    /// 进入新建时记下的正文光标与 @ 提及（从「没有叫 xx 的项目」按 ⌘N 时预填 xx，创建后删掉 @xx）
    var createReturnRange = NSRange(location: 0, length: 0)
    var createMention: Mention?

    func startCreate() {
        guard !model.creatingRepo else { return }
        createReturnRange = textView.selectedRange()
        createMention = nil
        var prefill = ""
        if model.popupOpen, model.popupItems.isEmpty,
           let m = MentionParser.active(in: textView.string, cursor: createReturnRange.location) {
            prefill = m.query
            createMention = m
        }
        closePopup()
        model.newRepoName = prefill
        model.createError = nil
        model.creatingRepo = true
        relayout()
    }

    func cancelCreate() {
        endCreate()
        log.info("create repo cancelled")
    }

    /// ⏎：空名 = 取消；重名 = 选中已有项目并高亮；否则创建并选中
    func commitCreate() {
        let name = model.newRepoName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { cancelCreate(); return }
        if let existing = model.repos.first(where: { $0.folder.compare(name, options: .caseInsensitive) == .orderedSame }) {
            model.selection.selected = existing.id
            flash(existing.id)
            endCreate(selected: true)
            log.info("create repo: exists, selected \(existing.folder, privacy: .public)")
            return
        }
        do {
            let repo = try app.store.createRepo(name: name, in: app.library)
            app.reload()
            model.repos = app.repos
            model.selection.selected = repo.id
            endCreate(selected: true)
            log.info("create repo \(repo.folder, privacy: .public)")
        } catch {
            model.createError = error.localizedDescription
        }
    }

    func endCreate(selected: Bool = false) {
        model.creatingRepo = false
        model.newRepoName = ""
        model.createError = nil
        panel.makeFirstResponder(textView)
        if selected, let m = createMention, MentionParser.active(in: textView.string, cursor: m.range.location + m.range.length) == m {
            apply(mention: m, repo: model.selectedRepo!)
        } else if selected {
            // 光标回到正文末尾，再按 ⏎ 即保存
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        } else {
            textView.setSelectedRange(createReturnRange)
        }
        createMention = nil
        relayout()
    }

    func flash(_ id: String) {
        model.flashID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { if self?.model.flashID == id { self?.model.flashID = nil } }
        }
    }

    // MARK: 保存

    func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { shake(); return }
        let repo = model.selectedRepo
        do {
            let idea = try app.store.saveIdea(text, to: repo)
            log.info("saved \(idea.url.lastPathComponent, privacy: .public) → \(repo?.folder ?? "Inbox", privacy: .public)")
            app.didSave(idea)
            draftText = ""
            draftSelection = TagSelection()
            textView.string = ""
            model.selection = TagSelection()
            model.errorMessage = nil
            let frame = panel.frame
            hide()
            showHUD(repo: repo, below: frame)
        } catch {
            log.error("save failed \(error.localizedDescription, privacy: .public)")
            model.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Sparkling 文件夹不可写"
            relayout()
        }
    }

    func shake() {
        let origin = panel.frame.origin
        let offsets: [CGFloat] = [-8, 8, -6, 6, 0]
        for (i, dx) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.032 * Double(i)) { [weak self] in
                self?.panel.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y))
            }
        }
    }

    func showHUD(repo: Repo?, below frame: NSRect) {
        hudPanel.contentView = NSHostingView(rootView: HUDView(repo: repo))
        let size = hudPanel.contentView!.fittingSize
        hudPanel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - 40 - size.height, width: size.width, height: size.height), display: true)
        hudPanel.alphaValue = 0
        hudPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; hudPanel.animator().alphaValue = 1 }
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 2.5 + 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.hudPanel.animator().alphaValue = 0 },
                                                     completionHandler: { MainActor.assumeIsolated { self.hudPanel.orderOut(nil) } })
            }
        }
    }
}
