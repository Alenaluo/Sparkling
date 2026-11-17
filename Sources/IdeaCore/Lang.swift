import Foundation

/// 界面语言（product D24）。启动时解析一次，切换靠重启。
public enum Lang: String, Sendable {
    case zh, en

    /// 偏好设置里的选项：跟随系统 / 中文 / English
    public enum Setting: String, CaseIterable, Sendable {
        case system, zh, en
    }

    static let defaultsKey = "language"

    /// 跟随系统：首选语言是中文（简 / 繁）→ 中文，其余 → English
    public static func resolve(_ setting: Setting, preferred: [String] = Locale.preferredLanguages) -> Lang {
        switch setting {
        case .zh: return .zh
        case .en: return .en
        case .system: return (preferred.first ?? "").lowercased().hasPrefix("zh") ? .zh : .en
        }
    }

    public static func loadSetting(_ d: UserDefaults = .standard) -> Setting {
        d.string(forKey: defaultsKey).flatMap(Setting.init(rawValue:)) ?? .system
    }

    public static func saveSetting(_ s: Setting, _ d: UserDefaults = .standard) { d.set(s.rawValue, forKey: defaultsKey) }

    /// 当前界面语言。环境变量 SPARKLING_LANG=zh/en 可覆盖（测试、开发用）
    nonisolated(unsafe) public static var current: Lang = {
        let info = ProcessInfo.processInfo
        if let e = info.environment["SPARKLING_LANG"], let l = Lang(rawValue: e) { return l }
        // 单测进程默认中文（原有断言按中文写），不受本机系统语言影响；要测英文设 SPARKLING_LANG=en
        if info.processName.contains("swiftpm-testing-helper") || info.processName.hasSuffix("xctest") { return .zh }
        return resolve(loadSetting())
    }()

    public var isEnglish: Bool { self == .en }
}

/// 一句界面文字的中英两版
public func L(_ zh: String, _ en: String, lang: Lang = Lang.current) -> String { lang == .en ? en : zh }

/// 英文单复数（design §12.2）：1 idea / N ideas；0 写 "No ideas"
public enum Plural {
    public static func ideas(_ n: Int, lang: Lang = Lang.current) -> String {
        guard lang == .en else { return "\(n) 条" }
        return n == 0 ? "No ideas" : n == 1 ? "1 idea" : "\(n) ideas"
    }
    public static func items(_ n: Int, lang: Lang = Lang.current) -> String {
        guard lang == .en else { return "\(n) 条" }
        return n == 1 ? "1 item" : "\(n) items"
    }
    public static func files(_ n: Int, lang: Lang = Lang.current) -> String {
        guard lang == .en else { return "\(n) 个文件" }
        return n == 1 ? "1 file" : "\(n) files"
    }
}

/// 名称引号：中文「X」，英文 “X”
public func Q(_ s: String, lang: Lang = Lang.current) -> String { lang == .en ? "“\(s)”" : "「\(s)」" }
