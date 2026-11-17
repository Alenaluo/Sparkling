import Foundation

public struct Repo: Identifiable, Hashable, Sendable {
    public var id: String
    /// 文件夹名 = 仓库名；收件箱为 `Inbox`
    public var folder: String
    public var shortcode: String
    public var description: String
    public var created: Date
    public var colorIndex: Int
    public var isInbox: Bool

    public init(id: String, folder: String, shortcode: String, description: String, created: Date, colorIndex: Int, isInbox: Bool) {
        self.id = id; self.folder = folder; self.shortcode = shortcode; self.description = description
        self.created = created; self.colorIndex = colorIndex; self.isInbox = isInbox
    }

    public var displayName: String { isInbox ? L("未归类", "Unsorted") : folder }
}

public struct Idea: Identifiable, Hashable, Sendable {
    public var id: String
    public var url: URL
    public var repoFolder: String
    public var created: Date
    public var modified: Date
    public var body: String
}

public struct Library: Sendable {
    public var inbox: Repo
    /// 不含收件箱，按创建时间排序（= tag 顺序）
    public var repos: [Repo]
    public var ideas: [Idea]

    public init(inbox: Repo = Repo(id: "inbox", folder: LibraryStore.inboxFolder, shortcode: "", description: "", created: .distantPast, colorIndex: -1, isInbox: true), repos: [Repo] = [], ideas: [Idea] = []) {
        self.inbox = inbox; self.repos = repos; self.ideas = ideas
    }

    public var allRepos: [Repo] { [inbox] + repos }
    public func repo(id: String) -> Repo? { allRepos.first { $0.id == id } }
    public func repo(folder: String) -> Repo? { allRepos.first { $0.folder == folder } }
    public func ideas(in repo: Repo) -> [Idea] {
        ideas.filter { $0.repoFolder == repo.folder }.sorted { $0.created > $1.created }
    }
    public func count(in repo: Repo) -> Int { ideas.lazy.filter { $0.repoFolder == repo.folder }.count }
}

public enum LibraryError: LocalizedError, Equatable {
    case invalidName(String)
    case duplicateName(String)
    case duplicateShortcode(String)
    case modifiedExternally
    case notWritable(String)
    case inboxIsProtected

    public var errorDescription: String? {
        switch self {
        case let .invalidName(m): return m
        case let .duplicateName(n): return L("已经有叫「\(n)」的项目", "“\(n)” already exists")
        case let .duplicateShortcode(n): return L("已被 \(n) 使用", "Already used by \(n)")
        case .modifiedExternally: return L("文件已在别处修改", "Changed somewhere else")
        case let .notWritable(m): return m
        case .inboxIsProtected: return L("未归类不能改名或删除", "Unsorted can't be renamed or deleted")
        }
    }
}

public final class LibraryStore: @unchecked Sendable {
    public static let inboxFolder = "Inbox"
    public static let repoFile = "_repo.md"
    public static let paletteCount = 8

    public let root: URL
    let fm = FileManager.default

    public init(root: URL) { self.root = root.standardizedFileURL }

    /// 根目录取值：环境变量 SPARKLING_ROOT > 设置 > ~/Documents/IdeaNotes
    public static func resolveRoot(defaults: UserDefaults = .standard, env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let p = env["SPARKLING_ROOT"], !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        if let p = defaults.string(forKey: "rootPath"), !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return defaultRoot
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Sparkling")
    }

    /// 0.1 版的默认目录，用于一次性迁移
    public static var legacyDefaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/IdeaNotes")
    }

    /// 默认目录从 ~/Documents/IdeaNotes 改为 ~/Documents/Sparkling：
    /// 用户没自己设过路径、旧目录在、新目录还不存在时，把旧文件夹改名过去。返回是否迁移了。
    @discardableResult
    public static func migrateLegacyDefaultRoot(defaults: UserDefaults = .standard,
                                                env: [String: String] = ProcessInfo.processInfo.environment,
                                                legacy: URL = legacyDefaultRoot, target: URL = defaultRoot) -> Bool {
        let fm = FileManager.default
        guard (env["SPARKLING_ROOT"] ?? "").isEmpty,
              (defaults.string(forKey: "rootPath") ?? "").isEmpty,
              fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: target.path) else { return false }
        do {
            try fm.moveItem(at: legacy, to: target)
            return true
        } catch {
            // 改名失败就继续用旧目录，不丢数据
            defaults.set(legacy.path, forKey: "rootPath")
            return false
        }
    }

    var inboxURL: URL { root.appendingPathComponent(Self.inboxFolder) }
    func folderURL(_ folder: String) -> URL { root.appendingPathComponent(folder, isDirectory: true) }

    /// 根目录与收件箱不存在则创建。
    public func ensureRoot() throws {
        do {
            try fm.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        } catch {
            throw LibraryError.notWritable(L("Sparkling 文件夹不可写", "the Sparkling folder isn't writable"))
        }
    }

    public var rootIsWritable: Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue && fm.isWritableFile(atPath: root.path)
    }

    // MARK: 扫描

    public func scan() throws -> Library {
        try ensureRoot()
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles])) ?? []
        var repos: [Repo] = []
        var ideas: [Idea] = []
        for url in children {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let folder = url.lastPathComponent
            let isInbox = folder == Self.inboxFolder
            if !isInbox { repos.append(readRepo(folder: folder)) }
            ideas += readIdeas(folder: folder)
        }
        repos.sort { ($0.created, $0.folder) < ($1.created, $1.folder) }
        // 没有 _repo.md 的仓库按位置给颜色
        for i in repos.indices where repos[i].colorIndex < 0 { repos[i].colorIndex = i % Self.paletteCount }
        let inbox = Repo(id: "inbox", folder: Self.inboxFolder, shortcode: "", description: "", created: .distantPast, colorIndex: -1, isInbox: true)
        return Library(inbox: inbox, repos: repos, ideas: ideas)
    }

    func readRepo(folder: String) -> Repo {
        let dir = folderURL(folder)
        let fileURL = dir.appendingPathComponent(Self.repoFile)
        let folderCreated = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return Repo(id: "folder:\(folder)", folder: folder, shortcode: Pinyin.initials(folder), description: "", created: folderCreated, colorIndex: -1, isInbox: false)
        }
        let (fmOpt, body) = Frontmatter.split(text)
        let fmv = fmOpt ?? Frontmatter()
        return Repo(
            id: fmv["id"] ?? "folder:\(folder)",
            folder: folder,
            shortcode: fmv["shortcode"] ?? Pinyin.initials(folder),
            description: body.trimmingCharacters(in: .whitespacesAndNewlines),
            created: ISODate.parse(fmv["created"]) ?? folderCreated,
            colorIndex: Int(fmv["color"] ?? "").map { (($0 % Self.paletteCount) + Self.paletteCount) % Self.paletteCount } ?? -1,
            isInbox: false
        )
    }

    func readIdeas(folder: String) -> [Idea] {
        let dir = folderURL(folder)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { url in
            guard url.pathExtension.lowercased() == "md", url.lastPathComponent != Self.repoFile else { return nil }
            return readIdea(url: url, folder: folder)
        }
    }

    public func readIdea(url: URL, folder: String) -> Idea? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let attrs = Self.dates(url)
        let (fmOpt, body) = Frontmatter.split(text)
        let created = ISODate.parse(fmOpt?["created"]) ?? attrs.created ?? Date()
        return Idea(
            id: fmOpt?["id"] ?? "path:\(folder)/\(url.lastPathComponent)",
            url: url,
            repoFolder: folder,
            created: created,
            modified: attrs.modified ?? created,
            body: body.trimmingCharacters(in: .newlines)
        )
    }

    /// 直接读文件属性（URL 的 resourceValues 会缓存，读不到外部修改）。
    static func dates(_ url: URL) -> (created: Date?, modified: Date?) {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (a?[.creationDate] as? Date, a?[.modificationDate] as? Date)
    }

    // MARK: 灵感

    /// 保存一条灵感。repo 为 nil 或收件箱时写入 Inbox/。
    @discardableResult
    public func saveIdea(_ text: String, to repo: Repo?, date: Date = Date(), nameHint: String? = nil) throws -> Idea {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (repo?.isInbox ?? true) ? Self.inboxFolder : repo!.folder
        let dir = folderURL(folder)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw LibraryError.notWritable(L("Sparkling 文件夹不可写", "the Sparkling folder isn't writable"))
        }
        let url = FileNamer.uniqueURL(in: dir, base: FileNamer.baseName(for: nameHint ?? body, date: date))
        var fmv = Frontmatter()
        fmv["id"] = ULID.make(date: date)
        fmv["created"] = ISODate.string(date)
        do {
            try AtomicWriter.write(Frontmatter.compose(fmv, body: body), to: url)
        } catch {
            throw LibraryError.notWritable(L("\(folder == Self.inboxFolder ? "未归类" : folder) 文件夹不可写", "the “\(folder == Self.inboxFolder ? "Unsorted" : folder)” folder isn't writable"))
        }
        return readIdea(url: url, folder: folder)!
    }

    /// 把图片拷进项目的 `assets/`（v2 剪贴板转灵感，D23②）。返回 .md 里引用用的相对路径 `assets/<名>.png`。
    public func copyAsset(from src: URL, to repo: Repo?, baseName: String, date: Date = Date()) throws -> String {
        let folder = (repo?.isInbox ?? true) ? Self.inboxFolder : repo!.folder
        let dir = folderURL(folder).appendingPathComponent("assets", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = src.pathExtension.isEmpty ? "png" : src.pathExtension
            let dst = FileNamer.uniqueURL(in: dir, base: FileNamer.baseName(for: baseName, date: date).replacingOccurrences(of: " ", with: "-"), ext: ext)
            try fm.copyItem(at: src, to: dst)
            return "assets/" + dst.lastPathComponent
        } catch {
            throw LibraryError.notWritable(L("\(folder == Self.inboxFolder ? "未归类" : folder) 文件夹不可写", "the “\(folder == Self.inboxFolder ? "Unsorted" : folder)” folder isn't writable"))
        }
    }

    /// 改正文。写回前比对修改时间，外部改过且未 force 时抛 modifiedExternally。文件名不变。
    @discardableResult
    public func updateIdea(_ idea: Idea, body: String, force: Bool = false) throws -> Idea {
        let current = try? String(contentsOf: idea.url, encoding: .utf8)
        let mtime = Self.dates(idea.url).modified
        if !force, let mtime, abs(mtime.timeIntervalSince(idea.modified)) > 0.001 { throw LibraryError.modifiedExternally }
        let (fmOpt, _) = Frontmatter.split(current ?? "")
        try AtomicWriter.write(Frontmatter.compose(fmOpt, body: body), to: idea.url)
        return readIdea(url: idea.url, folder: idea.repoFolder) ?? idea
    }

    @discardableResult
    public func moveIdea(_ idea: Idea, to repo: Repo) throws -> Idea {
        let dir = folderURL(repo.folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = idea.url.deletingPathExtension().lastPathComponent
        let dest = FileNamer.uniqueURL(in: dir, base: base, ext: idea.url.pathExtension)
        try fm.moveItem(at: idea.url, to: dest)
        return readIdea(url: dest, folder: repo.folder) ?? idea
    }

    /// 移到系统废纸篓，返回废纸篓里的位置（用于撤销）。
    @discardableResult
    public func trashIdea(_ idea: Idea) throws -> URL? {
        var result: NSURL?
        try fm.trashItem(at: idea.url, resultingItemURL: &result)
        return result as URL?
    }

    /// 从废纸篓（或任意位置）放回原处。
    public func restore(from url: URL, to original: URL) throws {
        let dest = fm.fileExists(atPath: original.path)
            ? FileNamer.uniqueURL(in: original.deletingLastPathComponent(), base: original.deletingPathExtension().lastPathComponent, ext: original.pathExtension)
            : original
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: dest)
    }

    // MARK: 仓库

    public func validate(name: String, shortcode: String?, excluding: Repo?, in library: Library) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = FileNamer.repoNameProblem(trimmed) { throw LibraryError.invalidName(p) }
        if library.repos.contains(where: { $0.id != excluding?.id && $0.folder.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            throw LibraryError.duplicateName(trimmed)
        }
        if let sc = shortcode?.trimmingCharacters(in: .whitespaces).lowercased(), !sc.isEmpty,
           let other = library.repos.first(where: { $0.id != excluding?.id && $0.shortcode.lowercased() == sc }) {
            throw LibraryError.duplicateShortcode(other.folder)
        }
    }

    /// 新建仓库：建文件夹 + _repo.md；短码默认拼音首字母（重复时加数字）；颜色按创建顺序轮换。
    @discardableResult
    public func createRepo(name: String, shortcode: String? = nil, description: String = "", in library: Library, date: Date = Date()) throws -> Repo {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(name: trimmed, shortcode: shortcode, excluding: nil, in: library)
        var sc = (shortcode?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? Pinyin.initials(trimmed)
        if shortcode == nil || shortcode!.isEmpty {
            let used = Set(library.repos.map { $0.shortcode.lowercased() })
            var n = 2
            let base = sc
            while used.contains(sc) { sc = "\(base)\(n)"; n += 1 }
        }
        let dir = folderURL(trimmed)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        let repo = Repo(id: UUID().uuidString.lowercased(), folder: trimmed, shortcode: sc, description: description,
                        created: date, colorIndex: library.repos.count % Self.paletteCount, isInbox: false)
        try writeRepoFile(repo)
        return repo
    }

    func writeRepoFile(_ repo: Repo) throws {
        let url = folderURL(repo.folder).appendingPathComponent(Self.repoFile)
        let existing = (try? String(contentsOf: url, encoding: .utf8)).map { Frontmatter.split($0).0 } ?? nil
        var fmv = existing ?? Frontmatter()
        fmv["id"] = repo.id.hasPrefix("folder:") ? UUID().uuidString.lowercased() : repo.id
        fmv["shortcode"] = repo.shortcode
        fmv["created"] = ISODate.string(repo.created)
        fmv["color"] = String(max(0, repo.colorIndex))
        try AtomicWriter.write(Frontmatter.compose(fmv, body: repo.description), to: url)
    }

    /// 改名 / 改短码 / 改描述。改名 = 重命名文件夹，id 不变。
    @discardableResult
    public func updateRepo(_ repo: Repo, name: String, shortcode: String, description: String, in library: Library) throws -> Repo {
        guard !repo.isInbox else { throw LibraryError.inboxIsProtected }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sc = shortcode.trimmingCharacters(in: .whitespaces).lowercased()
        try validate(name: trimmed, shortcode: sc, excluding: repo, in: library)
        var updated = repo
        if trimmed != repo.folder {
            let tmp = root.appendingPathComponent(".rename-\(UUID().uuidString)")
            // 先挪到临时名，兼容只改大小写
            try fm.moveItem(at: folderURL(repo.folder), to: tmp)
            try fm.moveItem(at: tmp, to: folderURL(trimmed))
            updated.folder = trimmed
        }
        updated.shortcode = sc
        updated.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.id.hasPrefix("folder:") { updated.id = UUID().uuidString.lowercased() }
        try writeRepoFile(updated)
        return updated
    }

    /// 删除仓库：灵感逐条移到收件箱，然后整个文件夹进废纸篓。返回移动的条数。
    @discardableResult
    public func deleteRepo(_ repo: Repo) throws -> Int {
        guard !repo.isInbox else { throw LibraryError.inboxIsProtected }
        try ensureRoot()
        let ideas = readIdeas(folder: repo.folder)
        for idea in ideas {
            let base = idea.url.deletingPathExtension().lastPathComponent
            try fm.moveItem(at: idea.url, to: FileNamer.uniqueURL(in: inboxURL, base: base, ext: idea.url.pathExtension))
        }
        try fm.trashItem(at: folderURL(repo.folder), resultingItemURL: nil)
        return ideas.count
    }

    /// 把当前根目录下的内容搬到新根目录（不覆盖同名项）。返回未能搬走的项。
    public func moveContents(to newRoot: URL) throws -> [String] {
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        var skipped: [String] = []
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in children {
            let dest = newRoot.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                // 同名文件夹：合并其中的文件
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    for f in files {
                        let target = FileNamer.uniqueURL(in: dest, base: f.deletingPathExtension().lastPathComponent, ext: f.pathExtension)
                        if f.lastPathComponent == Self.repoFile, fm.fileExists(atPath: dest.appendingPathComponent(Self.repoFile).path) { continue }
                        do { try fm.moveItem(at: f, to: f.lastPathComponent == Self.repoFile ? dest.appendingPathComponent(Self.repoFile) : target) }
                        catch { skipped.append(f.lastPathComponent) }
                    }
                } else { skipped.append(url.lastPathComponent) }
            } else {
                do { try fm.moveItem(at: url, to: dest) } catch { skipped.append(url.lastPathComponent) }
            }
        }
        return skipped
    }
}
