import Foundation
import IdeaCore

// 命令行调试工具：不开界面验证存储与匹配。
var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
let rootArg = take("--root")
let root = rootArg.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? LibraryStore.resolveRoot()
let store = LibraryStore(root: root)

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
func lib() -> Library { do { return try store.scan() } catch { fail("扫描失败：\(error.localizedDescription)") } }
func findRepo(_ name: String, _ l: Library) -> Repo {
    if let r = l.allRepos.first(where: { $0.folder == name || $0.displayName == name || $0.shortcode == name }) { return r }
    fail("没有仓库：\(name)")
}

let usage = """
用法: ideactl [--root DIR] <命令>
  repos                         列出仓库（顺序 = tag 顺序）
  repo add <名称> [--short x] [--desc 描述]
  repo edit <名称> [--name 新名] [--short x] [--desc 描述]
  repo rm <名称>                删除仓库（灵感移入收件箱）
  save <文本> [--repo 名称]      保存一条灵感（不给 --repo 即收件箱）
  ls [仓库]                     列出灵感
  mv <文件> <仓库>               移动灵感
  rm <文件>                     删除灵感（进废纸篓）
  match <查询>                  @ 补全匹配结果
  grep <词>                     跨仓库搜索
"""

guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()

switch cmd {
case "repos":
    let l = lib()
    print("Inbox\t收件箱\t\(l.count(in: l.inbox)) 条")
    for (i, r) in l.repos.enumerated() {
        print("\(i + 1)\t\(r.folder)\t@\(r.shortcode)\tcolor=\(r.colorIndex)\t\(l.count(in: r)) 条")
    }
case "repo":
    guard let sub = args.first else { fail(usage) }
    args.removeFirst()
    switch sub {
    case "add":
        let sc = take("--short"), desc = take("--desc") ?? ""
        guard let name = args.first else { fail(usage) }
        do { let r = try store.createRepo(name: name, shortcode: sc, description: desc, in: lib()); print("已建 \(r.folder) @\(r.shortcode)") }
        catch { fail(error.localizedDescription) }
    case "edit":
        let newName = take("--name"), sc = take("--short"), desc = take("--desc")
        guard let name = args.first else { fail(usage) }
        let l = lib(); let r = findRepo(name, l)
        do {
            let u = try store.updateRepo(r, name: newName ?? r.folder, shortcode: sc ?? r.shortcode, description: desc ?? r.description, in: l)
            print("已改 \(u.folder) @\(u.shortcode) id=\(u.id)")
        } catch { fail(error.localizedDescription) }
    case "rm":
        guard let name = args.first else { fail(usage) }
        do { let n = try store.deleteRepo(findRepo(name, lib())); print("已删除，\(n) 条灵感移入收件箱") }
        catch { fail(error.localizedDescription) }
    default: fail(usage)
    }
case "save":
    let repoName = take("--repo")
    guard let text = args.first else { fail(usage) }
    let l = lib()
    do { let i = try store.saveIdea(text, to: repoName.map { findRepo($0, l) }); print(i.url.path) }
    catch { fail(error.localizedDescription) }
case "ls":
    let l = lib()
    let list = args.first.map { l.ideas(in: findRepo($0, l)) } ?? l.ideas.sorted { $0.created > $1.created }
    for i in list { print("\(i.repoFolder)/\(i.url.lastPathComponent)\t\(i.body.prefix(40).replacingOccurrences(of: "\n", with: " "))") }
case "mv":
    guard args.count >= 2 else { fail(usage) }
    let l = lib()
    let path = URL(fileURLWithPath: args[0]).standardizedFileURL.path
    guard let idea = l.ideas.first(where: { $0.url.standardizedFileURL.path == path || "\($0.repoFolder)/\($0.url.lastPathComponent)" == args[0] }) else { fail("找不到文件") }
    do { let m = try store.moveIdea(idea, to: findRepo(args[1], l)); print(m.url.path) } catch { fail(error.localizedDescription) }
case "rm":
    guard let p = args.first else { fail(usage) }
    let l = lib()
    let path = URL(fileURLWithPath: p).standardizedFileURL.path
    guard let idea = l.ideas.first(where: { $0.url.standardizedFileURL.path == path || "\($0.repoFolder)/\($0.url.lastPathComponent)" == p }) else { fail("找不到文件") }
    do { let t = try store.trashIdea(idea); print("已移到废纸篓：\(t?.path ?? "?")") } catch { fail(error.localizedDescription) }
case "match":
    let l = lib()
    for r in RepoMatcher(repos: l.repos).match(args.first ?? "") { print("\(r.folder)\t@\(r.shortcode)\t\(Pinyin.initials(r.folder))") }
case "grep":
    let l = lib()
    let hits = TextSearch.search(args.joined(separator: " "), in: l.ideas)
    for i in hits { print("\(i.repoFolder)\t\(i.body.prefix(60).replacingOccurrences(of: "\n", with: " "))") }
    print("共 \(hits.count) 条")
default:
    fail(usage)
}
