import Foundation

/// Repeating events and meetings. A port of Chronicles' `utils/recurrence.ts`:
/// daily/weekly step from the start; weekly lands on the chosen weekdays (the
/// start's weekday when none); monthly keeps the start's day (clamped to short
/// months); yearly the same month and day (Feb 29 → Feb 28). Until is inclusive.
public struct RepeatRule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case daily, weekly, monthly, yearly }
    public var kind: Kind
    public var every: Int
    /// Weekly: 0 = Sunday … 6 = Saturday
    public var days: [Int]
    /// Last day it may land on, "" = no end
    public var until: String

    public init(kind: Kind, every: Int = 1, days: [Int] = [], until: String = "") {
        self.kind = kind; self.every = every; self.days = days; self.until = until
    }

    /// From an entry's custom fields; nil when it doesn't repeat.
    public init?(fields cf: JSONValue) {
        guard let raw = cf["repeat"]?.string, let kind = Kind(rawValue: raw) else { return nil }
        let everyRaw = cf["repeatEvery"].flatMap { $0.double ?? $0.string.flatMap(Double.init) } ?? 1
        let every = max(1, min(99, Int(everyRaw.isFinite ? everyRaw : 1)))
        let days = Array(Set((cf["repeatDays"]?.array ?? []).compactMap { $0.int ?? $0.string.flatMap(Int.init) }
            .filter { (0...6).contains($0) })).sorted()
        let until = cf["repeatUntil"]?.string.flatMap { Day.isValid($0) && $0.count == 10 ? $0 : nil } ?? ""
        self.init(kind: kind, every: every, days: days, until: until)
    }
}

public enum Recurrence {
    /// The days in [from, to] (inclusive) an entry starting on `start` lands on, oldest first.
    public static func occurrences(start: String, rule: RepeatRule?, from: String, to: String, limit: Int = 1000) -> [String] {
        guard Day.isValid(start), start.count == 10 else { return [] }
        guard let rule else { return start >= from && start <= to ? [start] : [] }
        let last = !rule.until.isEmpty && rule.until < to ? rule.until : to
        let first = start > from ? start : from
        if first > last { return [] }
        var out: [String] = []
        func push(_ d: String) { if d >= first && d <= last && out.count < limit { out.append(d) } }
        let every = rule.every

        switch rule.kind {
        case .daily:
            let skip = max(0, Int(ceil(Double(Day.daysBetween(start, first)) / Double(every))))
            var d = Day.addDays(start, skip * every)
            while d <= last && out.count < limit { push(d); d = Day.addDays(d, every) }
        case .weekly:
            let wd = { (s: String) in Day.weekday(s) - 1 } // 0 = Sunday
            let days = rule.days.isEmpty ? [wd(start)] : rule.days
            let weekOf = { (s: String) in Day.addDays(s, -wd(s)) }
            let startWeek = weekOf(start)
            let weeks = max(0, Int(floor(Double(Day.daysBetween(startWeek, weekOf(first))) / 7 / Double(every))))
            var w = Day.addDays(startWeek, weeks * 7 * every)
            while w <= last && out.count < limit {
                for day in days { push(Day.addDays(w, day)) }
                w = Day.addDays(w, 7 * every)
            }
        case .monthly:
            guard let s = Day.parse(start), let f = Day.parse(first) else { return [] }
            var i = max(0, Int(floor(Double((f.y - s.y) * 12 + f.m - s.m) / Double(every))) - 1) * every
            while true {
                let d = dayOfMonth(s.y, s.m + i, s.d)
                if d > last || out.count >= limit { break }
                push(d); i += every
            }
        case .yearly:
            guard let s = Day.parse(start), let f = Day.parse(first) else { return [] }
            var y = max(0, Int(floor(Double(f.y - s.y) / Double(every))) - 1) * every
            while true {
                let d = dayOfMonth(s.y + y, s.m, s.d)
                if d > last || out.count >= limit { break }
                push(d); y += every
            }
        }
        return out
    }

    /// Day `day` of month `m` (may overflow past 12) in year `y`, clamped to the month's last day.
    static func dayOfMonth(_ y: Int, _ m: Int, _ day: Int) -> String {
        let total = m - 1
        let ny = y + Int(floor(Double(total) / 12))
        let nm = ((total % 12) + 12) % 12 + 1
        return String(format: "%04d-%02d-%02d", ny, nm, min(day, Day.daysInMonth(ny, nm)))
    }
}
