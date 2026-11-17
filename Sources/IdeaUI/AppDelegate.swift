import AppKit
import SwiftUI
import ServiceManagement
import IdeaCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    public let app = AppModel()
    var capture: CaptureController!
    var statusItem: NSStatusItem!
    var captureItem: NSMenuItem!
    var warningItem: NSMenuItem!
    /// 快捷键问题（注册失败 / 系统占用 / 疑似被别的 App 抢）；非空时菜单栏图标显示警告
    var hotkeyWarning: String? { didSet { updateStatusIcon() } }
    var windows: [String: NSWindow] = [:]
    public let settings = SettingsModel()

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua) // D13 只做浅色
        buildMainMenu()
        buildStatusItem()

        capture = CaptureController(app: app)
        capture.openLibrary = { [weak self] in self?.showLibrary() }
        capture.openSettings = { [weak self] in self?.showSettings() }
        HotkeyCenter.shared.onFire = { [weak self] in self?.capture.toggle() }
        settings.app = app
        settings.onHotkeyChanged = { [weak self] in
            guard let self else { return }
            self.updateCaptureItem()
            self.hotkeyWarning = self.settings.hotkeyError
        }
        capture.onSuspectedConflict = { [weak self] appName in
            guard let self, let hk = HotkeyCenter.shared.current else { return }
            self.hotkeyWarning = "\(hk.display) 可能和「\(appName)」冲突"
        }

        if let err = HotkeyCenter.shared.register(Hotkey.load()) {
            settings.hotkeyError = err
            hotkeyWarning = err
            DispatchQueue.main.async { [weak self] in self?.alertHotkeyFailure(err) }
        }
        updateCaptureItem()
        settings.applyLaunchAtLoginDefault()

        if !UserDefaults.standard.bool(forKey: "onboarded") && ProcessInfo.processInfo.environment["SPARKLING_SKIP_ONBOARDING"] == nil {
            showOnboarding()
        }
        log.info("launched root=\(self.app.root.path, privacy: .public)")
    }

    // MARK: 菜单栏

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Sparkling")
        img?.isTemplate = true
        statusItem.button?.image = img
        let menu = NSMenu()
        warningItem = menu.addItem(withTitle: "", action: #selector(changeHotkeyAction), keyEquivalent: "")
        warningItem.isHidden = true
        captureItem = menu.addItem(withTitle: "记一条灵感…", action: #selector(captureAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开全部灵感…", action: #selector(libraryAction), keyEquivalent: "o")
        menu.addItem(withTitle: "偏好设置…", action: #selector(settingsAction), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Sparkling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        if let w = hotkeyWarning {
            let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "快捷键有问题")
            img?.isTemplate = false
            button.image = img?.withSymbolConfiguration(.init(paletteColors: [Theme.ns(0xC4473C)]))
            button.toolTip = "Sparkling：\(w)，点开菜单修改"
            warningItem.title = "⚠︎ \(w)，点此修改"
            warningItem.isHidden = false
        } else {
            let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Sparkling")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "Sparkling"
            warningItem.isHidden = true
        }
    }

    /// 快捷键有问题时的警告项：打开偏好设置并直接进入快捷键录制（D21：菜单里不再单列「修改快捷键…」）
    @objc func changeHotkeyAction() {
        settings.focusRecorder = true
        showSettings()
    }

    func updateCaptureItem() {
        guard let hk = HotkeyCenter.shared.current else { captureItem?.title = "记一条灵感…"; return }
        captureItem.title = "记一条灵感…\t\(hk.display)"
    }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "Sparkling", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "偏好设置…", action: #selector(settingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Sparkling", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Sparkling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = main.addItem(withTitle: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "记一条灵感…", action: #selector(captureAction), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "重新读取文件夹", action: #selector(reindexAction), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = main.addItem(withTitle: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = main.addItem(withTitle: "窗口", action: nil, keyEquivalent: "")
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m").keyEquivalentModifierMask = [.command, .control]
        winItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }

    @objc func captureAction() { capture.show() }
    @objc func libraryAction() { showLibrary() }
    @objc func settingsAction() { showSettings() }
    @objc func reindexAction() { app.reload() }

    func alertHotkeyFailure(_ msg: String) {
        let a = NSAlert()
        a.messageText = "\(msg)，去设置换一个"
        a.informativeText = "在偏好设置里录一个新的呼出快捷键。也可以从菜单栏图标「记一条灵感…」呼出面板。"
        a.addButton(withTitle: "打开偏好设置")
        a.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { showSettings() }
    }

    // MARK: 窗口

    func present<V: View>(_ key: String, title: String, size: NSSize, minSize: NSSize? = nil, resizable: Bool, @ViewBuilder content: () -> V) {
        if let w = windows[key] {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ThemedRoot(content: content()).environment(app))
        if let minSize { w.contentMinSize = minSize }
        w.setContentSize(size)
        w.center()
        w.delegate = self
        w.backgroundColor = Theme.ns(Theme.t.canvas)
        windows[key] = w
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== w }
        if windows.isEmpty {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    public func showLibrary() {
        app.reload()
        present("library", title: "全部灵感", size: NSSize(width: 960, height: 620), minSize: NSSize(width: 720, height: 480), resizable: true) {
            LibraryView(openSettings: { [weak self] in self?.showSettings() })
        }
    }

    public func showSettings() {
        present("settings", title: "偏好设置", size: NSSize(width: 540, height: 520), resizable: false) {
            SettingsView(model: settings)
        }
    }

    func showOnboarding() {
        present("onboarding", title: "欢迎使用 Sparkling", size: NSSize(width: 560, height: 520), resizable: false) {
            OnboardingView(settings: settings, done: { [weak self] in
                UserDefaults.standard.set(true, forKey: "onboarded")
                self?.windows["onboarding"]?.close()
            })
        }
    }
}
