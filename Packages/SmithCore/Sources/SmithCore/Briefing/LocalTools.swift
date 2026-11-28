import Foundation

// Tools Smith can call. Each reads only Smith's filtered data: tasks, goals,
// bills (names and dates), the journal digest, weather and the time.

public struct TodayOverviewTool: LocalTool {
    let context: @Sendable () -> SmithContext
    public init(context: @escaping @Sendable () -> SmithContext) { self.context = context }
    public var name: String { "today_overview" }
    public var description: String { "Today's events, planned and overdue tasks, deadlines, medication doses, bills due and priorities." }
    public var inputSchema: JSONValue { ["type": "object", "properties": [:], "additionalProperties": false] }
    public func run(_ input: JSONValue) async throws -> String {
        context().overview?.contextText() ?? "No Chronicles data imported yet."
    }
}

public struct FindTasksTool: LocalTool {
    let snapshot: @Sendable () -> ChroniclesSnapshot?
    public init(snapshot: @escaping @Sendable () -> ChroniclesSnapshot?) { self.snapshot = snapshot }
    public var name: String { "find_tasks" }
    public var description: String {
        "Search tasks by words in the title and/or a date range (scheduled or deadline). Returns up to 25 tasks with their ids, types and what's blocking them, and the task types they use."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "query": ["type": "string", "description": "Words to look for in task titles. Optional."],
            "from": ["type": "string", "description": "First day, YYYY-MM-DD. Optional."],
            "to": ["type": "string", "description": "Last day, YYYY-MM-DD. Optional."],
            "include_done": ["type": "boolean", "description": "Include completed tasks. Default false."],
            "blocked_only": ["type": "boolean", "description": "Only tasks something is blocking. Default false."],
        ], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        guard let s = snapshot() else { return "No Chronicles data imported yet." }
        let q = input["query"]?.string?.lowercased().split(separator: " ").map(String.init) ?? []
        let from = input["from"]?.string, to = input["to"]?.string
        let done = input["include_done"]?.bool ?? false
        let blockedOnly = input["blocked_only"]?.bool ?? false
        let hits = s.tasks.filter { t in
            if !done && !t.isOpen { return false }
            if blockedOnly && t.openBlockers(in: s.tasks).isEmpty { return false }
            if !q.isEmpty && !q.allSatisfy({ t.title.lowercased().contains($0) }) { return false }
            if from != nil || to != nil {
                let days = [t.scheduledDate, t.deadline].compactMap { $0 }
                return days.contains { d in (from.map { d >= $0 } ?? true) && (to.map { d <= $0 } ?? true) }
            }
            return true
        }.sorted { ($0.scheduledDate ?? $0.deadline ?? "9999") < ($1.scheduledDate ?? $1.deadline ?? "9999") }
        let types = "Task types: " + s.taskTypes.joined(separator: ", ") + "."
        guard !hits.isEmpty else { return "No matching tasks.\n\(types)" }
        let goals = Dictionary(s.goals.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return hits.prefix(25).map { t in
            var bits = [t.status.rawValue]
            if let d = t.scheduledDate { bits.append("scheduled \(d)\(t.scheduledTime.map { " \($0)" } ?? "")") }
            if let d = t.deadline { bits.append("deadline \(d)") }
            if t.priority != "none" { bits.append("\(t.priority) priority") }
            if let g = t.goalID.flatMap({ goals[$0] }) { bits.append("goal: \(g)") }
            if let ty = t.taskType { bits.append("type: \(ty)") }
            let blocked = t.blockerWords(in: s.tasks)
            if !blocked.isEmpty { bits.append("blocked by: \(blocked.joined(separator: "; "))") }
            bits.append("id \(t.id)")
            return "- \(t.title) (\(bits.joined(separator: ", ")))"
        }.joined(separator: "\n") + "\n" + types
    }
}

public struct GoalsProgressTool: LocalTool {
    let snapshot: @Sendable () -> ChroniclesSnapshot?
    public init(snapshot: @escaping @Sendable () -> ChroniclesSnapshot?) { self.snapshot = snapshot }
    public var name: String { "goals_progress" }
    public var description: String { "Their goals and milestones with status and target dates, task counts per goal, and their vision and areas." }
    public var inputSchema: JSONValue { ["type": "object", "properties": [:], "additionalProperties": false] }
    public func run(_ input: JSONValue) async throws -> String {
        guard let s = snapshot() else { return "No Chronicles data imported yet." }
        var lines: [String] = []
        if let v = s.vision.overall { lines.append("Overall vision: \(v)") }
        let areas = s.vision.areas.compactMap { a in a.vision.map { "\(a.name): \($0)" } }
        if !areas.isEmpty { lines.append("Areas: " + areas.joined(separator: "; ")) }
        for g in s.goals where g.status != "completed" {
            let tasks = s.tasks.filter { $0.goalID == g.id }
            let doneCount = tasks.filter { !$0.isOpen }.count
            lines.append("Goal: \(g.title) — \(g.status.replacingOccurrences(of: "_", with: " "))\(g.targetDate.map { ", target \($0)" } ?? "")\(g.category.map { ", area \($0)" } ?? ""); tasks \(doneCount)/\(tasks.count) done")
            for m in s.milestones where m.goalID == g.id {
                lines.append("  Milestone: \(m.title) — \(m.status.replacingOccurrences(of: "_", with: " "))\(m.targetDate.map { ", target \($0)" } ?? "")")
            }
        }
        let doneGoals = s.goals.filter { $0.status == "completed" }.count
        if doneGoals > 0 { lines.append("Completed goals: \(doneGoals)") }
        return lines.isEmpty ? "No goals yet." : lines.joined(separator: "\n")
    }
}

public struct BillsDueTool: LocalTool {
    let context: @Sendable () -> SmithContext
    public init(context: @escaping @Sendable () -> SmithContext) { self.context = context }
    public var name: String { "bills_due" }
    public var description: String {
        "Bills and subscriptions due soon: names, due dates, paid or autopay. Never amounts (Smith doesn't keep them)."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": ["days": ["type": "integer", "description": "How many days ahead. Default 14."]],
         "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let c = context()
        guard let s = c.snapshot else { return "No Chronicles data imported yet." }
        let days = min(max(input["days"]?.int ?? 14, 1), 90)
        let list = BillsDue.upcoming(s.bills, today: c.today, days: days, privateIDs: c.privateBillIDs)
        return list.isEmpty ? "No bills due in the next \(days) days." : list.map { "- " + $0.line(today: c.today) }.joined(separator: "\n")
    }
}

public struct JournalSummaryTool: LocalTool {
    let digest: @Sendable () -> String?
    public init(digest: @escaping @Sendable () -> String?) { self.digest = digest }
    public var name: String { "journal_summary" }
    public var description: String { "A general summary of their journaling this week (counts, overall tone, broad themes). Never entry text." }
    public var inputSchema: JSONValue { ["type": "object", "properties": [:], "additionalProperties": false] }
    public func run(_ input: JSONValue) async throws -> String {
        digest() ?? "They've chosen not to share anything about their journal."
    }
}

public struct CurrentTimeTool: LocalTool {
    public init() {}
    public var name: String { "current_time" }
    public var description: String { "The current local date and time." }
    public var inputSchema: JSONValue { ["type": "object", "properties": [:], "additionalProperties": false] }
    public func run(_ input: JSONValue) async throws -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy, HH:mm zzz"; f.locale = Locale(identifier: "en_GB")
        return f.string(from: Date())
    }
}

public struct WeatherTool: LocalTool {
    let fetch: @Sendable () async throws -> String
    public init(fetch: @escaping @Sendable () async throws -> String) { self.fetch = fetch }
    public var name: String { "weather" }
    public var description: String { "Current weather and today's forecast where they are." }
    public var inputSchema: JSONValue { ["type": "object", "properties": [:], "additionalProperties": false] }
    public func run(_ input: JSONValue) async throws -> String { try await fetch() }
}

/// Smith's memory, in the conversation: what he notices on his own, what
/// they ask him to remember, and what they ask him to forget.
public struct MemoryTool: LocalTool {
    public var changesData: Bool { true }
    public enum Action: Sendable { case remember(String, Fact.Category), note(String, Fact.Category), forget(String) }
    let handle: @Sendable (Action) async -> String
    public init(handle: @escaping @Sendable (Action) async -> String) { self.handle = handle }
    public var name: String { "memory" }
    public var description: String {
        """
        Your memory of them. Use action "note" on your own, without asking, whenever they tell you something worth \
        remembering: how something went (an appointment, a meeting, a date), news, plans, people in their life and who \
        they are to them, likes and dislikes, how they want you to be. Use "remember" when they explicitly ask you to \
        remember something, and "forget" when they ask you to forget or correct something. Never anything from their \
        journal or about money amounts. Skip small talk that won't matter later.
        """
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["note", "remember", "forget"]],
            "fact": ["type": "string", "description": "One short third-person line, e.g. \"Doctor's appointment went well; follow-up in March\" or \"Doesn't drink coffee after 2pm\". For forget: words that identify it."],
            "category": ["type": "string", "enum": .array(Fact.Category.allCases.map { .string($0.rawValue) }),
                         "description": "updates = something that happened or is planned in their life"],
        ], "required": ["action", "fact"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let fact = input["fact"]?.string ?? ""
        guard !fact.isEmpty else { return "No fact given." }
        let cat = input["category"]?.string.flatMap(Fact.Category.init(rawValue:)) ?? .aboutYou
        switch input["action"]?.string {
        case "forget": return await handle(.forget(fact))
        case "note": return await handle(.note(fact, cat))
        default: return await handle(.remember(fact, cat))
        }
    }
}

/// Their Media journal: books, movies, TV shows and music, with their notes.
public struct FindMediaTool: LocalTool {
    let snapshot: @Sendable () -> ChroniclesSnapshot?
    public init(snapshot: @escaping @Sendable () -> ChroniclesSnapshot?) { self.snapshot = snapshot }
    public var name: String { "find_media" }
    public var description: String {
        "Their Media journal in Chronicles: books, movies, TV shows and music, with shelf (reading / want to / done / paused / didn't finish), rating, progress, genre, tags and their notes. Filter by words, type, shelf or rating. Returns up to 30."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "query": ["type": "string", "description": "Words in the title, creator, genre, tags or notes. Optional."],
            "type": ["type": "string", "enum": ["book", "movie", "tv", "music"]],
            "shelf": ["type": "string", "enum": ["current", "want", "done", "paused", "dnf"]],
            "min_rating": ["type": "number", "minimum": 0, "maximum": 5],
        ], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        guard let s = snapshot() else { return "No Chronicles data imported yet." }
        let all = s.media ?? []
        guard !all.isEmpty else { return "Nothing in their Media journal (or it's kept from AI in Chronicles)." }
        let words = input["query"]?.string?.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        let hits = all.filter { m in
            if let t = input["type"]?.string, m.type != t { return false }
            if let sh = input["shelf"]?.string, m.shelf != sh { return false }
            if let r = input["min_rating"]?.double, m.rating < r { return false }
            let hay = ([m.title, m.creator, m.album, m.genre, m.notes] + m.tags).joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        guard !hits.isEmpty else { return "Nothing in their Media journal matches." }
        let label = ["book": "Book", "movie": "Movie", "tv": "TV show", "music": "Music"]
        return "\(hits.count) found\(hits.count > 30 ? " (first 30)" : ""):\n" + hits.prefix(30).map { m in
            var bits = [label[m.type] ?? m.type]
            if !m.creator.isEmpty { bits.append("by \(m.creator)") }
            if !m.album.isEmpty { bits.append("on \(m.album)") }
            if !m.season.isEmpty { bits.append(m.season) }
            if !m.year.isEmpty { bits.append(m.year) }
            if !m.genre.isEmpty { bits.append(m.genre) }
            bits.append(m.shelfLabel)
            if m.shelf == "current", m.progress > 0 { bits.append("\(m.progress)% through") }
            if m.rating > 0 { bits.append("rated \(m.rating.formatted()) of 5") }
            if !m.tags.isEmpty { bits.append("tags: \(m.tags.joined(separator: ", "))") }
            var line = "- \(m.title) (\(bits.joined(separator: ", ")))"
            if !m.notes.isEmpty { line += "\n  Notes: " + String(m.notes.prefix(1500)) }
            return line
        }.joined(separator: "\n")
    }
}
