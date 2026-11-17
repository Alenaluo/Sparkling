import Foundation

/// 主窗口列表按日期分组（design §5.1）：今天 · 11月17日 周一 / 昨天 · … / 11月12日 周三 / 跨年加年份
public struct DateGroup: Identifiable, Equatable {
    public let id: Date        // 当天 0 点
    public let title: String
    public let ideas: [Idea]
}

public enum DateGrouping {
    public static func groups(_ ideas: [Idea], now: Date = Date(), calendar: Calendar = .current) -> [DateGroup] {
        let sorted = ideas.sorted { $0.created > $1.created }
        var order: [Date] = []
        var buckets: [Date: [Idea]] = [:]
        for idea in sorted {
            let day = calendar.startOfDay(for: idea.created)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(idea)
        }
        return order.map { DateGroup(id: $0, title: title(for: $0, now: now, calendar: calendar), ideas: buckets[$0]!) }
    }

    public static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        let wd = weekdays[(c.weekday ?? 1) - 1]
        let sameYear = c.year == calendar.component(.year, from: now)
        let date = sameYear ? "\(c.month!)月\(c.day!)日 \(wd)" : "\(c.year!)年\(c.month!)月\(c.day!)日 \(wd)"
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(day, inSameDayAs: today) { return "今天 · \(date)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: y) { return "昨天 · \(date)" }
        return date
    }

    /// 条目左侧时刻 10:42
    public static func time(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
