import Foundation

// MARK: - 拼音

public enum Pinyin {
    /// 音节数组：「夜读 App」→ ["ye", "du", "app"]
    public static func syllables(_ text: String) -> [String] {
        let m = NSMutableString(string: text) as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let s = (m as String).lowercased()
        return s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    public static func full(_ text: String) -> String { syllables(text).joined() }

    public static func initials(_ text: String) -> String {
        String(syllables(text).compactMap { $0.first })
    }

    /// 常见多音字的另一读音首字母（系统按单字转换，「重构」会转成 zhong gou）。
    static let polyphones: [Character: Character] = [
        "重": "c", "行": "h", "长": "z", "调": "d", "乐": "y", "单": "s", "朝": "c", "曾": "z",
        "传": "z", "便": "p", "降": "x", "藏": "z", "盛": "c", "还": "h", "都": "d", "会": "k",
        "说": "s", "率": "l", "术": "z", "解": "x", "教": "j", "参": "s", "差": "c", "大": "d",
    ]

    /// 所有可能的首字母组合（含多音字备选），最多 8 种。
    public static func initialVariants(_ text: String) -> [String] {
        var variants: [String] = [""]
        for ch in text {
            let s = String(ch)
            let base = initials(s)
            guard !base.isEmpty else { continue }
            var next: [String] = variants.map { $0 + base }
            if let alt = polyphones[ch], String(alt) != base, variants.count < 8 {
                next += variants.map { $0 + String(alt) }
            }
            variants = next
        }
        return variants
    }
}

// MARK: - 仓库匹配（@ 补全、移动浮层共用）

public struct RepoMatcher {
    public struct Entry: Equatable {
        public let repo: Repo
        public let rank: Int
    }

    let repos: [Repo]
    let keys: [(full: String, initials: [String], name: String)]

    public init(repos: [Repo]) {
        self.repos = repos
        self.keys = repos.map { (Pinyin.full($0.displayName), Pinyin.initialVariants($0.displayName), $0.displayName.lowercased()) }
    }

    /// 排序：短码完全相等 → 名称前缀 → 拼音首字母前缀 → 拼音全拼前缀 → 包含。空查询返回全部（原顺序）。
    public func match(_ query: String) -> [Repo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return repos }
        var entries: [(Int, Int)] = []
        for (i, repo) in repos.enumerated() {
            let k = keys[i]
            let sc = repo.shortcode.lowercased()
            let rank: Int?
            if !sc.isEmpty && sc == q { rank = 0 }
            else if k.name.hasPrefix(q) { rank = 1 }
            else if k.initials.contains(where: { $0.hasPrefix(q) }) { rank = 2 }
            else if k.full.hasPrefix(q) { rank = 3 }
            else if !sc.isEmpty && sc.hasPrefix(q) { rank = 4 }
            else if k.name.contains(q) || k.full.contains(q) { rank = 5 }
            else { rank = nil }
            if let rank { entries.append((rank, i)) }
        }
        return entries.sorted { $0 < $1 }.map { repos[$0.1] }
    }

    /// 盲打 `@xx␣`：与短码或名称完全相等才算。
    public func exact(_ query: String) -> Repo? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }
        return repos.first { (!$0.shortcode.isEmpty && $0.shortcode.lowercased() == q) || $0.displayName.lowercased() == q }
    }
}

// MARK: - @ 提及解析（UTF-16 偏移，与 NSTextView 一致）

public struct Mention: Equatable {
    /// `@query` 在正文中的范围（含 @）
    public let range: NSRange
    public let query: String
}

public enum MentionParser {
    /// 光标处正在输入的 `@query`。`@` 必须在行首或空白后；query 中不能有空白。
    public static func active(in text: String, cursor: Int) -> Mention? {
        let ns = text as NSString
        guard cursor >= 1, cursor <= ns.length else { return nil }
        var i = cursor - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x40 { // @
                if i > 0 {
                    let prev = ns.character(at: i - 1)
                    guard let scalar = Unicode.Scalar(prev), CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
                }
                let r = NSRange(location: i, length: cursor - i)
                return Mention(range: r, query: ns.substring(with: NSRange(location: i + 1, length: cursor - i - 1)))
            }
            if let scalar = Unicode.Scalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            i -= 1
        }
        return nil
    }

    /// 删除 `@query`（连同其后一个空格），返回新正文与新光标位置。
    public static func remove(_ mention: Mention, from text: String) -> (text: String, cursor: Int) {
        let ns = text as NSString
        var r = mention.range
        let end = r.location + r.length
        if end < ns.length, ns.character(at: end) == 0x20 { r.length += 1 }
        else if r.location > 0, ns.character(at: r.location - 1) == 0x20, end >= ns.length { r.location -= 1; r.length += 1 }
        return (ns.replacingCharacters(in: r, with: ""), r.location)
    }
}

// MARK: - tag 选择

public struct TagSelection: Equatable {
    /// nil = 未选（收件箱）
    public var selected: String?
    public init(selected: String? = nil) { self.selected = selected }

    /// ⌘N / 点击：选第 N 个；已选则取消。
    public mutating func toggle(_ id: String) { selected = (selected == id) ? nil : id }

    public mutating func toggle(index: Int, in ids: [String]) {
        guard ids.indices.contains(index) else { return }
        toggle(ids[index])
    }

    public mutating func clear() { selected = nil }

    /// Tab：收件箱 → tag1 → … → 最后一个可见 tag → 收件箱
    public mutating func next(visible ids: [String]) {
        guard !ids.isEmpty else { selected = nil; return }
        if let s = selected, let i = ids.firstIndex(of: s) {
            selected = i + 1 < ids.count ? ids[i + 1] : nil
        } else { selected = ids[0] }
    }

    public mutating func previous(visible ids: [String]) {
        guard !ids.isEmpty else { selected = nil; return }
        if let s = selected, let i = ids.firstIndex(of: s) {
            selected = i > 0 ? ids[i - 1] : nil
        } else { selected = ids[ids.count - 1] }
    }
}

// MARK: - 按键决策

public enum KeyCommand: Equatable {
    case newline, cancel, tab, backtab, up, down, other
    public init(selector: String) {
        switch selector {
        case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:": self = .newline
        case "cancelOperation:": self = .cancel
        case "insertTab:": self = .tab
        case "insertBacktab:": self = .backtab
        case "moveUp:": self = .up
        case "moveDown:": self = .down
        default: self = .other
        }
    }
}

public enum KeyAction: Equatable {
    case submit, newline, cancel, nextTag, prevTag
    case popupUp, popupDown, popupConfirm, popupClose
    /// 交给 NSTextView 默认处理（含输入法）
    case passThrough
    /// 吃掉，不做任何事（如正文里不允许输入制表符）
    case swallow
}

public enum SubmitKeyPolicy {
    public static func action(_ cmd: KeyCommand, shift: Bool, hasMarkedText: Bool, popupOpen: Bool) -> KeyAction {
        if hasMarkedText { return .passThrough }
        switch cmd {
        case .newline:
            if popupOpen { return .popupConfirm }
            return shift ? .newline : .submit
        case .cancel: return popupOpen ? .popupClose : .cancel
        case .tab: return popupOpen ? .popupConfirm : .nextTag
        case .backtab: return popupOpen ? .popupUp : .prevTag
        case .up: return popupOpen ? .popupUp : .passThrough
        case .down: return popupOpen ? .popupDown : .passThrough
        case .other: return .passThrough
        }
    }

    /// ⌘数字等快捷键：组字中一律放行给输入法。
    public static func allowsShortcut(hasMarkedText: Bool) -> Bool { !hasMarkedText }
}

// MARK: - 搜索

public enum TextSearch {
    public static func search(_ query: String, in ideas: [Idea]) -> [Idea] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = ideas.sorted { $0.created > $1.created }
        guard !q.isEmpty else { return sorted }
        let terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        return sorted.filter { idea in terms.allSatisfy { idea.body.localizedStandardContains($0) } }
    }
}

// MARK: - 编辑卡片退出（product D17）

public enum EditExit: Equatable {
    /// 不用写文件
    case nothing
    /// 把这段正文写回文件
    case write(String)
}

public enum EditExitPolicy {
    /// original = 进入编辑前的正文；onDisk = 文件当前正文（可能已被自动保存改过）；edited = 输入框里的正文。
    /// 正文被清空 → 恢复编辑前内容（若文件已被自动保存改过就写回原文），绝不保存空灵感。
    public static func decide(original: String, onDisk: String, edited: String) -> EditExit {
        if edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return onDisk == original ? .nothing : .write(original)
        }
        return edited == onDisk ? .nothing : .write(edited)
    }

    /// 自动保存：空正文不写
    public static func shouldAutosave(_ edited: String, onDisk: String) -> Bool {
        edited != onDisk && !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
