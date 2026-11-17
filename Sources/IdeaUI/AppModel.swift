import AppKit
import Observation
import IdeaCore

/// 全局共享状态：根目录、仓库与灵感的内存索引。
@Observable @MainActor
public final class AppModel {
    public private(set) var store: LibraryStore
    public internal(set) var library = Library()
    /// 根目录丢失 / 不可写时的说明
    public private(set) var loadError: String?

    /// 配色主题，点选立即生效（呼出面板与全部灵感一起换）
    public var palette: Palette = Theme.current {
        didSet { Theme.current = palette; UserDefaults.standard.set(palette.rawValue, forKey: "palette") }
    }

    /// 背景底纹，点选立即生效
    public var texture: Texture = Texture.load() {
        didSet { UserDefaults.standard.set(texture.rawValue, forKey: "texture") }
    }

    public var rootIsFromEnv: Bool { !(ProcessInfo.processInfo.environment["SPARKLING_ROOT"] ?? "").isEmpty }

    public init() {
        if LibraryStore.migrateLegacyDefaultRoot() { log.info("migrated ~/Documents/IdeaNotes → ~/Documents/Sparkling") }
        store = LibraryStore(root: LibraryStore.resolveRoot())
        reload()
    }

    public var root: URL { store.root }
    public var repos: [Repo] { library.repos }

    /// 全量扫描（菜单「文件 › 重新读取文件夹」）
    public func reload() {
        let t = CFAbsoluteTimeGetCurrent()
        do {
            library = try store.scan()
            loadError = nil
        } catch {
            loadError = "找不到 Sparkling 文件夹"
        }
        log.info("scan \(self.library.ideas.count) ideas in \(Int((CFAbsoluteTimeGetCurrent() - t) * 1000))ms")
    }

    /// 只检查根目录是否可用（不重扫）
    public func checkRoot() {
        loadError = store.rootIsWritable ? nil : "找不到 Sparkling 文件夹"
    }

    /// 换根目录；moveExisting 为 true 时把现有内容一起搬过去。返回没能搬走的项。
    @discardableResult
    public func setRoot(_ url: URL, moveExisting: Bool) throws -> [String] {
        var skipped: [String] = []
        if moveExisting, url.standardizedFileURL != store.root { skipped = try store.moveContents(to: url) }
        UserDefaults.standard.set(url.path, forKey: "rootPath")
        store = LibraryStore(root: url)
        reload()
        return skipped
    }

    /// 保存后增量加入索引，不必全量扫描
    func didSave(_ idea: Idea) {
        library.ideas.append(idea)
    }

    /// 用新版本替换索引中的一条（按旧 URL 定位）
    func replace(_ old: Idea, with new: Idea) {
        if let i = library.ideas.firstIndex(where: { $0.url == old.url }) { library.ideas[i] = new } else { library.ideas.append(new) }
    }

    func remove(_ idea: Idea) {
        library.ideas.removeAll { $0.url == idea.url }
    }
}
