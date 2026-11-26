import Foundation

/// What the action tools need from the app. Closures so the app can hand over
/// live state (and nil while Smith is locked).
public struct ChroniclesActionContext: Sendable {
    public var writer: @Sendable () async -> ChroniclesWriter?
    public var snapshot: @Sendable () async -> ChroniclesSnapshot?
    public var topicID: @Sendable ([String]) async -> Int?
    public var hiddenTopicIDs: @Sendable () async -> Set<Int>
    public var estimateNutrients: @Sendable (_ item: String, _ mealType: String?, _ ingredients: String?) async -> [String: Double]?
    /// The app shows an Undo chip (2 minutes) and refreshes its data.
    public var didWrite: @Sendable (WriteResult) async -> Void
    /// A medication's name and fields (for the nutrients a dose adds to Meals).
    public var medication: @Sendable (Int) async -> (name: String, fields: JSONValue)? = { _ in nil }
    /// Is a Meals row already linked to this dose?
    public var hasDoseLink: @Sendable (String) async -> Bool = { _ in false }
    public var now: @Sendable () -> Date
    public var timeZone: TimeZone

    public init(writer: @escaping @Sendable () async -> ChroniclesWriter?, snapshot: @escaping @Sendable () async -> ChroniclesSnapshot?,
                topicID: @escaping @Sendable ([String]) async -> Int?, hiddenTopicIDs: @escaping @Sendable () async -> Set<Int>,
                estimateNutrients: @escaping @Sendable (String, String?, String?) async -> [String: Double]?,
                didWrite: @escaping @Sendable (WriteResult) async -> Void, now: @escaping @Sendable () -> Date = { Date() },
                timeZone: TimeZone = .current) {
        self.writer = writer; self.snapshot = snapshot; self.topicID = topicID; self.hiddenTopicIDs = hiddenTopicIDs
        self.estimateNutrients = estimateNutrients; self.didWrite = didWrite; self.now = now; self.timeZone = timeZone
    }

    var today: String { Day.key(for: now(), in: timeZone) }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }
}

/// Every action tool takes `explicit`: true only when they directly told Smith
/// to do it ("Smith, log meal…", "mark my vitamin D taken") or just said yes
/// to Smith's question. Otherwise the tool answers "ask first" and does nothing.
let explicitProperty: JSONValue = [
    "type": "boolean",
    "description": "true only if they explicitly asked you to do this now, or just said yes when you asked. If you are inferring it from something they mentioned, use false.",
]

func askFirst(_ what: String) -> String {
    "Not done. They didn't explicitly ask, so ask first, in your own words, whether they'd like you to \(what). Only call this again with explicit=true after they say yes."
}

/// Loose name matching: the best item whose words include the asked-for words.
func bestMatch<T>(_ items: [T], name: (T) -> String, query: String) -> (match: T?, candidates: [String]) {
    let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
    guard !words.isEmpty else { return (nil, []) }
    let scored = items.map { item -> (T, Int) in
        let n = name(item).lowercased()
        if n == query.lowercased() { return (item, 1000) }
        return (item, words.filter { n.contains($0) }.count)
    }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    guard let top = scored.first else { return (nil, []) }
    let ties = scored.filter { $0.1 == top.1 }
    if ties.count > 1, top.1 < 1000 { return (nil, ties.prefix(5).map { name($0.0) }) }
    return (top.0, [])
}

public struct LogMealTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var name: String { "log_meal" }
    public var description: String { "Log something they ate or drank in Chronicles (Meals). Nutrients are estimated the way Chronicles does." }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "description": ["type": "string", "description": "What they had, e.g. \"oatmeal with blueberries\""],
            "meal_type": ["type": "string", "enum": ["breakfast", "lunch", "dinner", "snack", "supplement"]],
            "time": ["type": "string", "description": "HH:MM, if they said when. Default now."],
            "ingredients": ["type": "string"],
            "explicit": explicitProperty,
        ], "required": ["description", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let item = input["description"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !item.isEmpty else { return "No meal given." }
        guard input["explicit"]?.bool == true else { return askFirst("log \(item) in Chronicles") }
        guard let writer = await ctx.writer() else { return "Smith is locked; they need to unlock with their Chronicles password first." }
        guard let topic = await ctx.topicID(["Meals"]) else { return "There's no Meals topic in their Chronicles yet." }
        if await ctx.hiddenTopicIDs().contains(topic) { return "They keep Meals from AI, so you can't log it. They can add it in Chronicles." }
        let now = ctx.now()
        let mealType = input["meal_type"]?.string ?? ChroniclesShapes.mealForNow(now, calendar: ctx.calendar)
        let time = input["time"]?.string.flatMap { $0.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil ? $0 : nil }
            ?? ChroniclesShapes.hhmm(now, calendar: ctx.calendar)
        let ingredients = input["ingredients"]?.string
        let nutrients = await ctx.estimateNutrients(item, mealType, ingredients)
        let shape = ChroniclesShapes.meal(name: item, mealType: mealType, date: ctx.today, time: time, ingredients: ingredients,
                                          topicID: topic, nutrients: nutrients)
        let id = try await writer.createEntry(content: shape.content, metadata: shape.metadata, now: now)
        let kcal = nutrients?["calories"].map { ", about \(Int($0)) calories" } ?? ""
        let result = WriteResult(summary: "Logged \(item) for \(mealType)\(kcal).", undo: .deleteEntry(id: id))
        await ctx.didWrite(result)
        return result.summary + " (Undo is available for 2 minutes.)"
    }
}

public struct LogDoseTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var name: String { "log_dose" }
    public var description: String { "Mark a medication dose taken or skipped in Chronicles. Scheduled medications tick the next untaken dose today; as-needed ones log a new dose." }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "medication": ["type": "string", "description": "Its name, e.g. \"vitamin D\""],
            "status": ["type": "string", "enum": ["taken", "skipped"]],
            "time": ["type": "string", "description": "HH:MM of the scheduled dose, if they named one"],
            "explicit": explicitProperty,
        ], "required": ["medication", "status", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let query = input["medication"]?.string ?? ""
        let status = input["status"]?.string == "skipped" ? "skipped" : "taken"
        guard let snap = await ctx.snapshot() else { return "No Chronicles data yet." }
        let (med, candidates) = bestMatch(snap.medications.filter(\.isActive), name: \.name, query: query)
        guard let med else {
            return candidates.isEmpty ? "No active medication matches \"\(query)\"." : "Which one? \(candidates.joined(separator: ", "))."
        }
        guard input["explicit"]?.bool == true else { return askFirst("mark \(med.name) \(status)") }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        guard let medID = Int(med.id) else { return "That medication can't be updated." }
        let today = ctx.today
        if med.frequency == "as_needed" || med.scheduleTimes.isEmpty {
            guard status == "taken" else { return "As-needed medications are only logged when taken." }
            let undo = try await writer.logAsNeededDose(medicationID: medID, date: today, now: ctx.now())
            let meal = await addToMeals(writer, medID: medID, time: ChroniclesShapes.hhmm(ctx.now(), calendar: ctx.calendar))
            let r = WriteResult(summary: "Logged a dose of \(med.name).", undo: meal.map { .all([undo, $0]) } ?? undo)
            await ctx.didWrite(r)
            return r.summary
        }
        let times = med.scheduleTimes.map { String($0.prefix(5)) }
        let done = Set(snap.doseLogs.filter { $0.medicationID == med.id && $0.date == today && $0.status != "pending" }.map(\.scheduledTime))
        let time = input["time"]?.string.map { String($0.prefix(5)) }.flatMap { t in times.contains(t) ? t : nil }
            ?? times.first { !done.contains($0) }
        guard let time else { return "\(med.name) is already ticked for today." }
        let undo = try await writer.logDose(medicationID: medID, scheduledTime: time, date: today, status: status, takenAt: nil)
        let meal = status == "taken" ? await addToMeals(writer, medID: medID, time: time) : nil
        let r = WriteResult(summary: "Marked \(med.name) (\(time)) \(status).", undo: meal.map { .all([undo, $0]) } ?? undo)
        await ctx.didWrite(r)
        return r.summary
    }
}

extension LogDoseTool {
    /// Chronicles' dashboard adds a "medication" Meals row for a dose with vitamins
    /// or minerals in it; Smith does the same. Returns its undo, or nil when nothing was added.
    func addToMeals(_ writer: ChroniclesWriter, medID: Int, time: String) async -> UndoAction? {
        let today = ctx.today
        let link = MedNutrients.linkKey(medicationID: medID, date: today, time: time)
        guard !(await ctx.hasDoseLink(link)), let med = await ctx.medication(medID) else { return nil }
        let values = MedNutrients.forDose(medicationFields: med.fields, name: med.name)
        guard MedNutrients.hasAny(values), let topic = await ctx.topicID(["Meals"]) else { return nil }
        let row = MedNutrients.mealRow(name: med.name, dosage: med.fields["dosage"]?.string ?? "", values: values, date: today,
                                       time: ChroniclesShapes.hhmm(ctx.now(), calendar: ctx.calendar), topicID: topic, link: link, createdAt: nil)
        guard let id = try? await writer.createEntry(content: row.content, metadata: row.metadata, now: ctx.now()) else { return nil }
        return .deleteEntry(id: id)
    }
}

public struct CheckHabitTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var name: String { "check_habit" }
    public var description: String { "Check off a habit in Chronicles for today (or a given day)." }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "habit": ["type": "string"],
            "day": ["type": "string", "description": "YYYY-MM-DD; default today"],
            "explicit": explicitProperty,
        ], "required": ["habit", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let query = input["habit"]?.string ?? ""
        guard let snap = await ctx.snapshot() else { return "No Chronicles data yet." }
        let (habit, candidates) = bestMatch(snap.habits.filter(\.isActive), name: \.name, query: query)
        guard let habit else {
            return candidates.isEmpty ? "No active habit matches \"\(query)\"." : "Which one? \(candidates.joined(separator: ", "))."
        }
        guard input["explicit"]?.bool == true else { return askFirst("check off \(habit.name)") }
        guard let writer = await ctx.writer(), let id = Int(habit.id) else { return "Smith is locked; unlock first." }
        let day = input["day"]?.string.flatMap { Day.isValid($0) ? String($0.prefix(10)) : nil } ?? ctx.today
        let undo = try await writer.checkHabit(habitID: id, day: day)
        let r = WriteResult(summary: "Checked off \(habit.name)\(day == ctx.today ? "" : " for \(Day.short(day))").", undo: undo)
        await ctx.didWrite(r)
        return r.summary
    }
}

public struct SaveNoteTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var name: String { "save_note" }
    public var description: String { "Save something they said as a Chronicles entry: in Journal, or in a topic they name (e.g. Idea)." }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "text": ["type": "string", "description": "Exactly what to save, in their words"],
            "topic": ["type": "string", "description": "Topic name; default Journal"],
            "explicit": explicitProperty,
        ], "required": ["text", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let text = input["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return "Nothing to save." }
        let topicName = input["topic"]?.string ?? "Journal"
        guard input["explicit"]?.bool == true else { return askFirst("save that to \(topicName)") }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        guard let topic = await ctx.topicID([topicName]) else { return "There's no \(topicName) topic in Chronicles yet." }
        if ExportParser.kind(of: topicName) != nil { return "\(topicName) has its own fields; use the matching tool instead." }
        // A note in a topic kept from AI couldn't be hidden by Smith (only Chronicles can mark it)
        if await ctx.hiddenTopicIDs().contains(topic) {
            return "They keep \(topicName) from AI, so you can't save there. They can add it in Chronicles."
        }
        let id = try await writer.createEntry(content: ChroniclesShapes.html(text), metadata: ["_taxonomyId": .number(Double(topic))], now: ctx.now())
        let r = WriteResult(summary: "Saved to \(topicName).", undo: .deleteEntry(id: id))
        await ctx.didWrite(r)
        return r.summary
    }
}

public struct AddTaskTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var name: String { "add_task" }
    public var description: String { "Add a task to Chronicles." }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "title": ["type": "string"],
            "date": ["type": "string", "description": "YYYY-MM-DD to plan it for"],
            "time": ["type": "string", "description": "HH:MM"],
            "deadline": ["type": "string", "description": "YYYY-MM-DD"],
            "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low", "none"]],
            "goal": ["type": "string", "description": "A goal it belongs to, by name"],
            "explicit": explicitProperty,
        ], "required": ["title", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let title = input["title"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !title.isEmpty else { return "No task given." }
        guard input["explicit"]?.bool == true else { return askFirst("add \"\(title)\" as a task") }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        guard let topic = await ctx.topicID(["Task", "Tasks"]) else { return "There's no Task topic in Chronicles yet." }
        var goalID: Int?
        if let g = input["goal"]?.string, let snap = await ctx.snapshot() {
            goalID = bestMatch(snap.goals, name: \.title, query: g).match.flatMap { Int($0.id) }
        }
        let valid = { (s: String?) in s.flatMap { Day.isValid($0) && $0.count == 10 ? $0 : nil } }
        let shape = ChroniclesShapes.task(title: title, date: valid(input["date"]?.string), time: input["time"]?.string,
                                          deadline: valid(input["deadline"]?.string), priority: input["priority"]?.string,
                                          goalID: goalID, topicID: topic)
        let id = try await writer.createEntry(content: shape.content, metadata: shape.metadata, now: ctx.now())
        let r = WriteResult(summary: "Added the task \"\(title)\".", undo: .deleteEntry(id: id))
        await ctx.didWrite(r)
        return r.summary
    }
}

public struct SetTaskStatusTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var name: String { "set_task_status" }
    public var description: String { "Mark a Chronicles task done, in progress, or back to to-do." }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "task": ["type": "string", "description": "Words from the task's title"],
            "status": ["type": "string", "enum": ["done", "in_progress", "todo"]],
            "explicit": explicitProperty,
        ], "required": ["task", "status", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let query = input["task"]?.string ?? ""
        let status = input["status"]?.string ?? "done"
        guard let snap = await ctx.snapshot() else { return "No Chronicles data yet." }
        let pool = status == "done" ? snap.tasks.filter(\.isOpen) : snap.tasks
        let (task, candidates) = bestMatch(pool, name: \.title, query: query)
        guard let task, let id = Int(task.id) else {
            return candidates.isEmpty ? "No task matches \"\(query)\"." : "Which one? \(candidates.joined(separator: ", "))."
        }
        let label = status == "done" ? "done" : status == "in_progress" ? "in progress" : "to do"
        guard input["explicit"]?.bool == true else { return askFirst("mark \"\(task.title)\" \(label)") }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        let before = try await writer.updateEntry(id: id) { _, meta in ChroniclesShapes.setTaskStatus(&meta, to: status) }
        let r = WriteResult(summary: "Marked \"\(task.title)\" \(label).", undo: .restoreEntry(id: id, content: before.content, metadata: before.metadata))
        await ctx.didWrite(r)
        return r.summary
    }
}

public struct MarkBillPaidTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var name: String { "mark_bill_paid" }
    public var description: String { "Mark a bill paid in Chronicles for its next unpaid due date. You never see or say amounts." }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "bill": ["type": "string"],
            "explicit": explicitProperty,
        ], "required": ["bill", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let query = input["bill"]?.string ?? ""
        guard let snap = await ctx.snapshot() else { return "No Chronicles data yet." }
        let (bill, candidates) = bestMatch(snap.bills.filter { !$0.paused }, name: \.name, query: query)
        guard let bill else {
            return candidates.isEmpty ? "No bill matches \"\(query)\"." : "Which one? \(candidates.joined(separator: ", "))."
        }
        guard input["explicit"]?.bool == true else { return askFirst("mark \(bill.name) paid") }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        let done = try await writer.markBillPaid(billID: bill.id, today: ctx.today)
        let r = WriteResult(summary: done.summary, undo: done.undo)
        await ctx.didWrite(r)
        return r.summary
    }
}

public enum ChroniclesActionTools {
    public static func all(_ ctx: ChroniclesActionContext) -> [LocalTool] {
        [LogMealTool(ctx), LogDoseTool(ctx), CheckHabitTool(ctx), SaveNoteTool(ctx), AddTaskTool(ctx), SetTaskStatusTool(ctx), MarkBillPaidTool(ctx)]
    }

    /// Added to the persona when Smith is connected to Chronicles.
    public static let persona = """
        You can act in their Chronicles: log meals and doses, check off habits, save notes, add tasks, mark tasks done \
        and mark bills paid. When they directly tell you to do one of these ("Smith, log meal: oatmeal", "mark my vitamin \
        D taken"), do it and say plainly what you did; they can undo it for two minutes. When you are only inferring it \
        ("I had oatmeal"), ask first in a natural way ("Want me to log that?"), and act only after they say yes. You \
        can't delete or change anything else; if they ask, say you can't and that they can do it in Chronicles.
        """
}
