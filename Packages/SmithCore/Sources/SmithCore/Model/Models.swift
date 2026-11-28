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
    /// Chronicles' task type ("Regular task", "Small victory" or one of their own), nil when unset.
    public var taskType: String? = nil
    /// What's in the way ("Blocked by"). Optional so a snapshot saved before blockers were read still opens.
    public var blockerList: [TaskBlocker]? = nil

    public var isOpen: Bool { status != .done }
    public var priorityRank: Int { ["urgent": 0, "high": 1, "medium": 2, "low": 3][priority] ?? 4 }
    public var blockers: [TaskBlocker] { blockerList ?? [] }

    /// The blockers still in the way: notes, and tasks that are still open. A task
    /// that is done, or isn't there any more, no longer blocks (Chronicles' rule).
    public func openBlockers(in tasks: [PlanTask]) -> [TaskBlocker] {
        blockers.filter { b in
            guard let other = b.taskID else { return true }
            return tasks.first { $0.id == other }?.isOpen ?? false
        }
    }

    /// "Get passport", "waiting on Dana's reply": each open blocker in words.
    public func blockerWords(in tasks: [PlanTask]) -> [String] {
        openBlockers(in: tasks).map { b in
            b.note ?? tasks.first { $0.id == b.taskID }?.title ?? "another task"
        }
    }
}

/// One "Blocked by" line on a task: another task (cleared once it's done) or a short note.
public struct TaskBlocker: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: String?
    public var note: String?
    public init(id: String = UUID().uuidString.lowercased(), taskID: String? = nil, note: String? = nil) {
        self.id = id; self.taskID = taskID; self.note = note
    }

    /// The same blocker in a fresh read: by id, else by what it is. A blocker Chronicles
    /// saved without an id gets a new one on every read, so the id alone can miss it.
    public func same(_ other: TaskBlocker) -> Bool {
        if id == other.id { return true }
        if let t = taskID { return other.taskID == t }
        if let n = note?.lowercased() { return other.note?.lowercased() == n }
        return false
    }

    public static let maxPerTask = 10
    public static let maxNote = 200

    /// A note made tidy, the way Chronicles keeps it: one line, single spaces, at most 200 characters.
    public static func cleanNote(_ raw: String) -> String {
        let oneLine = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(oneLine.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maxNote))
    }

    /// The blockers in a task's fields (`blockers`): each valid one once, at most 10.
    public static func list(from v: JSONValue?) -> [TaskBlocker] {
        var out: [TaskBlocker] = []
        for item in v?.array ?? [] {
            guard out.count < maxPerTask else { break }
            let id = item["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
            if let n = item["taskId"]?.int {
                let t = String(n)
                if !out.contains(where: { $0.taskID == t }) { out.append(TaskBlocker(id: id, taskID: t)) }
            } else if let raw = item["note"]?.string {
                let note = cleanNote(raw)
                if !note.isEmpty, !out.contains(where: { $0.note?.lowercased() == note.lowercased() }) { out.append(TaskBlocker(id: id, note: note)) }
            }
        }
        return out
    }

    /// As Chronicles stores it: `{ id, taskId }` or `{ id, note }`.
    public var json: JSONValue {
        if let t = taskID, let n = Int(t) { return ["id": .string(id), "taskId": .number(Double(n))] }
        return ["id": .string(id), "note": .string(note ?? "")]
    }
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

/// An exercise routine (Chronicles' Exercise Routine topic): a row on each day's
/// checklist at each of its times. Ticking it logs an Exercise entry for that slot.
public struct Routine: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var exerciseType: String
    /// Minutes for a full session (typed, else the sum of the "N min" items)
    public var minutes: Int
    public var itemIDs: [String]
    /// 0 = Sunday; empty = every day
    public var days: [Int]
    public var times: [String]
    public var trainingCategory: String

    public func runs(on day: String) -> Bool { days.isEmpty || days.contains(Day.weekday(day) - 1) }

    /// Chronicles' routineLinkKey: "<routineId>|<date>|<HH:MM>".
    public func linkKey(day: String, time: String) -> String {
        let t = String(time.prefix(5))
        return "\(id)|\(day)|\(t.count == 4 ? "0" + t : t)"
    }

    static let typeLabels = ["walking": "Walking", "running": "Running", "cycling": "Cycling", "swimming": "Swimming",
                             "strength": "Strength Training", "yoga": "Yoga", "balance": "Balance", "breathing": "Breathing",
                             "cardio": "Cardio", "other": "Other"]

    /// Chronicles' sessionFields for a full session.
    public func sessionFields(day: String, time: String) -> [String: JSONValue] {
        var f: [String: JSONValue] = [
            "exerciseType": .string(exerciseType), "duration": .string(minutes > 0 ? String(minutes) : ""),
            "intensity": "medium", "distance": "", "distanceUnit": "miles", "calories": "",
            "performedDate": .string(day), "performedTime": .string(String(time.prefix(5))), "notes": "",
            "routineId": .number(Double(Int(id) ?? 0)), "routineItemsDone": .array(itemIDs.map { .string($0) }),
        ]
        if !trainingCategory.isEmpty { f["trainingCategory"] = .string(trainingCategory) }
        return f
    }

    /// Chronicles' sessionTitle: "Morning yoga · Yoga · 30 min".
    public var sessionTitle: String {
        [name, Self.typeLabels[exerciseType] ?? exerciseType, minutes > 0 ? "\(minutes) min" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A book, movie, TV show or album from their Media journal (no cover image, no link).
public struct MediaItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// book / movie / tv / music
    public var type: String
    public var creator: String
    public var album: String
    public var season: String
    public var year: String
    public var genre: String
    /// 0 = unrated, else 0.5 … 5
    public var rating: Double
    /// current / want / done / paused / dnf, "" = no shelf
    public var shelf: String
    /// 0–100
    public var progress: Int
    public var notes: String
    public var tags: [String]

    /// "Reading" / "Want to watch" / "Listened" — Chronicles' shelf names for the type.
    public var shelfLabel: String {
        let verb = type == "book" ? "read" : type == "music" ? "listen" : "watch"
        switch shelf {
        case "current": return verb == "read" ? "Reading" : verb == "listen" ? "Listening" : "Watching"
        case "want": return "Want to \(verb)"
        case "done": return verb == "read" ? "Read" : verb == "listen" ? "Listened" : "Watched"
        case "paused": return "Paused"
        case "dnf": return "Didn't finish"
        default: return "No shelf"
        }
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
    public struct Item: Codable, Equatable, Sendable {
        public var text: String
        public var done: Bool
        /// Chronicles' id for the item (kept so a rewrite doesn't lose it).
        public var id: String? = nil
        public init(text: String, done: Bool, id: String? = nil) { self.text = text; self.done = done; self.id = id }
        /// The same item in a fresh read of the list: by Chronicles' id, else (an item
        /// saved without one) by its words.
        public func same(_ other: Item) -> Bool {
            if let id, let o = other.id { return id == o }
            return text == other.text
        }
        /// Stable while the list changes around it (for the Today page's checkboxes).
        public var key: String { id ?? "text:" + text }
    }
    public var day: String
    public var items: [Item]
    /// The Priorities entry this list is (the newest one, which Chronicles' dashboard shows).
    public var entryID: String? = nil
}

/// The Wins list Chronicles' dashboard shows: its newest Wins entry (it carries over midnight).
public struct WinsList: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public init(id: String = UUID().uuidString.lowercased(), text: String) { self.id = id; self.text = text }
    }
    public var entryID: String
    public var day: String
    public var items: [Item]
}

/// A shopping list that's still active: empty, or with something still to get (Chronicles' rule).
public struct ShoppingList: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var category: String
        public var checked: Bool
        public init(id: String = UUID().uuidString.lowercased(), name: String, category: String = "other", checked: Bool = false) {
            self.id = id; self.name = name; self.category = category; self.checked = checked
        }
    }
    public var entryID: String
    public var title: String
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
    /// From the Allergy topic: what they're allergic to, as they wrote it ("Eggs", "Coffee").
    /// Optional so a snapshot saved before this was read still opens.
    public var allergyList: [String]?
    public var allergies: [String] { allergyList ?? [] }
    /// Today's wins, and every active shopping list, newest first (optional, so older saved snapshots still open).
    public var wins: WinsList?
    public var shoppingLists: [ShoppingList]?
    /// Exercise routines, and the sessions logged from them in the last week (link key → entry id).
    public var routines: [Routine]?
    /// Their Media journal: books, movies, TV and music, with their notes.
    public var media: [MediaItem]?
    public var routineSessions: [String: String]?
    /// The task types they've added in Chronicles (the built-in two aren't listed). Optional for older snapshots.
    public var customTaskTypes: [String]?
    /// Every task type to offer: Chronicles' built-in ones, then theirs.
    public var taskTypes: [String] {
        var out: [String] = []
        for t in ["Regular task", "Small victory"] + (customTaskTypes ?? []) {
            let clean = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !clean.isEmpty, !out.contains(where: { $0.lowercased() == clean.lowercased() }) { out.append(clean) }
        }
        return out
    }

    public init(exportedAt: Date) { self.exportedAt = exportedAt }
}
