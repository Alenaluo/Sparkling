import Foundation

/// Markdown 文件头（`---` 包围的 YAML 子集）。
/// 只解析「key: 标量」行；其余行（列表、嵌套、注释）原样保留，写回时不丢。
public struct Frontmatter: Equatable, Sendable {
    public enum Line: Equatable, Sendable {
        case field(key: String, value: String)
        case raw(String)
    }

    public var lines: [Line] = []

    public init(lines: [Line] = []) { self.lines = lines }

    public subscript(key: String) -> String? {
        get {
            for case let .field(k, v) in lines where k == key { return v }
            return nil
        }
        set {
            if let idx = lines.firstIndex(where: { if case let .field(k, _) = $0 { return k == key }; return false }) {
                if let newValue { lines[idx] = .field(key: key, value: newValue) } else { lines.remove(at: idx) }
            } else if let newValue {
                lines.append(.field(key: key, value: newValue))
            }
        }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// 拆出文件头与正文。没有文件头时返回 nil 文件头与原文。
    public static func split(_ text: String) -> (Frontmatter?, String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return (nil, normalized) }
        let rest = normalized.dropFirst(4)
        var headerLines: [Substring] = []
        var remainder: Substring? = nil
        var cursor = rest.startIndex
        while cursor < rest.endIndex {
            let lineEnd = rest[cursor...].firstIndex(of: "\n") ?? rest.endIndex
            let line = rest[cursor..<lineEnd]
            if line == "---" || line == "..." {
                remainder = lineEnd < rest.endIndex ? rest[rest.index(after: lineEnd)...] : ""
                break
            }
            headerLines.append(line)
            cursor = lineEnd < rest.endIndex ? rest.index(after: lineEnd) : rest.endIndex
        }
        guard let body = remainder else { return (nil, normalized) }
        var fm = Frontmatter()
        for line in headerLines { fm.lines.append(parseLine(String(line))) }
        return (fm, String(body))
    }

    static func parseLine(_ line: String) -> Line {
        guard let first = line.first, first != " ", first != "\t", first != "#", first != "-",
              let colon = line.firstIndex(of: ":") else { return .raw(line) }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return .raw(line) }
        let afterColon = line[line.index(after: colon)...]
        if !afterColon.isEmpty && afterColon.first != " " { return .raw(line) }
        var value = afterColon.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value.hasPrefix("[") || value.hasPrefix("{") || value.hasPrefix("|") || value.hasPrefix(">") {
            return .raw(line) // 列表 / 嵌套 / 多行，原样保留
        }
        value = unquote(value)
        return .field(key: key, value: value)
    }

    static func unquote(_ v: String) -> String {
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            var out = ""
            var escaping = false
            for ch in v.dropFirst().dropLast() {
                if escaping {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaping = false
                } else if ch == "\\" { escaping = true } else { out.append(ch) }
            }
            return out
        }
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
            return String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // 去掉行尾注释（空格 + #）
        if let r = v.range(of: " #") { return String(v[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return v
    }

    static func quoteIfNeeded(_ v: String) -> String {
        // 只在 YAML 会误解时加引号：`: ` / ` #` / 行尾冒号 / 特殊开头字符 / 布尔与空值字样
        let startSpecial = CharacterSet(charactersIn: "-?:,[]{}#&*!|>'\"%@`")
        let needs = v.isEmpty
            || v.contains(": ") || v.hasSuffix(":") || v.contains(" #")
            || v.contains("\n") || v.contains("\t") || v.contains("\\") || v.contains("\"")
            || v.unicodeScalars.first.map { startSpecial.contains($0) } == true
            || v.hasPrefix(" ") || v.hasSuffix(" ")
            || ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(v.lowercased())
        guard needs else { return v }
        let escaped = v.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    public func render() -> String {
        var out = "---\n"
        for line in lines {
            switch line {
            case let .field(k, v): out += "\(k): \(Self.quoteIfNeeded(v))\n"
            case let .raw(r): out += r + "\n"
            }
        }
        out += "---\n"
        return out
    }

    /// 组合文件内容：文件头 + 正文（正文末尾保证一个换行）。
    public static func compose(_ fm: Frontmatter?, body: String) -> String {
        let trimmedBody = body.trimmingCharacters(in: .newlines)
        let head = fm.map { $0.render() } ?? ""
        return head + trimmedBody + "\n"
    }
}
