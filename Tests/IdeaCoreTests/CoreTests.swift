import Foundation
import Testing
@testable import IdeaCore

func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sparkling-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct FrontmatterTests {
    @Test func roundTrip() {
        var fm = Frontmatter()
        fm["id"] = "01ABC"
        fm["title"] = "含: 冒号 和 \"引号\""
        fm["note"] = "#开头"
        let text = Frontmatter.compose(fm, body: "正文 #标签\n第二行")
        let (parsed, body) = Frontmatter.split(text)
        #expect(parsed?["id"] == "01ABC")
        #expect(parsed?["title"] == "含: 冒号 和 \"引号\"")
        #expect(parsed?["note"] == "#开头")
        #expect(body.trimmingCharacters(in: .newlines) == "正文 #标签\n第二行")
    }

    @Test func preservesUnknownLines() {
        let src = "---\nid: x\ntags:\n  - a\n  - b\naliases: [p, q]\n---\nbody\n"
        var (fm, body) = Frontmatter.split(src)
        fm?["id"] = "y"
        let out = Frontmatter.compose(fm, body: body)
        #expect(out.contains("tags:\n  - a\n  - b\n"))
        #expect(out.contains("aliases: [p, q]"))
        #expect(out.contains("id: y"))
    }

    @Test func noFrontmatter() {
        let (fm, body) = Frontmatter.split("只有正文\n")
        #expect(fm == nil)
        #expect(body == "只有正文\n")
    }
}

@Suite struct BasicsTests {
    @Test func ulidMonotonic() {
        let d = Date()
        let ids = (0..<200).map { _ in ULID.make(date: d) }
        #expect(ids.allSatisfy { $0.count == 26 })
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
    }

    @Test func fileNames() {
        #expect(FileNamer.summary("a/b:c*d?\"e<f>g|h#i") == "a b c d e f g h i")
        #expect(FileNamer.summary("   ") == "untitled")
        #expect(FileNamer.summary("一二三四五六七八九十一二三四五六七八九十多余") == "一二三四五六七八九十一二三四五六七八九十")
        let root = tempRoot()
        let a = FileNamer.uniqueURL(in: root, base: "x")
        FileManager.default.createFile(atPath: a.path, contents: nil)
        #expect(FileNamer.uniqueURL(in: root, base: "x").lastPathComponent == "x-2.md")
    }

    @Test func repoNames() {
        #expect(FileNamer.repoNameProblem("Inbox") != nil)
        #expect(FileNamer.repoNameProblem("inbox") != nil)
        #expect(FileNamer.repoNameProblem("a/b") != nil)
        #expect(FileNamer.repoNameProblem(".x") != nil)
        #expect(FileNamer.repoNameProblem("播放器重构") == nil)
    }
}

@Suite struct StoreTests {
    @Test func saveScanMoveDelete() throws {
        let root = tempRoot()
        let store = LibraryStore(root: root)
        var lib = try store.scan()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox").path))
        let a = try store.createRepo(name: "播放器重构", in: lib)
        #expect(a.shortcode == "bfqzg") // 系统按单字转拼音
        lib = try store.scan()
        let b = try store.createRepo(name: "数据看板", shortcode: "dv", in: lib)
        lib = try store.scan()
        #expect(lib.repos.map(\.folder) == ["播放器重构", "数据看板"])
        #expect(lib.repos.map(\.colorIndex) == [0, 1])

        let i1 = try store.saveIdea("长按右侧 2 倍速 #交互", to: a)
        let i2 = try store.saveIdea("周会换成异步周报", to: nil)
        #expect(i1.url.deletingLastPathComponent().lastPathComponent == "播放器重构")
        #expect(i2.repoFolder == "Inbox")
        let text = try String(contentsOf: i1.url, encoding: .utf8)
        #expect(text.contains("#交互"))
        let (fm, _) = Frontmatter.split(text)
        #expect(fm?.lines.count == 2)

        // 移动
        let moved = try store.moveIdea(i1, to: b)
        #expect(!FileManager.default.fileExists(atPath: i1.url.path))
        #expect(moved.repoFolder == "数据看板")

        // 删除仓库 → 灵感进收件箱
        lib = try store.scan()
        let n = try store.deleteRepo(lib.repo(folder: "数据看板")!)
        #expect(n == 1)
        lib = try store.scan()
        #expect(lib.count(in: lib.inbox) == 2)
        #expect(lib.repos.map(\.folder) == ["播放器重构"])

        // 不残留临时文件
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func renameKeepsID() throws {
        let store = LibraryStore(root: tempRoot())
        var lib = try store.scan()
        let r = try store.createRepo(name: "数据看板", in: lib)
        lib = try store.scan()
        let u = try store.updateRepo(lib.repo(folder: "数据看板")!, name: "数据看板 v2", shortcode: "kb", description: "说明", in: lib)
        lib = try store.scan()
        let again = lib.repo(folder: "数据看板 v2")!
        #expect(again.id == r.id)
        #expect(again.shortcode == "kb")
        #expect(again.description == "说明")
        #expect(u.folder == "数据看板 v2")
    }

    @Test func duplicates() throws {
        let store = LibraryStore(root: tempRoot())
        var lib = try store.scan()
        _ = try store.createRepo(name: "A", shortcode: "a", in: lib)
        lib = try store.scan()
        #expect(throws: LibraryError.duplicateName("a")) { try store.createRepo(name: "a", in: lib) }
        #expect(throws: LibraryError.duplicateShortcode("A")) { try store.createRepo(name: "B", shortcode: "A", in: lib) }
        #expect(throws: LibraryError.invalidName("「Inbox」是保留名称")) { try store.createRepo(name: "Inbox", in: lib) }
    }

    @Test func externalFilesAndFolders() throws {
        let root = tempRoot()
        let store = LibraryStore(root: root)
        _ = try store.scan()
        let dir = root.appendingPathComponent("手建文件夹")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "没有文件头的笔记".write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "忽略".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let lib = try store.scan()
        let r = lib.repo(folder: "手建文件夹")!
        #expect(r.shortcode == "sjwjj")
        #expect(lib.ideas(in: r).map(\.body) == ["没有文件头的笔记"])
    }

    @Test func updateDetectsExternalChange() throws {
        let store = LibraryStore(root: tempRoot())
        _ = try store.scan()
        let idea = try store.saveIdea("原文", to: nil)
        let edited = try store.updateIdea(idea, body: "改过")
        #expect(edited.body == "改过")
        // 模拟外部修改
        Thread.sleep(forTimeInterval: 0.05)
        try "---\nid: x\n---\n外部改的\n".write(to: idea.url, atomically: false, encoding: .utf8)
        #expect(throws: LibraryError.modifiedExternally) { try store.updateIdea(edited, body: "我的") }
        let forced = try store.updateIdea(edited, body: "我的", force: true)
        #expect(forced.body == "我的")
    }
}

@Suite struct SelectionTests {
    func repos() -> [Repo] {
        ["播放器重构", "夜读 App", "夜间模式调研", "数据看板"].enumerated().map { i, n in
            Repo(id: "r\(i)", folder: n, shortcode: i == 0 ? "pr" : Pinyin.initials(n), description: "", created: Date(timeIntervalSince1970: Double(i)), colorIndex: i, isInbox: false)
        }
    }

    @Test func pinyin() {
        #expect(Pinyin.initials("播放器重构") == "bfqzg")
        #expect(Pinyin.initialVariants("播放器重构").contains("bfqcg"))
        #expect(Pinyin.full("夜读 App") == "yeduapp")
        #expect(Pinyin.initials("夜读 App") == "yda")
    }

    @Test(arguments: [
        ("pr", "播放器重构"), ("bfq", "播放器重构"), ("bfqcg", "播放器重构"), ("播放", "播放器重构"), ("bofang", "播放器重构"),
        ("yd", "夜读 App"), ("夜间", "夜间模式调研"), ("sjkb", "数据看板"), ("看板", "数据看板"),
    ])
    func matcherTop(query: String, expected: String) {
        #expect(RepoMatcher(repos: repos()).match(query).first?.folder == expected)
    }

    @Test func matcherMisc() {
        let m = RepoMatcher(repos: repos())
        #expect(m.match("ye").map(\.folder) == ["夜读 App", "夜间模式调研"])
        #expect(m.match("zzz").isEmpty)
        #expect(m.match("").count == 4)
        #expect(m.exact("pr")?.folder == "播放器重构")
        #expect(m.exact("bf") == nil)
    }

    @Test func mentionTrigger() {
        #expect(MentionParser.active(in: "@pr", cursor: 3)?.query == "pr")
        #expect(MentionParser.active(in: "加个 @bf", cursor: 6)?.query == "bf")
        #expect(MentionParser.active(in: "第一行\n@x", cursor: 6)?.query == "x")
        #expect(MentionParser.active(in: "发给 a@b.com", cursor: 10) == nil)
        #expect(MentionParser.active(in: "@pr 后面", cursor: 6) == nil)
        #expect(MentionParser.active(in: "@", cursor: 1)?.query == "")
        #expect(MentionParser.active(in: "abc", cursor: 0) == nil)
    }

    @Test func mentionRemove() {
        let t = "@pr 字幕字号可调 #交互"
        let m = MentionParser.active(in: t, cursor: 3)!
        let r = MentionParser.remove(m, from: t)
        #expect(r.text == "字幕字号可调 #交互")
        #expect(r.cursor == 0)
        let t2 = "字幕字号可调 @pr"
        let m2 = MentionParser.active(in: t2, cursor: (t2 as NSString).length)!
        #expect(MentionParser.remove(m2, from: t2).text == "字幕字号可调")
        let t3 = "前 @pr 后"
        let m3 = MentionParser.active(in: t3, cursor: 5)!
        #expect(MentionParser.remove(m3, from: t3).text == "前 后")
    }

    @Test func tagCycle() {
        var s = TagSelection()
        let ids = ["a", "b", "c"]
        s.next(visible: ids); #expect(s.selected == "a")
        s.next(visible: ids); s.next(visible: ids); #expect(s.selected == "c")
        s.next(visible: ids); #expect(s.selected == nil)
        s.previous(visible: ids); #expect(s.selected == "c")
        s.toggle(index: 1, in: ids); #expect(s.selected == "b")
        s.toggle(index: 1, in: ids); #expect(s.selected == nil)
        s.toggle(index: 7, in: ids); #expect(s.selected == nil)
        s.toggle("hidden"); s.next(visible: ids); #expect(s.selected == "a")
        s.clear(); #expect(s.selected == nil)
        var e = TagSelection(); e.next(visible: []); #expect(e.selected == nil)
    }

    @Test func keyPolicy() {
        typealias P = SubmitKeyPolicy
        #expect(P.action(.newline, shift: false, hasMarkedText: false, popupOpen: false) == .submit)
        #expect(P.action(.newline, shift: false, hasMarkedText: true, popupOpen: false) == .passThrough)
        #expect(P.action(.newline, shift: false, hasMarkedText: true, popupOpen: true) == .passThrough)
        #expect(P.action(.newline, shift: true, hasMarkedText: false, popupOpen: false) == .newline)
        #expect(P.action(.newline, shift: false, hasMarkedText: false, popupOpen: true) == .popupConfirm)
        #expect(P.action(.cancel, shift: false, hasMarkedText: true, popupOpen: true) == .passThrough)
        #expect(P.action(.cancel, shift: false, hasMarkedText: false, popupOpen: false) == .cancel)
        #expect(P.action(.cancel, shift: false, hasMarkedText: false, popupOpen: true) == .popupClose)
        #expect(P.action(.tab, shift: false, hasMarkedText: true, popupOpen: false) == .passThrough)
        #expect(P.action(.tab, shift: false, hasMarkedText: false, popupOpen: false) == .nextTag)
        #expect(P.action(.backtab, shift: true, hasMarkedText: false, popupOpen: false) == .prevTag)
        #expect(P.action(.tab, shift: false, hasMarkedText: false, popupOpen: true) == .popupConfirm)
        #expect(P.action(.up, shift: false, hasMarkedText: false, popupOpen: true) == .popupUp)
        #expect(P.action(.down, shift: false, hasMarkedText: false, popupOpen: true) == .popupDown)
        #expect(P.action(.down, shift: false, hasMarkedText: true, popupOpen: true) == .passThrough)
        #expect(P.action(.up, shift: false, hasMarkedText: false, popupOpen: false) == .passThrough)
        #expect(P.allowsShortcut(hasMarkedText: true) == false)
    }

    @Test func search() {
        let ideas = [
            Idea(id: "1", url: URL(fileURLWithPath: "/a"), repoFolder: "A", created: Date(timeIntervalSince1970: 1), modified: Date(), body: "支付页加 Button"),
            Idea(id: "2", url: URL(fileURLWithPath: "/b"), repoFolder: "B", created: Date(timeIntervalSince1970: 2), modified: Date(), body: "夜间模式 button"),
        ]
        #expect(TextSearch.search("BUTTON", in: ideas).map(\.id) == ["2", "1"])
        #expect(TextSearch.search("夜间 button", in: ideas).map(\.id) == ["2"])
        #expect(TextSearch.search("", in: ideas).count == 2)
    }
}

@Suite struct DateGroupingTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 10, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))!
    }
    func idea(_ date: Date) -> Idea { Idea(id: UUID().uuidString, url: URL(fileURLWithPath: "/x"), repoFolder: "A", created: date, modified: date, body: "b") }

    @Test func titles() {
        let now = d(2026, 11, 17, 21)
        #expect(DateGrouping.title(for: d(2026, 11, 17, 0, 0), now: now, calendar: cal) == "今天 · 11月17日 周二")
        #expect(DateGrouping.title(for: d(2026, 11, 16, 0, 0), now: now, calendar: cal) == "昨天 · 11月16日 周一")
        #expect(DateGrouping.title(for: d(2026, 11, 12, 0, 0), now: now, calendar: cal) == "11月12日 周四")
        #expect(DateGrouping.title(for: d(2025, 11, 3, 0, 0), now: now, calendar: cal) == "2025年11月3日 周一")
        #expect(DateGrouping.time(d(2026, 11, 17, 9, 5), calendar: cal) == "09:05")
    }

    @Test func grouping() {
        let now = d(2026, 11, 17, 21)
        let g = DateGrouping.groups([idea(d(2026, 11, 16, 9)), idea(d(2026, 11, 17, 8)), idea(d(2026, 11, 17, 10)), idea(d(2026, 11, 16, 20))], now: now, calendar: cal)
        #expect(g.count == 2)
        #expect(g[0].title.hasPrefix("今天"))
        #expect(g[0].ideas.map { DateGrouping.time($0.created, calendar: cal) } == ["10:00", "08:00"])
        #expect(g[1].ideas.map { DateGrouping.time($0.created, calendar: cal) } == ["20:00", "09:00"])
    }
}

@Suite struct EditExitTests {
    @Test func decide() {
        #expect(EditExitPolicy.decide(original: "原文", onDisk: "原文", edited: "改了") == .write("改了"))
        #expect(EditExitPolicy.decide(original: "原文", onDisk: "改了", edited: "改了") == .nothing)
        #expect(EditExitPolicy.decide(original: "原文", onDisk: "原文", edited: "  \n") == .nothing)
        // 自动保存写过半截，又删空 → 写回原文
        #expect(EditExitPolicy.decide(original: "原文", onDisk: "半截", edited: "") == .write("原文"))
        #expect(!EditExitPolicy.shouldAutosave("", onDisk: "原文"))
        #expect(EditExitPolicy.shouldAutosave("新", onDisk: "原文"))
    }
}

@Suite struct RootMigrationTests {
    func setup() -> (UserDefaults, URL, URL) {
        let base = tempRoot()
        let d = UserDefaults(suiteName: "sparkling-test-\(UUID().uuidString)")!
        return (d, base.appendingPathComponent("IdeaNotes"), base.appendingPathComponent("Sparkling"))
    }

    @Test func migratesWhenOnlyLegacyExists() throws {
        let (d, old, new) = setup()
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        #expect(LibraryStore.migrateLegacyDefaultRoot(defaults: d, env: [:], legacy: old, target: new))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("Inbox").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func skipsWhenUserChoseRootOrTargetExists() throws {
        let (d, old, new) = setup()
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        d.set("/somewhere", forKey: "rootPath")
        #expect(!LibraryStore.migrateLegacyDefaultRoot(defaults: d, env: [:], legacy: old, target: new))
        d.removeObject(forKey: "rootPath")
        #expect(!LibraryStore.migrateLegacyDefaultRoot(defaults: d, env: ["SPARKLING_ROOT": "/x"], legacy: old, target: new))
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        #expect(!LibraryStore.migrateLegacyDefaultRoot(defaults: d, env: [:], legacy: old, target: new))
        #expect(FileManager.default.fileExists(atPath: old.path))
    }
}

@Suite struct RenameTests {
    func repo(_ id: String, _ name: String) -> Repo { Repo(id: id, folder: name, shortcode: "", description: "", created: Date(), colorIndex: 0, isInbox: false) }

    @Test func decide() {
        let a = repo("a", "结算重构"), b = repo("b", "增长实验")
        #expect(RenamePolicy.decide("结算重构", repo: a, others: [a, b]) == .unchanged)
        #expect(RenamePolicy.decide("  新名字 ", repo: a, others: [a, b]) == .rename("新名字"))
        #expect(RenamePolicy.decide("   ", repo: a, others: [a, b]) == .rejected("名称不能为空，已恢复原名"))
        #expect(RenamePolicy.decide("增长实验", repo: a, others: [a, b]) == .rejected("已有项目「增长实验」，已恢复原名"))
        if case .rejected = RenamePolicy.decide("a/b", repo: a, others: [a, b]) {} else { Issue.record("非法字符应被拒") }
        if case .rejected = RenamePolicy.decide("未归类", repo: a, others: [a, b]) {} else { Issue.record("保留名应被拒") }
    }

    /// 改名同步改磁盘文件夹，灵感不丢（验收 #18）
    @Test func renameKeepsIdeas() throws {
        let store = LibraryStore(root: tempRoot())
        var lib = try store.scan()
        let r = try store.createRepo(name: "旧名", in: lib)
        try store.saveIdea("一条", to: r)
        try store.saveIdea("两条", to: r)
        lib = try store.scan()
        _ = try store.updateRepo(lib.repo(id: r.id)!, name: "新名", shortcode: r.shortcode, description: "", in: lib)
        lib = try store.scan()
        #expect(lib.repo(folder: "旧名") == nil)
        #expect(lib.count(in: lib.repo(folder: "新名")!) == 2)
    }
}
