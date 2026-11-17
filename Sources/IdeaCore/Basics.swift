import Foundation

// MARK: - ULID

public enum ULID {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    nonisolated(unsafe) private static var lastTime: UInt64 = 0
    nonisolated(unsafe) private static var lastRandom: [UInt8] = []
    private static let lock = NSLock()

    /// 26 位 Crockford Base32；同一毫秒内随机部分递增，保证单调。
    public static func make(date: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        let ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var random: [UInt8]
        if ms <= lastTime, lastRandom.count == 10 {
            random = lastRandom
            var i = 9
            while i >= 0 {
                if random[i] == 0xFF { random[i] = 0; i -= 1 } else { random[i] += 1; break }
            }
        } else {
            random = (0..<10).map { _ in UInt8.random(in: 0...255) }
        }
        let time = max(ms, lastTime)
        lastTime = time
        lastRandom = random

        var chars: [Character] = []
        var t = time
        var timeChars = [Character](repeating: "0", count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            timeChars[i] = alphabet[Int(t & 31)]
            t >>= 5
        }
        chars += timeChars
        // 80 位随机数 → 16 个字符
        var bits: UInt64 = 0
        var bitCount = 0
        for byte in random {
            bits = (bits << 8) | UInt64(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                chars.append(alphabet[Int((bits >> UInt64(bitCount)) & 31)])
            }
        }
        return String(chars)
    }
}

// MARK: - 日期

public enum ISODate {
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    public static func string(_ d: Date) -> String { formatter.string(from: d) }
    public static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = formatter.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: s)
    }
}

// MARK: - 文件名

public enum FileNamer {
    static let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|#^[]").union(.newlines).union(.controlCharacters)

    /// `YYYY-MM-DD-HHmm-<正文前 20 字>.md`
    public static func baseName(for body: String, date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd-HHmm"
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return df.string(from: date) + "-" + summary(firstLine)
    }

    public static func summary(_ text: String, limit: Int = 20) -> String {
        var cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { illegal.contains($0) ? " " : $0 }))
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = String(cleaned.trimmingCharacters(in: .whitespaces).prefix(limit))
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    /// 在目录下找一个不重名的 `<base>.md`，重名加 `-2`、`-3`。
    public static func uniqueURL(in dir: URL, base: String, ext: String = "md", fm: FileManager = .default) -> URL {
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// 仓库名是否合法：非空、不含路径非法字符、不以点开头、不是保留名。
    public static func repoNameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "名称不能为空" }
        if trimmed.unicodeScalars.contains(where: { CharacterSet(charactersIn: "/:\\").union(.newlines).contains($0) }) {
            return "名称不能包含 / : \\"
        }
        if trimmed.hasPrefix(".") { return "名称不能以 . 开头" }
        if trimmed.compare(LibraryStore.inboxFolder, options: .caseInsensitive) == .orderedSame || trimmed == "收件箱" || trimmed == "未归类" {
            return "「\(trimmed)」是保留名称"
        }
        if trimmed.count > 60 { return "名称太长" }
        return nil
    }
}

// MARK: - 原子写

public enum AtomicWriter {
    public static func write(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try Data(text.utf8).write(to: tmp, options: [])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
