import Foundation

/// What's going on today, worked out from the snapshot. Used for the home
/// screen chips, the morning briefing and Smith's day context.
public struct DayOverview: Equatable, Sendable {
    public struct Event: Equatable, Sendable {
        public var title: String
        public var time: String?
        public var endTime: String?
        public var allDay: Bool
        public var location: String?
        public var isMeeting: Bool
    }
    public struct Dose: Equatable, Sendable {
        public var medication: String
        public var dosage: String
        public var time: String
        /// taken / skipped / pending
        public var status: String
    }

    public var today: String
    public var events: [Event]
    public var tasksToday: [PlanTask]
    public var overdue: [PlanTask]
    /// Open tasks with a deadline in the next 3 days (not already listed for today).
    public var deadlinesSoon: [PlanTask]
    public var doses: [Dose]
    public var bills: [BillDue]
    public var priorities: [String]
    /// An in-progress goal worth a mention, with its nearest target date.
    public var goalMention: Goal?

    public var openTasksToday: Int { tasksToday.filter(\.isOpen).count }

    public var nextEvent: Event? {
        events.first { !$0.allDay }
    }

    public static func make(_ s: ChroniclesSnapshot, today: String, billDays: Int = 3,
                            privateBillIDs: Set<String> = []) -> DayOverview {
        let events = s.calendar.flatMap { item -> [Event] in
            let occ = Recurrence.occurrences(start: item.startDate, rule: item.repeatRule, from: today, to: today)
            // A multi-day event without repeats also covers the days it spans.
            let spans = item.repeatRule == nil && item.startDate <= today && (item.endDate ?? item.startDate) >= today
            guard !occ.isEmpty || spans else { return [] }
            return [Event(title: item.title, time: item.allDay ? nil : item.startTime, endTime: item.endTime,
                          allDay: item.allDay || item.startTime == nil, location: item.location, isMeeting: item.isMeeting)]
        }.sorted { ($0.allDay ? "" : $0.time ?? "99") < ($1.allDay ? "" : $1.time ?? "99") }

        let open = s.tasks.filter(\.isOpen)
        let todays = s.tasks.filter { $0.scheduledDate == today || ($0.isOpen && $0.deadline == today) }
            .sorted(by: taskOrder)
        let overdue = open.filter { t in
            guard t.status != .backlog else { return false }
            if let d = t.deadline, d < today { return true }
            if let d = t.scheduledDate, d < today, t.deadline == nil || t.deadline! < today { return true }
            return false
        }.sorted(by: taskOrder)
        let soonEnd = Day.addDays(today, 3)
        let todayIDs = Set(todays.map(\.id))
        let deadlines = open.filter { t in
            guard let d = t.deadline else { return false }
            return d > today && d <= soonEnd && !todayIDs.contains(t.id)
        }.sorted { ($0.deadline ?? "") < ($1.deadline ?? "") }

        var doses: [Dose] = []
        for m in s.medications where m.isActive && m.frequency != "as_needed" {
            for time in m.scheduleTimes {
                let log = s.doseLogs.last { $0.medicationID == m.id && $0.date == today && $0.scheduledTime == String(time.prefix(5)) && !$0.asNeeded }
                doses.append(Dose(medication: m.name, dosage: m.dosage, time: String(time.prefix(5)), status: log?.status ?? "pending"))
            }
        }
        doses.sort { $0.time < $1.time }

        let priorities = s.priorities.map { $0.items.filter { !$0.done }.map(\.text) } ?? []

        let goal = s.goals.filter { $0.status == "in_progress" }
            .sorted { ($0.targetDate ?? "9999") < ($1.targetDate ?? "9999") }.first

        return DayOverview(today: today, events: events, tasksToday: todays, overdue: overdue, deadlinesSoon: deadlines,
                           doses: doses, bills: BillsDue.upcoming(s.bills, today: today, days: billDays, privateIDs: privateBillIDs),
                           priorities: priorities, goalMention: goal)
    }

    static func taskOrder(_ a: PlanTask, _ b: PlanTask) -> Bool {
        (a.scheduledTime ?? "99", a.priorityRank, a.title) < (b.scheduledTime ?? "99", b.priorityRank, b.title)
    }

    /// Plain text for Smith's context. Facts only; Smith decides what to say.
    public func contextText(includeGoal: Bool = true) -> String {
        var lines: [String] = []
        lines.append(events.isEmpty ? "Events today: none." : "Events today:\n" + events.map { e in
            let when = e.allDay ? "all day" : [e.time, e.endTime].compactMap { $0 }.joined(separator: "–")
            return "- \(when): \(e.title)\(e.isMeeting ? " (meeting)" : "")\(e.location.map { " at \($0)" } ?? "")"
        }.joined(separator: "\n"))
        lines.append(tasksToday.isEmpty ? "Tasks planned today: none." : "Tasks planned today:\n" + tasksToday.map(taskLine).joined(separator: "\n"))
        if !overdue.isEmpty { lines.append("Overdue tasks:\n" + overdue.prefix(10).map(taskLine).joined(separator: "\n")) }
        if !deadlinesSoon.isEmpty {
            lines.append("Deadlines in the next 3 days:\n" + deadlinesSoon.map { "- \($0.title), due \(Day.relative($0.deadline ?? "", today: today))" }.joined(separator: "\n"))
        }
        if !doses.isEmpty {
            lines.append("Medication doses today:\n" + doses.map { "- \($0.time) \($0.medication)\($0.dosage.isEmpty ? "" : " \($0.dosage)"): \($0.status)" }.joined(separator: "\n"))
        }
        lines.append(bills.isEmpty ? "Bills due in the next 3 days: none." : "Bills (names and dates only):\n" + bills.map { "- " + $0.line(today: today) }.joined(separator: "\n"))
        if !priorities.isEmpty { lines.append("Today's priorities list: " + priorities.joined(separator: "; ")) }
        if includeGoal, let g = goalMention {
            lines.append("A goal in progress: \(g.title)\(g.targetDate.map { ", target \(Day.short($0))" } ?? "").")
        }
        return lines.joined(separator: "\n\n")
    }

    func taskLine(_ t: PlanTask) -> String {
        var s = "- \(t.title)"
        var bits: [String] = []
        if let time = t.scheduledTime { bits.append(time) } else if let part = t.scheduledPart { bits.append(part) }
        if t.priority != "none" { bits.append("\(t.priority) priority") }
        if t.status == .done { bits.append("done") } else if t.status == .inProgress { bits.append("in progress") }
        if let d = t.deadline, d != today { bits.append("deadline \(Day.relative(d, today: today))") }
        if !bits.isEmpty { s += " (\(bits.joined(separator: ", ")))" }
        return s
    }
}
