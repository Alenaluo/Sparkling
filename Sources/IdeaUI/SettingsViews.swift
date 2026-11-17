import AppKit
import SwiftUI
import Observation
import ServiceManagement
import IdeaCore

@Observable @MainActor
public final class SettingsModel {
    var app: AppModel?
    var hotkey = Hotkey.load()
    var hotkeyError: String?
    var recording = false
    var launchAtLogin = false
    var launchError: String?
    var onHotkeyChanged: () -> Void = {}
    /// 打开设置时直接进入快捷键录制
    var focusRecorder = false
    /// v2 剪贴板快捷键（默认 ⌥⇧V）
    var clipHotkey = Hotkey.load(.clipboard)
    var clipHotkeyError: String?
    var recordingClip = false
    var onClipHotkeyChanged: () -> Void = {}

    func hotkey(_ slot: HotkeySlot) -> Hotkey { slot == .capture ? hotkey : clipHotkey }
    func error(_ slot: HotkeySlot) -> String? { slot == .capture ? hotkeyError : clipHotkeyError }
    func isRecording(_ slot: HotkeySlot) -> Bool { slot == .capture ? recording : recordingClip }
    func setRecording(_ slot: HotkeySlot, _ on: Bool) { if slot == .capture { recording = on } else { recordingClip = on } }

    /// 语言设置（重启生效）；启动时实际用的语言是 Lang.current
    var language = Lang.loadSetting()
    /// 实际显示语言会变才提示重启（如系统是中文时「跟随系统」↔「中文」不用重启）
    var languageNeedsRestart: Bool { Lang.resolve(language) != Lang.current }

    func setLanguage(_ s: Lang.Setting) {
        language = s
        Lang.saveSetting(s)
    }

    /// 立即重启：拉起一个新的自己再退出
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    public init() { refreshLaunchState() }

    /// 录到新快捷键：先试注册，失败则恢复旧的并提示（D9）
    func setHotkey(_ hk: Hotkey, slot: HotkeySlot = .capture) {
        let old = HotkeyCenter.shared.current(slot) ?? hotkey(slot)
        let err = HotkeyCenter.shared.register(hk, slot: slot)
        if err != nil { HotkeyCenter.shared.register(old, slot: slot) } else { hk.save(slot) }
        if slot == .capture {
            if err == nil { hotkey = hk }
            hotkeyError = err
            onHotkeyChanged()
        } else {
            if err == nil { clipHotkey = hk }
            clipHotkeyError = err
            onClipHotkeyChanged()
        }
    }

    func refreshLaunchState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
            log.info("launch at login \(on ? "on" : "off") status=\(SMAppService.mainApp.status.rawValue)")
        } catch {
            log.error("launch at login failed \(error.localizedDescription, privacy: .public)")
            launchError = L("设置失败：", "Couldn't change this: ") + error.localizedDescription
        }
        UserDefaults.standard.set(true, forKey: "launchAtLoginChosen")
        refreshLaunchState()
    }

    /// design §8：开机自启默认开。只在从 /Applications 运行、用户没改过时自动打开一次。
    func applyLaunchAtLoginDefault() {
        guard !UserDefaults.standard.bool(forKey: "launchAtLoginChosen"),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        setLaunchAtLogin(true)
    }
}

/// 快捷键录制框
struct HotkeyRecorder: NSViewRepresentable {
    @Bindable var model: SettingsModel
    var slot: HotkeySlot = .capture

    final class RecorderView: NSView {
        var model: SettingsModel!
        var slot: HotkeySlot = .capture
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { model.setRecording(slot, true); HotkeyCenter.shared.unregister(slot); return true }
        override func resignFirstResponder() -> Bool {
            if model.isRecording(slot) { model.setRecording(slot, false); HotkeyCenter.shared.register(model.hotkey(slot), slot: slot) }
            return true
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { window?.makeFirstResponder(nil); return } // Esc 取消
            guard let hk = Hotkey(event: event) else { NSSound.beep(); return }
            model.setRecording(slot, false)
            model.setHotkey(hk, slot: slot)
            window?.makeFirstResponder(nil)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event); return true
        }
    }

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView(); v.model = model; v.slot = slot; return v
    }
    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.model = model
        nsView.slot = slot
        if slot == .capture && model.focusRecorder {
            DispatchQueue.main.async {
                model.focusRecorder = false
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, clipboard
    var id: String { rawValue }
    var title: String { self == .general ? L("通用", "General") : L("剪贴板", "Clipboard") }
    var icon: String { self == .general ? "gearshape" : "doc.on.clipboard" }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Environment(AppModel.self) var app
    @State private var pendingRoot: URL?
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏图标分页（design §11.4）
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { t in
                    let on = tab == t
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 17, weight: .medium))
                        Text(t.title).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                    .frame(width: 72, height: 50)
                    .background(on ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                    .onTapGesture { tab = t }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Theme.block)
            if tab == .general { generalPage } else { ClipboardSettingsPage(model: model, clip: app.clipboard) }
        }
        .frame(width: SettingsLayout.width, alignment: .top)
        .background(Theme.canvas)
        .onChange(of: model.focusRecorder) { _, on in if on { tab = .general } }
        .onAppear { if model.focusRecorder { tab = .general } }
    }

    var generalPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            row(L("语言", "Language")) { languagePicker }
            row(L("配色", "Theme")) { palettePicker }
            row(L("底纹", "Background")) { texturePicker }
            row(L("呼出快捷键", "Capture shortcut")) {
                VStack(alignment: .leading, spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.block)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.recording ? Theme.accent : .clear, lineWidth: 2))
                        Text(model.recording ? L("请按下新的组合键…（Esc 取消）", "Press a new shortcut… (Esc to cancel)") : model.hotkey.display)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(model.recording ? Theme.textSecondary : Theme.textPrimary)
                        HotkeyRecorder(model: model, slot: .capture)
                    }
                    .frame(width: 220, height: 32)
                    if let e = model.hotkeyError {
                        Text(e).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger)
                    } else {
                        Text(L("需包含 ⌘ / ⌥ / ⌃ 之一。若按下没反应，可能被别的 App 占用，请换一个。", "Must include ⌘, ⌥ or ⌃. If nothing happens when you press it, another app may be using it — try another."))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            row(L("存储位置", "Storage location")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(2).textSelection(.enabled)
                    if app.rootIsFromEnv {
                        Text(L("当前由环境变量 SPARKLING_ROOT 指定（开发模式）", "Set by the SPARKLING_ROOT environment variable (developer mode)")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    HStack {
                        Button(L("选择…", "Choose…")) { chooseRoot() }.buttonStyle(SecondaryButton())
                        Button(L("在 Finder 中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([app.root]) }.buttonStyle(SecondaryButton())
                    }
                }
            }
            row(L("开机自启", "Open at login")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                    if let e = model.launchError {
                        Text(e).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: SettingsLayout.width, alignment: .leading)
        .onAppear { model.refreshLaunchState() }
        .confirmationDialog(L("更换存储位置", "Change Storage Location"), isPresented: Binding(get: { pendingRoot != nil }, set: { if !$0 { pendingRoot = nil } })) {
            Button(L("把现有灵感一起搬过去", "Move Everything")) { applyRoot(move: true) }
            Button(L("只换位置", "Just Change Location")) { applyRoot(move: false) }
            Button(L("取消", "Cancel"), role: .cancel) { pendingRoot = nil }
        } message: {
            Text(pendingRoot?.path ?? "")
        }
    }

    func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                .frame(width: SettingsLayout.labelWidth, alignment: .topLeading).padding(.top, 6)
            content()
        }
    }

    /// 语言：跟随系统 / 中文 / English（design §12.1）；切换后提示重启
    var languagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                Text(L("跟随系统", "System")).tag(Lang.Setting.system)
                Text("中文").tag(Lang.Setting.zh)
                Text("English").tag(Lang.Setting.en)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            if model.languageNeedsRestart {
                HStack(spacing: 10) {
                    Text(L("重启 Sparkling 后生效", "Takes effect after restarting Sparkling."))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.c(0x6B5532))
                    Spacer(minLength: 8)
                    Button(L("立即重启", "Restart Now")) { SettingsModel.relaunch() }.buttonStyle(PrimaryButton())
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                .background(Theme.c(0xFBF1DC), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 400)
            }
        }
    }

    /// 3 张缩略图卡片单选，点选立即生效；选中带 2pt 强调色圈 + 右上角 ✓（design §8）
    var palettePicker: some View {
        HStack(spacing: 12) {
            ForEach(Palette.allCases) { p in
                let on = app.palette == p
                VStack(spacing: 4) {
                    PaletteThumb(palette: p)
                        .frame(width: 112, height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lineSoft, lineWidth: 1))
                        .padding(3)
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(on ? Theme.accent : .clear, lineWidth: 2))
                        .overlay(alignment: .topTrailing) {
                            if on {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                                    .foregroundStyle(Theme.accent).background(Circle().fill(.white)).offset(x: 4, y: -4)
                            }
                        }
                    Text(p.title).font(.system(size: 11, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { app.palette = p }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(L("配色：", "Theme: ") + p.title)
            }
        }
    }

    /// 5 个 64×46 小方块单选，点选立即生效；选中带 2pt 强调色圈（design §8）
    var texturePicker: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Texture.allCases) { t in
                let on = app.texture == t
                VStack(spacing: 4) {
                    TexturedBackground(texture: t)
                        .frame(width: 64, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lineSoft, lineWidth: 1))
                        .padding(3)
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(on ? Theme.accent : .clear, lineWidth: 2))
                    Text(t.title).font(.system(size: 11, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { app.texture = t }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(L("底纹：", "Background: ") + t.title)
            }
        }
    }

    func chooseRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = L("选择", "Choose")
        p.directoryURL = app.root.deletingLastPathComponent()
        if p.runModal() == .OK, let url = p.url, url.standardizedFileURL != app.root { pendingRoot = url }
    }

    func applyRoot(move: Bool) {
        guard let url = pendingRoot else { return }
        pendingRoot = nil
        do {
            let skipped = try app.setRoot(url, moveExisting: move)
            if !skipped.isEmpty {
                let a = NSAlert(); a.messageText = L("有 \(skipped.count) 项没能搬走", "\(skipped.count) \(skipped.count == 1 ? "item" : "items") couldn't be moved"); a.informativeText = skipped.prefix(10).joined(separator: "\n"); a.runModal()
            }
        } catch {
            let a = NSAlert(); a.messageText = L("换位置失败", "Couldn't change location"); a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}

// MARK: - 按钮样式（无描边，撞色浅底）

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primaryFg)
            .padding(.horizontal, 14).frame(minWidth: 72).frame(height: 32)
            .background(Theme.primary.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).frame(minWidth: 72).frame(height: 32)
            .background(Theme.selected.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct DangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.danger)
            .padding(.horizontal, 14).frame(minWidth: 72).frame(height: 32)
            .background(Theme.dangerBg.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: - 首次启动引导

struct OnboardingView: View {
    @Bindable var settings: SettingsModel
    @Environment(AppModel.self) var app
    var done: () -> Void
    @State private var names = ["", "", ""]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Sparkling Lab").font(.system(size: 10, weight: .semibold)).kerning(0.8)
                Spacer()
                Text(L("灵感研究所", "IDEA LAB")).font(.system(size: 10, weight: .semibold)).kerning(0.8)
            }.foregroundStyle(Theme.textTertiary)

            Text(L("随时记下灵感，顺手放进对的项目", "Jot anything down — and drop it in the right project")).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.textPrimary)

            step(1, L("灵感存在哪", "Where your ideas live")) {
                HStack {
                    Text(app.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    Button(L("换位置…", "Change…")) {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { try? app.setRoot(u, moveExisting: false) }
                    }.buttonStyle(SecondaryButton())
                }
            }
            step(2, L("建 1–3 个项目（只填名称，可跳过）", "Create 1–3 projects (just a name, optional)")) {
                VStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        TextField(L("项目名称，如「播放器重构」", "Project name, e.g. “Checkout Revamp”"), text: $names[i])
                            .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(Theme.block, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let error { Text(error).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            step(3, L("按 \(settings.hotkey.display) 试记一条", "Press \(settings.hotkey.display) and jot one down")) {
                Text(L("在任何 App 里按下快捷键，输入后回车。没选项目就装进未归类。", "Press the shortcut in any app, write a line, hit ⏎. Without a project it goes to Unsorted."))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Since 2026").font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button(L("跳过", "Skip")) { done() }.buttonStyle(SecondaryButton())
                Button(L("开始使用", "Get Started")) { finish() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560, height: 520)
        .background(Theme.canvas)
    }

    func step<C: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(n)").font(.system(size: 13, weight: .bold).monospacedDigit())
                    .frame(width: 22, height: 22).background(Theme.primary, in: Circle())
                Text(title).font(.system(size: 15, weight: .semibold))
            }.foregroundStyle(Theme.textPrimary)
            content().padding(.leading, 30)
        }
    }

    func finish() {
        for n in names.map({ $0.trimmingCharacters(in: .whitespaces) }) where !n.isEmpty {
            do { try app.store.createRepo(name: n, in: app.library); app.reload() }
            catch { self.error = Q(n) + L("：", ": ") + error.localizedDescription; return }
        }
        done()
    }
}

/// 配色缩略图：侧栏（含选中行）+ 列表区 + 三个项目标记，全部用该主题自己的色值
struct PaletteThumb: View {
    let palette: Palette
    var body: some View {
        let t = palette.tokens
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.c(t.sidebarSelected)).frame(height: 10)
                    .overlay(alignment: .leading) { mark(0, t, selected: true).padding(.leading, 4) }
                ForEach(1..<4, id: \.self) { i in
                    HStack(spacing: 4) { mark(i, t, selected: false); RoundedRectangle(cornerRadius: 1).fill(Theme.c(t.textTertiary)).frame(width: 14, height: 2) }
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: 42)
            .background(Theme.c(t.block))
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.c(t.textPrimary)).frame(width: 26, height: 3)
                RoundedRectangle(cornerRadius: 1).fill(Theme.c(t.textSecondary)).frame(width: 46, height: 2)
                RoundedRectangle(cornerRadius: 1).fill(Theme.c(t.textSecondary)).frame(width: 38, height: 2)
                HStack(spacing: 4) {
                    Capsule().fill(Theme.c(t.primary)).frame(width: 18, height: 8)
                    Capsule().fill(Theme.c(t.accent)).frame(width: 8, height: 8)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.c(t.canvas))
        }
    }

    @ViewBuilder func mark(_ i: Int, _ t: Palette.Tokens, selected: Bool) -> some View {
        let color = Theme.c(selected && t.markerOnSelectedUsesPrimary ? t.primary : t.repoColors[i].0)
        if t.shapes { MarkerShape(kind: i).fill(color).frame(width: 6, height: 6) }
        else { Ellipse().fill(color).frame(width: 6, height: 5).rotationEffect(.degrees(-18)) }
    }
}

// MARK: - 偏好设置 · 剪贴板（design §11.4）

struct ClipboardSettingsPage: View {
    @Bindable var model: SettingsModel
    @Bindable var clip: ClipboardModel
    @State private var selectedApp: String?
    @State private var limitText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row(L("记录剪贴板", "Record clipboard")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("", isOn: $clip.enabled).toggleStyle(.switch).labelsHidden()
                    note(L("只存在这台 Mac 上，不上传；密码管理器等标记为敏感的内容一律跳过", "Stays on this Mac, never uploaded. Items marked sensitive (like passwords) are always skipped."))
                }
            }
            row(L("保存条数", "Keep last")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        stepButton("minus") { setLimit(clip.limit - ClipboardStore.limitStep) }
                        TextField("", text: $limitText)
                            .textFieldStyle(.plain).multilineTextAlignment(.center)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .frame(width: 52, height: 28)
                            .onSubmit { commitLimitText() }
                        stepButton("plus") { setLimit(clip.limit + ClipboardStore.limitStep) }
                    }
                    .background(Theme.block, in: RoundedRectangle(cornerRadius: 9))
                    note(L("超过就自动删最早的（10–500）", "items (10–500) · Older items are removed automatically"))
                }
            }
            row(L("剪贴板快捷键", "Clipboard shortcut")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(Theme.block)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.recordingClip ? Theme.accent : (model.clipHotkeyError != nil ? Theme.danger : .clear), lineWidth: 2))
                            Text(model.recordingClip ? L("请按下新的组合键…（Esc 取消）", "Press a new shortcut… (Esc to cancel)") : model.clipHotkey.display)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(model.recordingClip ? Theme.textSecondary : Theme.textPrimary)
                            HotkeyRecorder(model: model, slot: .clipboard)
                        }
                        .frame(width: 220, height: 32)
                        Button(L("恢复默认", "Reset")) { model.setHotkey(HotkeySlot.clipboard.defaultHotkey, slot: .clipboard) }
                            .buttonStyle(SecondaryButton())
                            .disabled(model.clipHotkey == HotkeySlot.clipboard.defaultHotkey && model.clipHotkeyError == nil)
                    }
                    if let e = model.clipHotkeyError {
                        Text(e).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger)
                    } else {
                        note(L("呼出剪贴板面板。不能和呼出快捷键相同。", "Opens the clipboard panel. Must differ from the capture shortcut."))
                    }
                }
            }
            row(L("不记录这些 App", "Don't record these apps")) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(clip.excluded, id: \.self) { b in
                                HStack(spacing: 8) {
                                    if let icon = ClipboardModel.appIcon(b) {
                                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                    } else {
                                        Image(systemName: "app").font(.system(size: 13)).frame(width: 16, height: 16).foregroundStyle(Theme.textSecondary)
                                    }
                                    Text(ClipboardModel.appName(b)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(selectedApp == b ? Theme.selected : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedApp = b }
                            }
                        }
                    }
                    .frame(height: 100)
                    Divider()
                    HStack(spacing: 0) {
                        Button { addApp() } label: { Image(systemName: "plus").frame(width: 28, height: 24) }.buttonStyle(.plain)
                        Divider().frame(height: 14)
                        Button { removeApp() } label: { Image(systemName: "minus").frame(width: 28, height: 24) }.buttonStyle(.plain)
                            .disabled(selectedApp == nil)
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
                .frame(width: 300)
                .background(Theme.canvas)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.lineSoft, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            row(L("清空历史", "Clear history")) {
                Button(L("清空剪贴板历史…", "Clear Clipboard History…")) { confirmClear() }.buttonStyle(DangerButton())
                    .disabled(clip.items.isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: SettingsLayout.width, alignment: .leading)
        .onAppear { limitText = "\(clip.limit)" }
        .onChange(of: clip.limit) { _, n in limitText = "\(n)" }
    }

    func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                .frame(width: SettingsLayout.labelWidth, alignment: .topLeading).padding(.top, 6)
            content()
        }
    }

    func note(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Theme.textPrimary)
    }

    /// 调小时立即删多出的旧条目（ClipboardModel.limit 的 didSet 里裁剪）
    func setLimit(_ n: Int) {
        let stepped = Int((Double(n) / Double(ClipboardStore.limitStep)).rounded()) * ClipboardStore.limitStep
        clip.limit = ClipboardStore.clampLimit(stepped)
        limitText = "\(clip.limit)"
    }

    func commitLimitText() {
        guard let n = Int(limitText.trimmingCharacters(in: .whitespaces)) else { limitText = "\(clip.limit)"; return }
        clip.limit = ClipboardStore.clampLimit(n)
        limitText = "\(clip.limit)"
    }

    func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        p.prompt = L("不记录", "Don't Record")
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            guard let b = Bundle(url: u)?.bundleIdentifier, !clip.excluded.contains(b) else { continue }
            clip.excluded.append(b)
        }
    }

    func removeApp() {
        guard let b = selectedApp else { return }
        clip.excluded.removeAll { $0 == b }
        selectedApp = nil
    }

    func confirmClear() { confirmClearClipboard(clip) }
}

/// 偏好设置尺寸（design §12.3：中英共用，宽 600、标签列 150、标签可换两行）
enum SettingsLayout {
    static let width: CGFloat = 600
    static let labelWidth: CGFloat = 150
}
