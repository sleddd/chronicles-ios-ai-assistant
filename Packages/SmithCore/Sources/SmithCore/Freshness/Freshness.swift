import Foundation

/// "I notice you're a day behind on updates." (plan, section 13)
public enum Freshness {
    public enum Threshold: Int, Codable, CaseIterable, Sendable {
        case oneDay = 1, twoDays = 2, never = 0
        public var label: String { switch self { case .oneDay: "After 1 day"; case .twoDays: "After 2 days"; case .never: "Never" } }
    }

    public struct Settings: Codable, Equatable, Sendable {
        public var threshold: Threshold = .oneDay
        public var exportReminders = true
        public var syncReminders = true
        public var installReminders = true
        /// The day the last nudge was given (once a day at most).
        public var lastNudgeDay: String?
        /// "Not today" pressed on this day.
        public var snoozedDay: String?
        public init() {}
    }

    public enum Nudge: Equatable, Sendable {
        case exportBehind(exportDay: String, days: Int)
        case behindMac(lastSync: String, days: Int)
        case installExpiring(on: String)

        /// Wording for Smith to use (warm, plain, no slang).
        public func line(today: String) -> String {
            switch self {
            case .exportBehind(_, let days) where days == 1:
                return "I notice you're a day behind on updates. My Chronicles info is from yesterday. Whenever you have a moment, run Export All and I'll bring myself up to date."
            case .exportBehind(let day, _):
                return "I'm working from \(Day.relative(day, today: today))'s plans, so I may be missing a few things. Whenever you have a moment, run Export All and I'll bring myself up to date."
            case .behindMac(_, let days):
                return "I'm \(days == 1 ? "a day" : "\(days) days") behind your Mac. Let's sync when you're back at your desk."
            case .installExpiring(let on):
                return "Just so you know, my iPad install expires \(Day.relative(on, today: today)). If you connect the iPad to Xcode tonight, I'll keep running without a break."
            }
        }
    }

    /// Days behind, or nil when the data is from today.
    public static func daysBehind(exportedAt: Date, today: String, tz: TimeZone = .current) -> Int? {
        let d = Day.daysBetween(Day.key(for: exportedAt, in: tz), today)
        return d > 0 ? d : nil
    }

    /// The nudge for today, if any (at most one a day; "Not today" silences it).
    public static func nudge(settings: Settings, today: String, exportedAt: Date?, lastSync: Date?, macHasNewer: Bool,
                             installExpires: Date?, isPad: Bool, tz: TimeZone = .current) -> Nudge? {
        guard settings.lastNudgeDay != today, settings.snoozedDay != today else { return nil }
        if isPad, settings.installReminders, let exp = installExpires {
            let day = Day.key(for: exp, in: tz)
            let left = Day.daysBetween(today, day)
            if left <= 2 { return .installExpiring(on: day) }
        }
        guard settings.threshold != .never else { return nil }
        if isPad, settings.syncReminders, macHasNewer, let lastSync,
           let days = daysBehind(exportedAt: lastSync, today: today, tz: tz), days >= settings.threshold.rawValue {
            return .behindMac(lastSync: Day.key(for: lastSync, in: tz), days: days)
        }
        if settings.exportReminders, let exportedAt,
           let days = daysBehind(exportedAt: exportedAt, today: today, tz: tz), days >= settings.threshold.rawValue {
            return .exportBehind(exportDay: Day.key(for: exportedAt, in: tz), days: days)
        }
        return nil
    }
}
