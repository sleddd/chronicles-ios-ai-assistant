import Foundation

/// Patterns worth a gentle word (plan: "The exception: when he's genuinely
/// concerned"). Simple rules on the device; Smith raises each at most once a week.
public struct Concern: Equatable, Sendable, Identifiable {
    public enum Area: String, Codable, CaseIterable, Sendable {
        case habits, medication, deadlines, goals, mood
        public var label: String {
            switch self {
            case .habits: "Habits"; case .medication: "Medication"; case .deadlines: "Overdue deadlines"
            case .goals: "Stalled goals"; case .mood: "Heavy weeks"
            }
        }
    }
    /// Stable key, e.g. "habit:123", so the once-a-week rule tracks it.
    public var id: String
    public var area: Area
    /// A note for Smith's context, not words to say verbatim.
    public var note: String
}

public struct ConcernSettings: Codable, Equatable, Sendable {
    public var disabledAreas: Set<Concern.Area> = []
    /// Concern id → day it was last raised.
    public var lastRaised: [String: String] = [:]
    /// Concern id → day the person said "not now" / "I know".
    public var dismissed: [String: String] = [:]
    public init() {}
}

public enum Concerns {
    public static let quietDays = 7

    public static func find(in s: ChroniclesSnapshot, journal: [JournalRecord], today: String,
                            neverMention: Set<String>) -> [Concern] {
        var out: [Concern] = []
        for h in s.habits where h.isActive {
            let last = h.lastDone(before: today)
            let since = last.map { Day.daysBetween($0, today) } ?? Int.max
            // Only for habits that were being done at some point, and only after two weeks.
            guard last != nil, since >= 14 else { continue }
            let weeks = since / 7
            out.append(Concern(id: "habit:\(h.id)", area: .habits,
                               note: "\(h.name) hasn't been checked off in \(weeks) weeks (last \(Day.short(last!)))."))
        }
        let weekAgo = Day.addDays(today, -7)
        let missed = s.doseLogs.filter { $0.date >= weekAgo && $0.date < today && $0.status == "skipped" && !$0.asNeeded }
        if missed.count >= 2 {
            let names = Set(missed.compactMap { l in s.medications.first { $0.id == l.medicationID }?.name }).sorted()
            out.append(Concern(id: "doses:\(names.joined(separator: ","))", area: .medication,
                               note: "\(missed.count) medication doses marked skipped in the past week (\(names.joined(separator: ", ")))."))
        }
        let overdue = s.tasks.filter { $0.isOpen && $0.status != .backlog && ($0.deadline ?? "9999") < today }
        if overdue.count >= 3 {
            out.append(Concern(id: "overdue", area: .deadlines, note: "\(overdue.count) tasks are past their deadline."))
        }
        for g in s.goals where g.status != "completed" && g.status != "paused" {
            if let t = g.targetDate, t < today {
                out.append(Concern(id: "goal:\(g.id)", area: .goals,
                                   note: "The goal \"\(g.title)\" passed its target date (\(Day.short(t))) and isn't complete."))
            }
        }
        let heavy = JournalDigest.heavyWeeks(journal, today: today, neverMention: neverMention)
        if heavy >= 2 {
            out.append(Concern(id: "mood", area: .mood, note: "The journal's general tone has been heavy for \(heavy) weeks."))
        }
        return out
    }

    /// The ones Smith may raise today: area on, not raised or dismissed in the last week.
    public static func raisable(_ all: [Concern], settings: ConcernSettings, today: String) -> [Concern] {
        all.filter { c in
            guard !settings.disabledAreas.contains(c.area) else { return false }
            let recent = { (d: String?) in d.map { Day.daysBetween($0, today) < quietDays } ?? false }
            return !recent(settings.lastRaised[c.id]) && !recent(settings.dismissed[c.id])
        }
    }
}
