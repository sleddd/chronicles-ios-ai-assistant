import Foundation

/// A calendar day as "yyyy-MM-dd", the form Chronicles uses. Strings compare in date order.
public enum Day {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func parse(_ s: String) -> (y: Int, m: Int, d: Int)? {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return (p[0], p[1], p[2])
    }

    public static func isValid(_ s: String?) -> Bool { s.flatMap(parse) != nil }

    static func date(_ s: String) -> Date? {
        guard let (y, m, d) = parse(s) else { return nil }
        return utc.date(from: DateComponents(year: y, month: m, day: d))
    }

    static func string(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Today (or `date`) in the given time zone.
    public static func key(for date: Date = Date(), in tz: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func addDays(_ s: String, _ n: Int) -> String {
        guard let d = date(s), let r = utc.date(byAdding: .day, value: n, to: d) else { return s }
        return string(r)
    }

    public static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        let d = utc.date(from: DateComponents(year: y, month: m, day: 1))!
        return utc.range(of: .day, in: .month, for: d)!.count
    }

    /// `s` moved by whole months, keeping its day, clamped to short months (Jan 31 → Feb 28/29).
    public static func addMonthsClamped(_ s: String, _ months: Int) -> String {
        guard let (y, m, d) = parse(s) else { return s }
        let total = (m - 1) + months
        let ny = y + Int(floor(Double(total) / 12))
        let nm = ((total % 12) + 12) % 12 + 1
        return String(format: "%04d-%02d-%02d", ny, nm, min(d, daysInMonth(ny, nm)))
    }

    public static func daysBetween(_ from: String, _ to: String) -> Int {
        guard let a = date(from), let b = date(to) else { return 0 }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    /// 1 = Sunday … 7 = Saturday
    public static func weekday(_ s: String) -> Int {
        guard let d = date(s) else { return 1 }
        return utc.component(.weekday, from: d)
    }

    /// "Mon 1 Dec"
    public static func short(_ s: String) -> String {
        guard let d = date(s) else { return s }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }

    /// "Tuesday" / "today" / "tomorrow", relative to `today`.
    public static func relative(_ s: String, today: String) -> String {
        switch daysBetween(today, s) {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6, -6 ... -2:
            guard let d = date(s) else { return s }
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE"
            return f.string(from: d)
        default: return short(s)
        }
    }
}
