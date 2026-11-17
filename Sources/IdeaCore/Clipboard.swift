import Foundation
import CryptoKit

// MARK: - 剪贴板历史（v2，product D22 / §10，design §11）
// 只在本机保存；不记录、不保存来源 App（D23④）。

public enum ClipKind: String, Codable, Sendable {
    case text, image, files
}

public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var date: Date
    public var kind: ClipKind
    /// 文字条目的原文
    public var text: String?
    /// 图片条目：存储目录里的文件名（img/<id>.png）
    public var imageFile: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    /// 文件条目：绝对路径
    public var paths: [String]?
    /// 内容指纹，用于去重
    public var fingerprint: String

    public var fileNames: [String] { (paths ?? []).map { ($0 as NSString).lastPathComponent } }

    /// 面板里的一行摘要（文件名、截图尺寸、原文）
    public var summary: String {
        switch kind {
        case .text: return text ?? ""
        case .image: return "截图 · \(imageWidth ?? 0) × \(imageHeight ?? 0)"
        case .files:
            let names = fileNames
            if names.count <= 1 { return names.first ?? "" }
            let shown = names.prefix(2).joined(separator: "、")
            return "\(names.count) 个文件：\(shown)\(names.count > 2 ? "…" : "")"
        }
    }

    /// 筛选用的文本：文字内容 + 文件名
    var searchable: String {
        switch kind {
        case .text: return text ?? ""
        case .image: return ""
        case .files: return fileNames.joined(separator: "\n")
        }
    }
}

public struct ClipIndex: Codable {
    public var version = 1
    public var items: [ClipItem] = []
}

/// 剪贴板历史的存储：`<dir>/index.json` + `<dir>/img/*.png`。items 按时间倒序。
public final class ClipboardStore {
    public static let defaultLimit = 50
    public static let limitRange = 10...500
    public static let limitStep = 10

    public let dir: URL
    public private(set) var items: [ClipItem] = []
    public private(set) var limit: Int
    let fm = FileManager.default

    public init(dir: URL, limit: Int = ClipboardStore.defaultLimit) {
        self.dir = dir
        self.limit = Self.clampLimit(limit)
        load()
    }

    public static func clampLimit(_ n: Int) -> Int { min(max(n, limitRange.lowerBound), limitRange.upperBound) }

    /// 默认位置：未设 SPARKLING_ROOT 时放 Application Support（不进可能被同步的灵感根目录）；设了就放 `<根>/.clipboard`（测试隔离）。
    public static func defaultDir(root: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let d = env["SPARKLING_CLIPBOARD_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        if let r = env["SPARKLING_ROOT"], !r.isEmpty { return root.appendingPathComponent(".clipboard", isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sparkling/clipboard", isDirectory: true)
    }

    var indexURL: URL { dir.appendingPathComponent("index.json") }
    var imageDir: URL { dir.appendingPathComponent("img", isDirectory: true) }
    public func imageURL(_ item: ClipItem) -> URL? { item.imageFile.map { imageDir.appendingPathComponent($0) } }

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { items = []; return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        items = ((try? dec.decode(ClipIndex.self, from: data))?.items ?? []).sorted { $0.date > $1.date }
    }

    func persist() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(ClipIndex(items: items)) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: 增

    @discardableResult
    public func addText(_ text: String, date: Date = Date()) -> ClipItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fp = "t:" + Self.hash(Data(text.utf8))
        return insert(fp, date: date) { id in ClipItem(id: id, date: date, kind: .text, text: text, fingerprint: fp) }
    }

    /// png：PNG 数据；width / height：像素尺寸
    @discardableResult
    public func addImage(png: Data, width: Int, height: Int, date: Date = Date()) -> ClipItem? {
        guard !png.isEmpty else { return nil }
        let fp = "i:" + Self.hash(png)
        return insert(fp, date: date) { id in
            try? self.fm.createDirectory(at: self.imageDir, withIntermediateDirectories: true)
            let name = "\(id).png"
            guard (try? png.write(to: self.imageDir.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
            return ClipItem(id: id, date: date, kind: .image, imageFile: name, imageWidth: width, imageHeight: height, fingerprint: fp)
        }
    }

    @discardableResult
    public func addFiles(_ paths: [String], date: Date = Date()) -> ClipItem? {
        guard !paths.isEmpty else { return nil }
        let fp = "f:" + Self.hash(Data(paths.joined(separator: "\n").utf8))
        return insert(fp, date: date) { id in ClipItem(id: id, date: date, kind: .files, paths: paths, fingerprint: fp) }
    }

    /// 相同内容已在历史里 → 不新增，只提到最前；否则新建并按上限裁剪
    private func insert(_ fp: String, date: Date, make: (String) -> ClipItem?) -> ClipItem? {
        if let i = items.firstIndex(where: { $0.fingerprint == fp }) {
            var it = items.remove(at: i)
            it.date = max(date, it.date)
            items.insert(it, at: 0)
            persist()
            return it
        }
        guard let it = make(ULID.make(date: date)) else { return nil }
        items.insert(it, at: 0)
        trim()
        persist()
        return it
    }

    // MARK: 删 / 上限 / 清空

    public func delete(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        removeFiles(items.remove(at: i))
        persist()
    }

    /// 调小时立即删掉多出的旧条目
    public func setLimit(_ n: Int) {
        limit = Self.clampLimit(n)
        if trim() { persist() }
    }

    @discardableResult
    func trim() -> Bool {
        guard items.count > limit else { return false }
        for it in items[limit...] { removeFiles(it) }
        items.removeLast(items.count - limit)
        return true
    }

    /// 清空历史：删掉整个存储文件夹，不留残留
    public func clear() {
        items = []
        try? fm.removeItem(at: dir)
    }

    func removeFiles(_ it: ClipItem) {
        if let u = imageURL(it) { try? fm.removeItem(at: u) }
    }

    // MARK: 查

    public func item(id: String) -> ClipItem? { items.first { $0.id == id } }

    /// 筛选文字内容和文件名；空格分词，全部命中才算
    public func filter(_ query: String) -> [ClipItem] { ClipFilter.filter(items, query) }
}

public enum ClipFilter {
    public static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func filter(_ items: [ClipItem], _ query: String) -> [ClipItem] {
        let ts = terms(query)
        guard !ts.isEmpty else { return items }
        return items.filter { it in ts.allSatisfy { it.searchable.localizedStandardContains($0) } }
    }

    /// 命中字的范围（加下划线用）
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for t in terms(query) {
            var start = text.startIndex
            while start < text.endIndex, let r = text.range(of: t, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: start..<text.endIndex) {
                out.append(r)
                start = r.upperBound
            }
        }
        return out
    }
}

// MARK: - 时间文案（design §11.1）

public enum ClipTime {
    /// 1 分钟内「刚刚」，1 小时内「N 分钟前」，今天「10:42」，昨天「昨天 21:08」，更早「11月12日」
    public static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(Int(secs / 60)) 分钟前" }
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "zh_CN")
        hm.calendar = calendar
        hm.timeZone = calendar.timeZone
        hm.dateFormat = "HH:mm"
        if calendar.isDate(date, inSameDayAs: now) { return hm.string(from: date) }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "昨天 " + hm.string(from: date) }
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    /// 文件大小：「12 KB」「3.4 MB」
    public static func size(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - 转成灵感正文（design §11.2，product D23①②）

public enum ClipMarkdown {
    /// 文件链接：`[名字](file:///绝对路径)`，路径做百分号编码
    public static func fileLink(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
        return "[\(name)](\(url.absoluteString))"
    }

    /// 组合最终正文。assetPath：图片已拷进项目后的相对路径（如 `assets/x.png`）
    public static func body(note: String, item: ClipItem?, assetPath: String?) -> String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var head: String?
        switch item?.kind {
        case .image?: head = assetPath.map { "![](\($0))" }
        case .files?: head = item?.paths.map { $0.map(fileLink).joined(separator: "\n") }
        default: head = nil
        }
        guard let head, !head.isEmpty else { return note }
        return note.isEmpty ? head : head + "\n\n" + note
    }

    /// 文件命名用的提示：优先用户写的话，其次文件名 / 「截图」
    public static func nameHint(note: String, item: ClipItem?) -> String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        switch item?.kind {
        case .image?: return "截图"
        case .files?: return item?.fileNames.first ?? "文件"
        default: return n
        }
    }
}

// MARK: - 灵感正文里的图片 / 文件（主窗口按卡片显示，和剪贴板一致）

public struct IdeaAttachments: Equatable {
    /// 图片相对路径（相对灵感 .md 所在文件夹），如 `assets/x.png`
    public var images: [String] = []
    /// 文件链接：显示名 + 绝对路径
    public var files: [FileLink] = []
    /// 去掉开头附件行后的文字
    public var text: String = ""

    public struct FileLink: Equatable {
        public var name: String
        public var path: String
    }

    public var isEmpty: Bool { images.isEmpty && files.isEmpty }

    /// 只认正文开头连续的 `![](路径)`、`[名](file://…)` 行（ClipMarkdown 写出的格式），其余原样当文字
    public static func parse(_ body: String) -> IdeaAttachments {
        var out = IdeaAttachments()
        var lines = body.components(separatedBy: "\n")
        while let first = lines.first {
            let l = first.trimmingCharacters(in: .whitespaces)
            if l.isEmpty, !out.isEmpty { lines.removeFirst(); continue }
            if let p = match(l, #"^!\[[^\]]*\]\(<?([^)>]+)>?\)$"#) {
                out.images.append(p.removingPercentEncoding ?? p)
            } else if let m = linkMatch(l), let u = URL(string: m.url), u.isFileURL {
                out.files.append(FileLink(name: m.name, path: u.path))
            } else { break }
            lines.removeFirst()
        }
        out.text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    static func match(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func linkMatch(_ s: String) -> (name: String, url: String)? {
        guard let re = try? NSRegularExpression(pattern: #"^\[((?:\\.|[^\]])*)\]\((file://[^)]+)\)$"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let n = Range(m.range(at: 1), in: s), let u = Range(m.range(at: 2), in: s) else { return nil }
        let name = String(s[n]).replacingOccurrences(of: "\\]", with: "]").replacingOccurrences(of: "\\[", with: "[")
        return (name, String(s[u]))
    }
}
