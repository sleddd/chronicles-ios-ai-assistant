import Foundation

// Changing their plan in Chronicles: a task's details, its blockers, deleting a
// task, today's priorities, calendar events, and the tags on their entries.
// Same rules as the other action tools: `explicit` or ask first, a fresh read
// before every save, and an Undo for two minutes.

/// A task by `task_id` (from find_tasks) or by words from its title.
/// Open tasks first; done ones only when no open task matches.
func pickTask(_ snap: ChroniclesSnapshot, _ input: JSONValue, idKey: String = "task_id", wordsKey: String = "task") -> (PlanTask?, String?) {
    if let id = input[idKey]?.int.map(String.init) ?? input[idKey]?.string, !id.isEmpty {
        if let t = snap.tasks.first(where: { $0.id == id }) { return (t, nil) }
        return (nil, "No task has that id.")
    }
    let query = input[wordsKey]?.string ?? ""
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, "Which task? Give words from its title.") }
    var (task, candidates) = bestMatch(snap.tasks.filter(\.isOpen), name: \.title, query: query)
    if task == nil, candidates.isEmpty { (task, candidates) = bestMatch(snap.tasks, name: \.title, query: query) }
    if let task { return (task, nil) }
    return (nil, candidates.isEmpty ? "No task matches \"\(query)\"." : "Which one? \(candidates.joined(separator: ", ")). (find_tasks gives each one's id.)")
}

func validDay(_ s: String?) -> String? { s.flatMap { $0.count == 10 && Day.isValid($0) ? $0 : nil } }

func validTime(_ s: String?) -> String? {
    guard let s, s.count == 5, s.dropFirst(2).first == ":", let h = Int(s.prefix(2)), let m = Int(s.suffix(2)),
          (0...23).contains(h), (0...59).contains(m) else { return nil }
    return s
}

/// "none", "clear" or "" means take it off.
func isClear(_ s: String?) -> Bool {
    guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    return s.isEmpty || s == "none" || s == "clear" || s == "no"
}

/// Undo for an edit: the fields as they were, and the text too when that changed.
func editUndo(id: Int, before: (content: String, metadata: JSONValue), touched: Set<String>, contentChanged: Bool) -> UndoAction {
    if contentChanged { return .restoreEntry(id: id, content: before.content, metadata: before.metadata) }
    let was = before.metadata["_customFields"]?.object ?? [:]
    return .restoreFields(id: id, fields: Dictionary(uniqueKeysWithValues: touched.map { ($0, was[$0]) }))
}

public struct EditTaskTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var changesData: Bool { true }
    public var name: String { "edit_task" }
    public var description: String {
        "Change a Chronicles task: move or reschedule it (date, time, part of the day), or change its title, deadline, priority, goal or type. Set only what they asked to change; \"none\" clears a field. For status use set_task_status."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "task": ["type": "string", "description": "Words from the task's title"],
            "task_id": ["type": "string", "description": "The task's id from find_tasks, when words aren't enough"],
            "title": ["type": "string"],
            "date": ["type": "string", "description": "YYYY-MM-DD to plan it for, or \"none\""],
            "time": ["type": "string", "description": "HH:MM (24-hour), or \"none\""],
            "part": ["type": "string", "enum": ["morning", "noon", "night", "all_day", "none"], "description": "Part of the day"],
            "deadline": ["type": "string", "description": "YYYY-MM-DD, or \"none\""],
            "deadline_time": ["type": "string", "description": "HH:MM, or \"none\""],
            "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low", "none"]],
            "goal": ["type": "string", "description": "A goal by name, or \"none\""],
            "type": ["type": "string", "description": "A task type by name (see find_tasks), or \"none\""],
            "explicit": explicitProperty,
        ], "required": ["explicit"], "additionalProperties": false]
    }

    public func run(_ input: JSONValue) async throws -> String {
        guard let snap = await ctx.snapshot() else { return "No Chronicles data yet." }
        let (picked, problem) = pickTask(snap, input)
        guard let task = picked, let id = Int(task.id) else { return problem ?? "No such task." }

        var set: [String: JSONValue] = [:]
        var said: [String] = []
        if let t = input["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            set["taskDescription"] = .string(String(t.prefix(200))); said.append("renamed to \"\(t.prefix(200))\"")
        }
        for (key, field, label) in [("date", "scheduledDate", "planned for"), ("deadline", "deadline", "deadline")] {
            guard let v = input[key]?.string else { continue }
            if isClear(v) { set[field] = ""; said.append("no \(key == "date" ? "planned date" : "deadline")") }
            else if let d = validDay(v) { set[field] = .string(d); said.append("\(label) \(Day.short(d))") }
            else { return "\(key) must be YYYY-MM-DD." }
        }
        for (key, field, label) in [("time", "scheduledTime", "at"), ("deadline_time", "deadlineTime", "due by")] {
            guard let v = input[key]?.string else { continue }
            if isClear(v) { set[field] = ""; said.append("no \(key == "time" ? "time" : "deadline time")") }
            else if let t = validTime(v) { set[field] = .string(t); said.append("\(label) \(t)") }
            else { return "\(key) must be HH:MM (24-hour)." }
        }
        // A time with no date: the deadline's day, or today (Chronicles' editor does the same)
        if let t = set["scheduledTime"]?.string, !t.isEmpty {
            let date = set["scheduledDate"]?.string ?? task.scheduledDate ?? ""
            if date.isEmpty { set["scheduledDate"] = .string(set["deadline"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? task.deadline ?? ctx.today) }
        }
        if let p = input["part"]?.string {
            switch p {
            case "all_day": set["scheduledPart"] = "morning"; set["scheduledPartEnd"] = "night"; said.append("all day")
            case "none": set["scheduledPart"] = ""; set["scheduledPartEnd"] = ""; said.append("no part of the day")
            case "morning", "noon", "night": set["scheduledPart"] = .string(p); set["scheduledPartEnd"] = ""; said.append("in the \(p == "noon" ? "afternoon" : p == "night" ? "evening" : p)")
            default: return "part must be morning, noon, night, all_day or none."
            }
        }
        if let p = input["priority"]?.string, ["urgent", "high", "medium", "low", "none"].contains(p) {
            set["priority"] = .string(p); said.append(p == "none" ? "no priority" : "\(p) priority")
        }
        if let g = input["goal"]?.string {
            if isClear(g) { set["parentGoalId"] = .null; set["parentMilestoneId"] = .null; said.append("no goal") }
            else {
                let (goal, candidates) = bestMatch(snap.goals, name: \.title, query: g)
                guard let goal, let gid = Int(goal.id) else {
                    return candidates.isEmpty ? "No goal matches \"\(g)\"." : "Which goal? \(candidates.joined(separator: ", "))."
                }
                set["parentGoalId"] = .number(Double(gid))
                if task.goalID != goal.id { set["parentMilestoneId"] = .null }
                said.append("goal \(goal.title)")
            }
        }
        if let ty = input["type"]?.string {
            if isClear(ty) { set["taskType"] = ""; said.append("no type") }
            else if let match = snap.taskTypes.first(where: { $0.lowercased() == ty.trimmingCharacters(in: .whitespaces).lowercased() }) {
                set["taskType"] = .string(match); said.append("type \(match)")
            } else {
                return "There's no task type called \"\(ty)\". Their types: \(snap.taskTypes.joined(separator: ", "))."
            }
        }
        guard !set.isEmpty else { return "Nothing to change on \"\(task.title)\"." }
        let what = said.joined(separator: ", ")
        guard input["explicit"]?.bool == true else { return askFirst("change \"\(task.title)\" (\(what))") }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        var touched = Set<String>()
        var newContent = ""
        let before = try await writer.updateEntry(id: id) { content, meta in
            touched = ChroniclesShapes.editTask(&content, &meta, set)
            newContent = content
        }
        let r = WriteResult(summary: "Changed \"\(task.title)\": \(what).",
                            undo: editUndo(id: id, before: before, touched: touched, contentChanged: newContent != before.content))
        await ctx.didWrite(r)
        return r.summary
    }
}

public struct DeleteTaskTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var changesData: Bool { true }
    public var name: String { "delete_task" }
    public var description: String {
        "Delete a Chronicles task. Chronicles keeps a copy they can put back for two weeks, and Undo works for two minutes. Tasks only: never anything else."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "task": ["type": "string", "description": "Words from the task's title"],
            "task_id": ["type": "string", "description": "The task's id from find_tasks"],
            "explicit": explicitProperty,
        ], "required": ["explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        guard let snap = await ctx.snapshot() else { return "No Chronicles data yet." }
        let (picked, problem) = pickTask(snap, input)
        guard let task = picked, let id = Int(task.id) else { return problem ?? "No such task." }
        guard input["explicit"]?.bool == true else { return askFirst("delete the task \"\(task.title)\"") }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        let kept: Int?
        do { kept = try await writer.deleteEntry(id: id) } catch ChroniclesError.refused {
            return "Chronicles didn't let Smith delete it (Chronicles may need updating first). They can delete it in Chronicles."
        }
        let r = WriteResult(summary: "Deleted the task \"\(task.title)\". Chronicles keeps a copy for two weeks.",
                            undo: kept.map { .restoreDeleted(changeID: $0) })
        await ctx.didWrite(r)
        return r.summary
    }
}

public struct TaskBlockersTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var changesData: Bool { true }
    public var name: String { "task_blockers" }
    public var description: String {
        "A task's \"Blocked by\" line in Chronicles. Add a blocker (another task that has to be done first, or a short note like \"waiting on Dana's reply\"), remove one, or clear them all. A task blocker clears itself once that task is done."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "task": ["type": "string", "description": "Words from the blocked task's title"],
            "task_id": ["type": "string", "description": "The blocked task's id from find_tasks"],
            "action": ["type": "string", "enum": ["add", "remove", "clear"]],
            "blocked_by_task": ["type": "string", "description": "add: words from the title of the task in the way"],
            "blocked_by_task_id": ["type": "string", "description": "add: that task's id from find_tasks"],
            "note": ["type": "string", "description": "add: a short note instead of a task (at most 200 characters)"],
            "which": ["type": "string", "description": "remove: words from the blocker (its note or its task's title)"],
            "explicit": explicitProperty,
        ], "required": ["action", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        guard let snap = await ctx.snapshot() else { return "No Chronicles data yet." }
        let (picked, problem) = pickTask(snap, input)
        guard let task = picked, let id = Int(task.id) else { return problem ?? "No such task." }
        let action = input["action"]?.string ?? ""
        let title = { (b: TaskBlocker) in b.note ?? snap.tasks.first { $0.id == b.taskID }?.title ?? "another task" }

        // Worked out from what Smith holds, then applied to a fresh read
        var adding: TaskBlocker?
        var removing: TaskBlocker?
        var what: String
        switch action {
        case "add":
            if input["blocked_by_task"] != nil || input["blocked_by_task_id"] != nil {
                let (other, p) = pickTask(snap, input, idKey: "blocked_by_task_id", wordsKey: "blocked_by_task")
                guard let other else { return p ?? "No such task." }
                guard other.id != task.id else { return "A task can't block itself." }
                adding = TaskBlocker(taskID: other.id); what = "mark \"\(task.title)\" blocked by \"\(other.title)\""
            } else if let n = input["note"]?.string.map(TaskBlocker.cleanNote), !n.isEmpty {
                adding = TaskBlocker(note: n); what = "mark \"\(task.title)\" blocked: \(n)"
            } else { return "Say what's in the way: another task, or a short note." }
            if task.blockers.count >= TaskBlocker.maxPerTask { return "\"\(task.title)\" already has \(TaskBlocker.maxPerTask) blockers, the most it can have." }
        case "remove":
            let q = input["which"]?.string ?? ""
            let (b, candidates) = bestMatch(task.blockers, name: title, query: q)
            guard let b else {
                if task.blockers.isEmpty { return "\"\(task.title)\" has no blockers." }
                return candidates.isEmpty ? "Its blockers: \(task.blockers.map(title).joined(separator: "; ")). Which one?" : "Which one? \(candidates.joined(separator: ", "))."
            }
            removing = b; what = "take \"\(title(b))\" off what's blocking \"\(task.title)\""
        case "clear":
            if task.blockers.isEmpty { return "\"\(task.title)\" has no blockers." }
            what = "clear everything blocking \"\(task.title)\""
        default: return "action must be add, remove or clear."
        }
        guard input["explicit"]?.bool == true else { return askFirst(what) }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        var removed = true
        let before = try await writer.updateEntry(id: id) { _, meta in
            var cf = meta["_customFields"]?.object ?? [:]
            var list = TaskBlocker.list(from: cf["blockers"])
            switch action {
            case "add":
                if let a = adding, list.count < TaskBlocker.maxPerTask,
                   !list.contains(where: { ($0.taskID != nil && $0.taskID == a.taskID) || ($0.note != nil && $0.note?.lowercased() == a.note?.lowercased()) }) {
                    list.append(a)
                }
            case "remove":
                let count = list.count
                if let b = removing { list.removeAll { $0.same(b) } }
                removed = list.count < count
            default: list = []
            }
            cf["blockers"] = .array(list.map(\.json))
            meta["_customFields"] = .object(cf)
        }
        // Gone from Chronicles since Smith last looked: say so rather than claim it
        if action == "remove", !removed { return "That blocker wasn't on \"\(task.title)\" any more; nothing was changed." }
        let summary: String
        switch action {
        case "add": summary = "\"\(task.title)\" is now blocked by \(adding.map(title).map { "\"\($0)\"" } ?? "that")."
        case "remove": summary = "Took that blocker off \"\(task.title)\"."
        default: summary = "Cleared the blockers on \"\(task.title)\"."
        }
        let r = WriteResult(summary: summary, undo: .restoreFields(id: id, fields: ["blockers": before.metadata["_customFields"]?["blockers"]]))
        await ctx.didWrite(r)
        return r.summary
    }
}

public struct EditPrioritiesTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var changesData: Bool { true }
    public var name: String { "edit_priorities" }
    public var description: String {
        "Their priorities list in Chronicles (the one on the dashboard): add an item, reword it, tick it off or untick it, move it to another place, or remove it."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["add", "rename", "done", "undone", "move", "remove"]],
            "item": ["type": "string", "description": "Words from the item, or its number in the list (1 = first). Not for add."],
            "text": ["type": "string", "description": "add / rename: the item's words"],
            "position": ["type": "integer", "minimum": 1, "description": "add / move: where it goes (1 = top). Default: the end for add."],
            "explicit": explicitProperty,
        ], "required": ["action", "explicit"], "additionalProperties": false]
    }

    /// The list after the change, and what it did in words (nil list = a problem, in the words).
    /// The item meant by `item` (its number, or words from it), or what's wrong, in words.
    static func resolve(_ item: String?, in list: [PriorityList.Item]) -> (Int?, String) {
        let q = item?.trimmingCharacters(in: .whitespaces) ?? ""
        if let n = Int(q) { return (1...max(1, list.count)).contains(n) && n <= list.count ? (n - 1, "") : (nil, "There's no number \(n) on the list.") }
        let (m, candidates) = bestMatch(Array(list.enumerated()), name: { $0.element.text }, query: q)
        if let m { return (m.offset, "") }
        if list.isEmpty { return (nil, "The priorities list is empty.") }
        return (nil, candidates.isEmpty ? "Nothing on the list matches \"\(q)\". The list: \(list.map(\.text).joined(separator: "; "))." : "Which one? \(candidates.joined(separator: ", ")).")
    }

    static func apply(_ action: String, to items: [PriorityList.Item], item: String?, text: String?, position: Int?) -> ([PriorityList.Item]?, String) {
        var list = items
        func index() -> (Int?, String) { resolve(item, in: list) }
        let words = text.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) } ?? ""
        switch action {
        case "add":
            guard !words.isEmpty else { return (nil, "What should the priority say?") }
            let at = min(max((position ?? list.count + 1) - 1, 0), list.count)
            list.insert(.init(text: words, done: false, id: UUID().uuidString.lowercased()), at: at)
            return (list, "added \"\(words)\" to the priorities")
        case "rename":
            guard !words.isEmpty else { return (nil, "What should it say instead?") }
            let (i, p) = index(); guard let i else { return (nil, p) }
            let old = list[i].text; list[i].text = words
            return (list, "reworded \"\(old)\" to \"\(words)\"")
        case "done", "undone":
            let (i, p) = index(); guard let i else { return (nil, p) }
            list[i].done = action == "done"
            return (list, action == "done" ? "ticked off \"\(list[i].text)\"" : "unticked \"\(list[i].text)\"")
        case "move":
            let (i, p) = index(); guard let i else { return (nil, p) }
            guard let position else { return (nil, "Where should it go? Give a position (1 = top).") }
            let it = list.remove(at: i)
            list.insert(it, at: min(max(position - 1, 0), list.count))
            return (list, "moved \"\(it.text)\" to number \(min(max(position, 1), list.count))")
        case "remove":
            let (i, p) = index(); guard let i else { return (nil, p) }
            let it = list.remove(at: i)
            return (list, "removed \"\(it.text)\" from the priorities")
        default: return (nil, "action must be add, rename, done, undone, move or remove.")
        }
    }

    public func run(_ input: JSONValue) async throws -> String {
        guard let snap = await ctx.snapshot() else { return "No Chronicles data yet." }
        let action = input["action"]?.string ?? ""
        let item = input["item"]?.string ?? input["item"]?.int.map(String.init)
        let text = input["text"]?.string, position = input["position"]?.int
        // Checked against what Smith holds first, so the question it asks is the right one
        let (preview, said) = Self.apply(action, to: snap.priorities?.items ?? [], item: item, text: text, position: position)
        guard preview != nil else { return said }
        guard input["explicit"]?.bool == true else {
            // "ticked off \"Call Mum\"" → "tick off \"Call Mum\"", for the question
            let verbs = [("added", "add"), ("reworded", "reword"), ("ticked off", "tick off"), ("unticked", "untick"), ("moved", "move"), ("removed", "remove")]
            let ask = verbs.first { said.hasPrefix($0.0) }.map { $0.1 + said.dropFirst($0.0.count) } ?? said
            return askFirst(ask)
        }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        // The item they confirmed, as Smith holds it: found again in the fresh read by its
        // id, so a list reordered in Chronicles since can't turn "number 2" into another item
        let target: PriorityList.Item? = action == "add" ? nil
            : Self.resolve(item, in: snap.priorities?.items ?? []).0.map { (snap.priorities?.items ?? [])[$0] }

        guard let entry = snap.priorities?.entryID.flatMap(Int.init) else {
            // No list yet: a new Priorities entry, as Chronicles' dashboard makes one
            guard action == "add", let list = preview else { return "There's no priorities list yet." }
            guard let topic = await ctx.topicID(["Priorities"]) else { return "There's no Priorities topic in Chronicles yet." }
            let shape = ChroniclesShapes.newPriorities(list, day: ctx.today, topicID: topic)
            let id = try await writer.createEntry(content: shape.content, metadata: shape.metadata, now: ctx.now())
            let r = WriteResult(summary: "Started a priorities list: \(said).", undo: .deleteEntry(id: id))
            await ctx.didWrite(r)
            return r.summary
        }
        var result = said
        var failed = false
        let before = try await writer.updateEntry(id: entry) { _, meta in
            var cf = meta["_customFields"]?.object ?? [:]
            let fresh = (cf["priorities"]?.array ?? []).compactMap { i -> PriorityList.Item? in
                guard let t = i["text"]?.string, !t.isEmpty else { return nil }
                return .init(text: t, done: i["done"]?.bool ?? false, id: i["id"]?.string)
            }
            var which = item
            if let target {
                guard let i = fresh.firstIndex(where: { $0.same(target) }) else {
                    failed = true; result = "\"\(target.text)\" isn't on the priorities list any more; nothing was changed."; return
                }
                which = String(i + 1)
            }
            let (list, words) = Self.apply(action, to: fresh, item: which, text: text, position: position)
            guard let list else { failed = true; result = words; return }
            result = words
            cf["priorities"] = ChroniclesShapes.priorities(list)
            meta["_customFields"] = .object(cf)
        }
        // The list changed in Chronicles since Smith last looked, and the item isn't there now: nothing was changed
        if failed { return result }
        let r = WriteResult(summary: result.prefix(1).uppercased() + result.dropFirst() + ".",
                            undo: .restoreFields(id: entry, fields: ["priorities": before.metadata["_customFields"]?["priorities"]]))
        await ctx.didWrite(r)
        return r.summary
    }
}

public struct EditEventTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var changesData: Bool { true }
    public var name: String { "edit_event" }
    public var description: String {
        "Move or change an event or meeting in their Chronicles calendar: its title, day, start and end time, all-day or not, or place. Set only what they asked to change."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "event": ["type": "string", "description": "Words from the event's title"],
            "on": ["type": "string", "description": "YYYY-MM-DD it's on now, to tell events with the same name apart"],
            "title": ["type": "string"],
            "date": ["type": "string", "description": "New day, YYYY-MM-DD"],
            "start_time": ["type": "string", "description": "HH:MM (24-hour)"],
            "end_time": ["type": "string", "description": "HH:MM (24-hour), or \"none\""],
            "all_day": ["type": "boolean"],
            "location": ["type": "string", "description": "Where, or \"none\""],
            "whole_series": ["type": "boolean", "description": "true only after they confirm a change to a repeating event should change every time it repeats"],
            "explicit": explicitProperty,
        ], "required": ["event", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        guard let snap = await ctx.snapshot() else { return "No Chronicles data yet." }
        let query = input["event"]?.string ?? ""
        var pool = snap.calendar
        if let on = validDay(input["on"]?.string) {
            pool = pool.filter { e in
                !Recurrence.occurrences(start: e.startDate, rule: e.repeatRule, from: on, to: on).isEmpty
                    || (e.repeatRule == nil && e.startDate <= on && (e.endDate ?? e.startDate) >= on)
            }
        }
        let (match, candidates) = bestMatch(pool, name: \.title, query: query)
        guard let ev = match, let id = Int(ev.id) else {
            if !candidates.isEmpty {
                let days = pool.filter { candidates.contains($0.title) }.prefix(5).map { "\($0.title) (\(Day.short($0.startDate)))" }
                return "Which one? \(days.joined(separator: ", ")). Give the day it's on."
            }
            return "No event matches \"\(query)\"."
        }

        var set: [String: JSONValue] = [:]
        var said: [String] = []
        if let t = input["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            set["title"] = .string(String(t.prefix(200))); said.append("renamed to \"\(t.prefix(200))\"")
        }
        if let v = input["date"]?.string {
            guard let d = validDay(v) else { return "date must be YYYY-MM-DD." }
            set["startDate"] = .string(d)
            // A multi-day event keeps its length
            if let end = ev.endDate, end > ev.startDate { set["endDate"] = .string(Day.addDays(d, Day.daysBetween(ev.startDate, end))) }
            else if ev.endDate != nil { set["endDate"] = .string(d) }
            said.append("moved to \(Day.short(d))")
        }
        if let v = input["start_time"]?.string {
            guard let t = validTime(v) else { return "start_time must be HH:MM (24-hour)." }
            set["startTime"] = .string(t); said.append("starts \(t)")
            if input["all_day"] == nil, ev.allDay { set["allDay"] = false }
        }
        if let v = input["end_time"]?.string {
            if isClear(v) { set["endTime"] = ""; said.append("no end time") }
            else if let t = validTime(v) { set["endTime"] = .string(t); said.append("ends \(t)") }
            else { return "end_time must be HH:MM (24-hour)." }
        }
        if let a = input["all_day"]?.bool { set["allDay"] = .bool(a); said.append(a ? "all day" : "not all day") }
        if let v = input["location"]?.string {
            if isClear(v) { set["location"] = ""; said.append("no place") } else { set["location"] = .string(String(v.prefix(200))); said.append("at \(v.prefix(200))") }
        }
        guard !set.isEmpty else { return "Nothing to change on \"\(ev.title)\"." }
        if ev.repeatRule != nil, input["whole_series"]?.bool != true {
            return "Not done. \"\(ev.title)\" repeats, and this would change every time it repeats. Ask whether they mean the whole series; only call again with whole_series=true after they say yes. Changing just one day is done in Chronicles."
        }
        let what = said.joined(separator: ", ")
        guard input["explicit"]?.bool == true else { return askFirst("change \"\(ev.title)\" (\(what))") }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        var touched = Set<String>()
        var newContent = ""
        let before = try await writer.updateEntry(id: id) { content, meta in
            touched = ChroniclesShapes.editEvent(&content, &meta, isMeeting: ev.isMeeting, set)
            newContent = content
        }
        let r = WriteResult(summary: "Changed \"\(ev.title)\": \(what).",
                            undo: editUndo(id: id, before: before, touched: touched, contentChanged: newContent != before.content))
        await ctx.didWrite(r)
        return r.summary
    }
}

/// Tags on their journal and topic entries. Read-only; works while locked.
public struct FindTagsTool: LocalTool {
    let entries: @Sendable () async -> [TaggedEntry]
    public init(entries: @escaping @Sendable () async -> [TaggedEntry]) { self.entries = entries }
    public var name: String { "find_tags" }
    public var description: String {
        "The tags on their journal and topic entries in Chronicles. With no tag: every tag in use and how often. With a tag: the entries that have it (day, topic, id and other tags; never the entry's text). Tasks don't have tags."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "tag": ["type": "string", "description": "A tag to list entries for. Optional."],
            "from": ["type": "string", "description": "First day, YYYY-MM-DD. Optional."],
            "to": ["type": "string", "description": "Last day, YYYY-MM-DD. Optional."],
            "untagged": ["type": "boolean", "description": "List entries with no tags instead. Optional."],
        ], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        var list = await entries()
        guard !list.isEmpty else { return "No journal or topic entries Smith may look at (their journal sharing may be off)." }
        if let f = validDay(input["from"]?.string) { list = list.filter { $0.day >= f } }
        if let t = validDay(input["to"]?.string) { list = list.filter { $0.day <= t } }
        func line(_ e: TaggedEntry) -> String {
            "- \(Day.short(e.day)) (\(e.day)), \(e.topic), id \(e.id)" + (e.tags.isEmpty ? ", no tags" : ", tags: \(e.tags.joined(separator: ", "))")
        }
        if input["untagged"]?.bool == true {
            let none = list.filter(\.tags.isEmpty)
            return none.isEmpty ? "Every entry in that range has a tag." : none.prefix(25).map(line).joined(separator: "\n")
        }
        if let tag = input["tag"]?.string, !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            let hits = list.filter { $0.tags.contains { EntryTags.same($0, tag) } }
            return hits.isEmpty ? "No entries are tagged \"\(tag)\"." : "\(hits.count) tagged \"\(tag)\" (newest first):\n" + hits.prefix(25).map(line).joined(separator: "\n")
        }
        let used = TaggedEntry.inUse(list)
        let recent = list.prefix(10).map(line).joined(separator: "\n")
        return (used.isEmpty ? "No tags in use yet." : "Tags in use: " + used.map { "\($0.tag) (\($0.count))" }.joined(separator: ", "))
            + "\n\nMost recent entries:\n" + recent
    }
}

public struct TagEntryTool: LocalTool {
    let ctx: ChroniclesActionContext
    public init(_ ctx: ChroniclesActionContext) { self.ctx = ctx }
    public var changesData: Bool { true }
    public var name: String { "tag_entry" }
    public var description: String {
        "Add or remove tags on one of their journal or topic entries in Chronicles. Find the entry's id with find_tags first."
    }
    public var inputSchema: JSONValue {
        ["type": "object", "properties": [
            "entry_id": ["type": "string", "description": "The entry's id from find_tags"],
            "add": ["type": "array", "items": ["type": "string"], "description": "Tags to add (at most 40 characters each)"],
            "remove": ["type": "array", "items": ["type": "string"], "description": "Tags to take off"],
            "explicit": explicitProperty,
        ], "required": ["entry_id", "explicit"], "additionalProperties": false]
    }
    public func run(_ input: JSONValue) async throws -> String {
        let key = input["entry_id"]?.string ?? input["entry_id"]?.int.map(String.init) ?? ""
        // Only an entry Smith may see (sharing on, not a "never mention" topic)
        guard let entry = await ctx.taggedEntries().first(where: { $0.id == key }), let id = Int(key) else {
            return "No entry with that id that Smith may change. Use find_tags to find it."
        }
        let add = (input["add"]?.array ?? []).compactMap(\.string).map(EntryTags.clean).filter { !$0.isEmpty }
        let remove = (input["remove"]?.array ?? []).compactMap(\.string)
        guard !add.isEmpty || !remove.isEmpty else { return "Which tags to add or remove?" }
        var said: [String] = []
        if !add.isEmpty { said.append("add \(add.map { "\"\($0)\"" }.joined(separator: ", "))") }
        if !remove.isEmpty { said.append("remove \(remove.map { "\"\($0)\"" }.joined(separator: ", "))") }
        let label = "\(entry.topic) entry from \(Day.short(entry.day))"
        guard input["explicit"]?.bool == true else { return askFirst("\(said.joined(separator: " and ")) on the \(label)") }
        guard let writer = await ctx.writer() else { return "Smith is locked; unlock first." }
        var after: [String] = []
        let before = try await writer.updateEntry(id: id) { _, meta in
            // Kept from AI since Smith last looked: leave it alone
            guard meta["_aiHidden"]?.bool != true else { throw ChroniclesError.notFound("hidden") }
            var cf = meta["_customFields"]?.object ?? [:]
            var tags = EntryTags.of(meta["_customFields"])
            for t in remove { tags = EntryTags.removing(t, from: tags) }
            for t in add { tags = EntryTags.adding(t, to: tags) }
            after = tags
            cf["tags"] = .array(tags.map { .string($0) })
            meta["_customFields"] = .object(cf)
        }
        let r = WriteResult(summary: "The \(label) is now tagged: \(after.isEmpty ? "no tags" : after.joined(separator: ", ")).",
                            undo: .restoreFields(id: id, fields: ["tags": before.metadata["_customFields"]?["tags"]]))
        await ctx.didWrite(r)
        return r.summary
    }
}
