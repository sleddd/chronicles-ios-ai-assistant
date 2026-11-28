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
        public var medicationID: String = ""
    }
    /// A habit due today: check-ins so far and how many it wants.
    public struct HabitToday: Equatable, Sendable {
        public var id: String
        public var name: String
        public var count: Int
        public var target: Int
        /// Done for today: the day's target reached (a weekly habit: checked in today).
        public var done: Bool { count >= target }
    }
    /// One routine at one of its times today.
    public struct ExerciseSlot: Equatable, Sendable {
        public var routine: Routine
        public var time: String
        public var key: String
        /// The Exercise entry logged for it, when it's done.
        public var sessionID: String?
        public var done: Bool { sessionID != nil }
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
    /// Today's wellness check-in, if there is one.
    public var wellness: WellnessDay? = nil
    /// Task id → what's still in the way of it, in words ("Get passport", "waiting on Dana").
    public var blockedBy: [String: [String]] = [:]
    /// Today's priorities with whether each is ticked off, in their order.
    public var priorityItems: [PriorityList.Item] = []
    public var wins: [WinsList.Item] = []
    /// Every active shopping list, newest first (the first is the one Chronicles' dashboard shows).
    public var shoppingLists: [ShoppingList] = []
    public var habits: [HabitToday] = []
    public var exercise: [ExerciseSlot] = []

    public var openTasksToday: Int { tasksToday.filter(\.isOpen).count }

    public var nextEvent: Event? {
        events.first { !$0.allDay }
    }

    /// Open tasks for today and overdue ones that something is in the way of.
    public var blockedTasks: [PlanTask] {
        (tasksToday + overdue).filter { $0.isOpen && !(blockedBy[$0.id] ?? []).isEmpty }
    }

    /// The next event still to come at `time` ("HH:MM"), else nil.
    public func nextEvent(after time: String) -> Event? {
        events.first { !$0.allDay && ($0.time ?? "") >= time }
    }

    /// The first open task for today that nothing is blocking: what to get on with.
    public var nextTask: PlanTask? {
        tasksToday.first { $0.isOpen && (blockedBy[$0.id] ?? []).isEmpty }
            ?? overdue.first { (blockedBy[$0.id] ?? []).isEmpty }
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
                doses.append(Dose(medication: m.name, dosage: m.dosage, time: String(time.prefix(5)), status: log?.status ?? "pending", medicationID: m.id))
            }
        }
        doses.sort { $0.time < $1.time }

        let priorities = s.priorities.map { $0.items.filter { !$0.done }.map(\.text) } ?? []
        let habits = s.habits.filter { $0.isActive && $0.isScheduled(on: today) }.map { h in
            HabitToday(id: h.id, name: h.name, count: h.count(on: today), target: h.targetPeriod == "day" ? max(1, h.targetCount) : 1)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let exercise = (s.routines ?? []).filter { $0.runs(on: today) }.flatMap { r in
            r.times.map { t in
                let key = r.linkKey(day: today, time: t)
                return ExerciseSlot(routine: r, time: String(t.prefix(5)), key: key, sessionID: s.routineSessions?[key])
            }
        }.sorted { ($0.time, $0.routine.name) < ($1.time, $1.routine.name) }
        var blocked: [String: [String]] = [:]
        for t in todays + overdue + deadlines {
            let words = t.blockerWords(in: s.tasks)
            if !words.isEmpty { blocked[t.id] = words }
        }

        let goal = s.goals.filter { $0.status == "in_progress" }
            .sorted { ($0.targetDate ?? "9999") < ($1.targetDate ?? "9999") }.first

        return DayOverview(today: today, events: events, tasksToday: todays, overdue: overdue, deadlinesSoon: deadlines,
                           doses: doses, bills: BillsDue.upcoming(s.bills, today: today, days: billDays, privateIDs: privateBillIDs),
                           priorities: priorities, goalMention: goal, wellness: s.wellness.first { $0.date == today },
                           blockedBy: blocked, priorityItems: s.priorities?.items ?? [],
                           wins: s.wins?.items ?? [], shoppingLists: s.shoppingLists ?? [],
                           habits: habits, exercise: exercise)
    }

    static func taskOrder(_ a: PlanTask, _ b: PlanTask) -> Bool {
        (a.scheduledTime ?? "99", a.priorityRank, a.title) < (b.scheduledTime ?? "99", b.priorityRank, b.title)
    }

    /// Plain text for Smith's context. Facts only; Smith decides what to say.
    public func contextText(includeGoal: Bool = true) -> String {
        var lines: [String] = []
        lines.append(wellness.map { "Wellness check-in today: \($0.line)." } ?? "Wellness check-in today: not filled in yet.")
        lines.append(events.isEmpty ? "Events today: none." : "Events today:\n" + events.map { e in
            let when = e.allDay ? "all day" : [e.time, e.endTime].compactMap { $0 }.joined(separator: "–")
            return "- \(when): \(e.title)\(e.isMeeting ? " (meeting)" : "")\(e.location.map { " at \($0)" } ?? "")"
        }.joined(separator: "\n"))
        lines.append(tasksToday.isEmpty ? "Tasks planned today: none." : "Tasks planned today:\n" + tasksToday.map(taskLine).joined(separator: "\n"))
        if !overdue.isEmpty { lines.append("Overdue tasks:\n" + overdue.prefix(10).map(taskLine).joined(separator: "\n")) }
        if !deadlinesSoon.isEmpty {
            lines.append("Deadlines in the next 3 days:\n" + deadlinesSoon.map { t in
                "- \(t.title), due \(Day.relative(t.deadline ?? "", today: today))" + ((blockedBy[t.id] ?? []).isEmpty ? "" : " (blocked by: \(blockedBy[t.id]!.joined(separator: "; ")))")
            }.joined(separator: "\n"))
        }
        if !doses.isEmpty {
            lines.append("Medication doses today:\n" + doses.map { "- \($0.time) \($0.medication)\($0.dosage.isEmpty ? "" : " \($0.dosage)"): \($0.status)" }.joined(separator: "\n"))
        }
        lines.append(bills.isEmpty ? "Bills due in the next 3 days: none." : "Bills (names and dates only):\n" + bills.map { "- " + $0.line(today: today) }.joined(separator: "\n"))
        if !priorities.isEmpty { lines.append("Today's priorities list: " + priorities.joined(separator: "; ")) }
        if !habits.isEmpty {
            lines.append("Habits today: " + habits.map { "\($0.name) \($0.done ? "done" : $0.target > 1 ? "\($0.count) of \($0.target)" : "not yet")" }.joined(separator: "; "))
        }
        if !exercise.isEmpty {
            lines.append("Exercise today: " + exercise.map { "\($0.time) \($0.routine.name) \($0.done ? "done" : "not yet")" }.joined(separator: "; "))
        }
        if !wins.isEmpty { lines.append("Wins list: " + wins.map(\.text).joined(separator: "; ")) }
        for list in shoppingLists {
            let toGet = list.items.filter { !$0.checked }.map(\.name)
            lines.append("Shopping list (\(list.title)): " + (toGet.isEmpty ? "nothing left to get." : "still to get: " + toGet.joined(separator: ", ")))
        }
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
        if let b = blockedBy[t.id], !b.isEmpty, t.isOpen { bits.append("blocked by: \(b.joined(separator: "; "))") }
        if !bits.isEmpty { s += " (\(bits.joined(separator: ", ")))" }
        return s
    }
}
