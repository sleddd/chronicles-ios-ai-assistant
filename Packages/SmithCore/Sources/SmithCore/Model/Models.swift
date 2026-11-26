import Foundation

// What Smith keeps from Chronicles. Only the fields Smith needs: no task or
// event notes, no finance amounts, no journal text, no wellness notes.

public struct PlanTask: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case backlog, todo, inProgress, done }
    public var id: String
    public var title: String
    public var status: Status
    public var scheduledDate: String?
    public var scheduledTime: String?
    /// "morning" / "noon" / "night"
    public var scheduledPart: String?
    public var deadline: String?
    public var deadlineTime: String?
    /// urgent / high / medium / low / none
    public var priority: String
    public var goalID: String?
    public var milestoneID: String?
    public var openChecklistItems: Int
    public var createdDay: String?

    public var isOpen: Bool { status != .done }
    public var priorityRank: Int { ["urgent": 0, "high": 1, "medium": 2, "low": 3][priority] ?? 4 }
}

public struct Goal: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// new / planned / in_progress / paused / completed
    public var status: String
    public var longTerm: Bool
    public var category: String?
    public var startOn: String?
    public var targetDate: String?
}

public struct Milestone: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// not_started / planned / in_progress / completed
    public var status: String
    public var goalID: String?
    public var startOn: String?
    public var targetDate: String?
}

public struct CalendarItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var isMeeting: Bool
    public var title: String
    public var startDate: String
    public var startTime: String?
    public var endDate: String?
    public var endTime: String?
    public var allDay: Bool
    public var location: String?
    public var attendees: String?
    public var repeatRule: RepeatRule?
}

public struct Habit: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var targetCount: Int
    /// "day" / "week"
    public var targetPeriod: String
    /// 0 = Sunday; empty = any day
    public var days: [Int]
    public var isActive: Bool
    public var goalID: String?
    /// "YYYY-MM" → one base-36 count per day (Chronicles' `habitLog`).
    public var log: [String: String]

    /// Check-ins recorded on a day.
    public func count(on day: String) -> Int {
        guard let (_, _, d) = Day.parse(day), let month = log[String(day.prefix(7))] else { return 0 }
        let chars = Array(month)
        guard d - 1 < chars.count else { return 0 }
        return Int(String(chars[d - 1]), radix: 36) ?? 0
    }

    /// The most recent day with a check-in, on or before `today`, looking back up to a year.
    public func lastDone(before today: String) -> String? {
        var d = today
        for _ in 0..<366 {
            if count(on: d) > 0 { return d }
            d = Day.addDays(d, -1)
        }
        return nil
    }

    public func isScheduled(on day: String) -> Bool {
        targetPeriod != "day" || days.isEmpty || days.contains(Day.weekday(day) - 1)
    }
}

public struct Medication: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var dosage: String
    /// once_daily / twice_daily / … / as_needed / custom
    public var frequency: String
    public var scheduleTimes: [String]
    public var isActive: Bool
}

public struct DoseLog: Codable, Equatable, Sendable {
    public var date: String
    public var medicationID: String
    /// "HH:MM"
    public var scheduledTime: String
    /// taken / skipped / pending
    public var status: String
    public var asNeeded: Bool
}

public struct PriorityList: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable { public var text: String; public var done: Bool }
    public var day: String
    public var items: [Item]
}

public struct VisionArea: Codable, Equatable, Sendable { public var name: String; public var vision: String? }

public struct Vision: Codable, Equatable, Sendable {
    public var overall: String?
    public var areas: [VisionArea]
}

/// Everything Smith keeps from one Chronicles export (journal text excluded — see `journal`).
/// One day's wellness check-in (Chronicles' wellness card), without its notes.
public struct WellnessDay: Codable, Equatable, Sendable {
    public var entryID: String
    public var date: String
    public var mood = 0              // 1–5, 0 = not set
    public var sleepHours = 0.0
    public var sleepQuality = 0      // how rested, 1–5
    public var water = 0
    public var waterGoal = 8
    public var stress = 0            // 1 very low – 5 very high
    public var workDay = 0           // 1–5
    public var social = 0            // 1–5
    public var procrastination = 0   // 1 not at all – 5 all day
    public var eating: String?       // too_little | just_right | too_much
    public var wokeAtNight: Bool?
    public var dreamed: Bool?

    public init(entryID: String, date: String) { self.entryID = entryID; self.date = date }

    init?(entryID: String, fields cf: JSONValue) {
        guard let date = cf["date"]?.string, Day.isValid(date) else { return nil }
        self.init(entryID: entryID, date: String(date.prefix(10)))
        mood = cf["moodScore"]?.int ?? 0
        sleepHours = cf["sleepHours"]?.double ?? 0
        sleepQuality = cf["sleepQuality"]?.int ?? 0
        water = cf["waterGlasses"]?.int ?? 0
        waterGoal = cf["waterGoal"]?.int ?? 8
        stress = cf["stress"]?.int ?? 0
        workDay = cf["workDay"]?.int ?? 0
        social = cf["social"]?.int ?? 0
        procrastination = cf["procrastination"]?.int ?? 0
        eating = cf["eating"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        wokeAtNight = cf["wokeAtNight"]?.bool
        dreamed = cf["dreamed"]?.bool
    }

    static let moods = ["Very low", "Low", "Okay", "Good", "Great"]
    static let quality = ["Poor", "Fair", "OK", "Good", "Great"]
    static let rested = ["Not at all", "A little", "Somewhat", "Mostly", "Fully"]
    static let stressWords = ["Very low", "Low", "Moderate", "High", "Very high"]
    static let procrastinationWords = ["Not at all", "A little", "Some", "A lot", "All day"]

    /// What's filled in, in words ("mood Good; slept 7h, rested Mostly; water 3 of 8 …").
    public var line: String {
        func word(_ v: Int, _ words: [String]) -> String? { (1...5).contains(v) ? words[v - 1] : nil }
        var bits: [String] = []
        if let m = word(mood, Self.moods) { bits.append("mood \(m)") }
        if sleepHours > 0 { bits.append("slept \(sleepHours.formatted())h") }
        if let r = word(sleepQuality, Self.rested) { bits.append("felt rested: \(r)") }
        bits.append("water \(water) of \(waterGoal) glasses")
        if let s = word(stress, Self.stressWords) { bits.append("stress \(s)") }
        if let w = word(workDay, Self.quality) { bits.append("work day \(w)") }
        if let s = word(social, Self.quality) { bits.append("social time \(s)") }
        if let p = word(procrastination, Self.procrastinationWords) { bits.append("procrastinated \(p)") }
        if let e = eating { bits.append("ate \(e.replacingOccurrences(of: "_", with: " "))") }
        if let w = wokeAtNight { bits.append(w ? "woke in the night" : "slept through") }
        if let d = dreamed { bits.append(d ? "remembers dreaming" : "no dreams remembered") }
        return bits.joined(separator: "; ")
    }
}

public struct ChroniclesSnapshot: Codable, Equatable, Sendable {
    public var exportedAt: Date
    public var displayName: String?
    public var timeZone: String?
    public var tasks: [PlanTask] = []
    public var goals: [Goal] = []
    public var milestones: [Milestone] = []
    public var calendar: [CalendarItem] = []
    public var habits: [Habit] = []
    public var medications: [Medication] = []
    /// The last 60 days only.
    public var doseLogs: [DoseLog] = []
    public var priorities: PriorityList?
    public var vision = Vision(overall: nil, areas: [])
    public var bills: [BillSchedule] = []
    /// Topic id → name, for the "never mention" picker and journal topics.
    public var topics: [String: String] = [:]
    /// Wellness check-ins from the last week: the numbers and choices only (never the notes).
    public var wellness: [WellnessDay] = []

    public init(exportedAt: Date) { self.exportedAt = exportedAt }
}
