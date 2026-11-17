import Foundation
import Testing
@testable import IdeaCore

/// v2 剪贴板历史（product §10.7 C5–C7、C10、C12、C13 的逻辑部分）
@Suite struct ClipboardStoreTests {
    let dir = tempRoot().appendingPathComponent(".clipboard")

    @Test func addOrderAndReload() {
        let s = ClipboardStore(dir: dir)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        s.addText("第一段", date: t0)
        s.addFiles(["/Users/me/Desktop/方案 v2.pdf"], date: t0.addingTimeInterval(1))
        s.addImage(png: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), width: 1280, height: 720, date: t0.addingTimeInterval(2))
        #expect(s.items.map(\.kind) == [.image, .files, .text])
        #expect(s.items[0].summary == "截图 · 1280 × 720")
        #expect(s.items[1].summary == "方案 v2.pdf")
        #expect(FileManager.default.fileExists(atPath: s.imageURL(s.items[0])!.path))
        // 重启后读回
        let s2 = ClipboardStore(dir: dir)
        #expect(s2.items == s.items)
        #expect(ClipboardStore(dir: dir).items.first?.kind == .image)
    }

    @Test func emptyTextIgnored() {
        let s = ClipboardStore(dir: dir)
        #expect(s.addText("  \n ") == nil)
        #expect(s.items.isEmpty)
    }

    /// C7：相同内容只出现一条，并提到最前
    @Test func dedupeMovesToTop() {
        let s = ClipboardStore(dir: dir)
        let t0 = Date()
        s.addText("A", date: t0)
        s.addText("A", date: t0.addingTimeInterval(1))
        #expect(s.items.count == 1)
        s.addText("B", date: t0.addingTimeInterval(2))
        s.addText("A", date: t0.addingTimeInterval(3))
        #expect(s.items.map(\.text) == ["A", "B"])
        s.addFiles(["/a", "/b"]); s.addFiles(["/a", "/b"])
        #expect(s.items.count == 3)
    }

    /// C6：上限 10，复制 12 次只留最近 10 条；调小立即裁掉多出的旧条目，并删图片
    @Test func limitAndTrim() {
        let s = ClipboardStore(dir: dir, limit: 10)
        let t0 = Date()
        for i in 0..<12 { s.addText("第 \(i) 条", date: t0.addingTimeInterval(Double(i))) }
        #expect(s.items.count == 10)
        #expect(s.items.first?.text == "第 11 条")
        #expect(s.items.last?.text == "第 2 条")
        s.setLimit(50)
        let img = s.addImage(png: Data([1, 2, 3]), width: 1, height: 1, date: t0.addingTimeInterval(-100))!
        #expect(s.items.count == 11 && s.items.first?.id == img.id)
        // 调回 10：立即裁掉最旧的一条
        s.setLimit(10)
        #expect(s.items.count == 10)
        #expect(s.items.last?.text == "第 3 条")
        #expect(ClipboardStore(dir: dir).items.count == 10)
        #expect(ClipboardStore.clampLimit(5) == 10)
        #expect(ClipboardStore.clampLimit(900) == 500)
    }

    /// C10 / C12：删除、清空后文件夹无残留
    @Test func deleteAndClear() throws {
        let s = ClipboardStore(dir: dir)
        let img = s.addImage(png: Data([9, 9]), width: 2, height: 2)!
        let url = s.imageURL(img)!
        s.addText("留下")
        s.delete(id: img.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(s.items.map(\.text) == ["留下"])
        #expect(ClipboardStore(dir: dir).items.count == 1)
        s.clear()
        #expect(s.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(ClipboardStore(dir: dir).items.isEmpty)
    }

    /// C12：筛选文字内容和文件名
    @Test func filter() {
        let s = ClipboardStore(dir: dir)
        s.addText("播放器 重构的想法")
        s.addFiles(["/tmp/Report-Final.pdf"])
        s.addImage(png: Data([1]), width: 1, height: 1)
        #expect(s.filter("").count == 3)
        #expect(s.filter("重构").map(\.kind) == [.text])
        #expect(s.filter("report").map(\.kind) == [.files])
        #expect(s.filter("播放器 想法").count == 1)
        #expect(s.filter("没有").isEmpty)
        let text = "Report-Final.pdf"
        #expect(ClipFilter.ranges(of: "final", in: text).map { String(text[$0]) } == ["Final"])
    }

    /// C13：索引里不含来源 App
    @Test func indexHasNoSourceApp() throws {
        let s = ClipboardStore(dir: dir)
        s.addText("x")
        let json = try String(contentsOf: dir.appendingPathComponent("index.json"), encoding: .utf8)
        for key in ["app", "source", "bundle"] { #expect(!json.lowercased().contains("\"\(key)")) }
    }

    @Test func defaultDir() {
        let root = URL(fileURLWithPath: "/tmp/r")
        #expect(ClipboardStore.defaultDir(root: root, env: ["SPARKLING_ROOT": "/tmp/r"]).path == "/tmp/r/.clipboard")
        #expect(ClipboardStore.defaultDir(root: root, env: [:]).path.hasSuffix("Application Support/Sparkling/clipboard"))
    }
}

@Suite struct ClipTimeTests {
    @Test func labels() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15, minute: 0))!
        #expect(ClipTime.label(now.addingTimeInterval(-20), now: now, calendar: cal) == "刚刚")
        #expect(ClipTime.label(now.addingTimeInterval(-5 * 60), now: now, calendar: cal) == "5 分钟前")
        #expect(ClipTime.label(cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 10, minute: 42))!, now: now, calendar: cal) == "10:42")
        #expect(ClipTime.label(cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 21, minute: 8))!, now: now, calendar: cal) == "昨天 21:08")
        #expect(ClipTime.label(cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9))!, now: now, calendar: cal) == "11月12日")
    }
}

/// C5 的逻辑部分：图片拷进 assets/、文件只写链接
@Suite struct ClipMarkdownTests {
    func item(_ kind: ClipKind, paths: [String]? = nil) -> ClipItem {
        ClipItem(id: "1", date: Date(), kind: kind, paths: paths, fingerprint: "x")
    }

    @Test func bodies() {
        #expect(ClipMarkdown.body(note: " 一句话 ", item: nil, assetPath: nil) == "一句话")
        #expect(ClipMarkdown.body(note: "", item: item(.image), assetPath: "assets/a.png") == "![](assets/a.png)")
        #expect(ClipMarkdown.body(note: "图注", item: item(.image), assetPath: "assets/a.png") == "![](assets/a.png)\n\n图注")
        let f = ClipMarkdown.body(note: "看看", item: item(.files, paths: ["/Users/me/方案 v2.pdf", "/tmp/b.txt"]), assetPath: nil)
        #expect(f == "[方案 v2.pdf](file:///Users/me/%E6%96%B9%E6%A1%88%20v2.pdf)\n[b.txt](file:///tmp/b.txt)\n\n看看")
        #expect(ClipMarkdown.nameHint(note: "", item: item(.image)) == "截图")
        #expect(ClipMarkdown.nameHint(note: "", item: item(.files, paths: ["/a/x.pdf"])) == "x.pdf")
    }

    @Test func copyAssetIntoProject() throws {
        let root = tempRoot()
        let store = LibraryStore(root: root)
        let repo = try store.createRepo(name: "播放器", in: store.scan())
        let src = root.appendingPathComponent("src.png")
        try Data([1, 2, 3]).write(to: src)
        let rel = try store.copyAsset(from: src, to: repo, baseName: "截图 一张")
        #expect(rel.hasPrefix("assets/") && rel.hasSuffix(".png") && !rel.contains(" "))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("播放器").appendingPathComponent(rel).path))
        let idea = try store.saveIdea(ClipMarkdown.body(note: "", item: ClipItem(id: "1", date: Date(), kind: .image, fingerprint: "x"), assetPath: rel), to: repo, nameHint: "截图")
        #expect(idea.url.lastPathComponent.hasSuffix("-截图.md"))
        // assets/ 不被当成灵感或项目
        let lib = try store.scan()
        #expect(lib.ideas.count == 1)
        #expect(lib.repos.filter { !$0.isInbox }.map(\.folder) == ["播放器"])
    }
}

@Suite struct IdeaAttachmentsTests {
    @Test func parse() {
        let item = ClipItem(id: "1", date: Date(), kind: .files, paths: ["/Users/me/方案 v2.pdf", "/tmp/a[1].txt"], fingerprint: "x")
        let body = ClipMarkdown.body(note: "看看这个\n第二行", item: item, assetPath: nil)
        let a = IdeaAttachments.parse(body)
        #expect(a.files == [.init(name: "方案 v2.pdf", path: "/Users/me/方案 v2.pdf"), .init(name: "a[1].txt", path: "/tmp/a[1].txt")])
        #expect(a.text == "看看这个\n第二行")

        let img = IdeaAttachments.parse("![](assets/2026-11-18-0034-截图.png)")
        #expect(img.images == ["assets/2026-11-18-0034-截图.png"] && img.text.isEmpty)
        let img2 = IdeaAttachments.parse("![](assets/x.png)\n\n首页截图")
        #expect(img2.images == ["assets/x.png"] && img2.text == "首页截图")

        // 普通文字、中间出现的链接不动
        let plain = IdeaAttachments.parse("想法 ![](a.png)\n[x](https://a.com)")
        #expect(plain.isEmpty && plain.text == "想法 ![](a.png)\n[x](https://a.com)")
        #expect(IdeaAttachments.parse("[x](https://a.com)").isEmpty)
    }
}
