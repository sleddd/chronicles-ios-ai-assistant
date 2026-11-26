import Foundation

/// Reads a Chronicles "Export All" file (Settings → Data → Export All).
///
/// What it keeps is in `ChroniclesSnapshot`. Journal entries come out only as
/// `TransientJournalEntry` values for the on-device summarizer and must not be
/// stored. Finance is read for bill schedules only; amounts are used once to
/// work out which due dates are paid, then dropped.
public enum ExportParser {
    public enum ParseError: LocalizedError, Equatable {
        case notJSON
        case notChroniclesExport
        case missingDate

        public var errorDescription: String? {
            switch self {
            case .notJSON: return "That file isn't a JSON file."
            case .notChroniclesExport: return "That doesn't look like a Chronicles Export All file."
            case .missingDate: return "The export has no export date."
            }
        }
    }

    public struct Result: Sendable {
        public var snapshot: ChroniclesSnapshot
        /// In memory only. Summarize, then let go.
        public var journal: [TransientJournalEntry]
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> Result {
        guard let root = try? JSONValue.parse(data) else { throw ParseError.notJSON }
        guard root["app"]?.string == "chronicles", root["kind"]?.string == "full-export" else {
            throw ParseError.notChroniclesExport
        }
        guard let exportedAt = root["exportedAt"]?.string.flatMap(parseISO) else { throw ParseError.missingDate }

        var snap = ChroniclesSnapshot(exportedAt: exportedAt)
        var settings = root["settings"] ?? [:]
        // What the account keeps from AI in Chronicles (Settings → In-App AI) is
        // left out of an export import exactly as it is from the live connection
        let kept = ChroniclesLiveSync.keptFromAI(settings.object ?? [:])
        if kept.features.contains("habits"), case .object(var o) = settings { o["habitLog"] = nil; settings = .object(o) }
        if kept.features.contains("vision"), case .object(var o) = settings { o["goalCategories"] = nil; settings = .object(o) }
        snap.displayName = settings["displayName"]?.string
        snap.timeZone = settings["timezone"]?.string

        // Topics: id → name; an entry's kind comes from its topic's name.
        for t in root["topics"]?.array ?? [] {
            if let id = idString(t["id"]), let name = t["name"]?.string { snap.topics[id] = name }
        }

        let habitLog = settings["habitLog"]?.object ?? [:]
        var journal: [TransientJournalEntry] = []
        var newestPriorities: (created: String, list: PriorityList)?

        for e in root["entries"]?.array ?? [] {
            guard let id = idString(e["id"]) else { continue }
            let meta = e["metadata"] ?? [:]
            // Hidden from AI (the entry's own switch or a topic on the list): never taken
            if meta["_aiHidden"]?.bool == true { continue }
            if let t = meta["_taxonomyId"]?.int ?? meta["_taxonomyId"]?.string.flatMap(Int.init), kept.topics.contains(t) { continue }
            let cf = meta["_customFields"] ?? [:]
            let topicID = idString(meta["_taxonomyId"])
            let topicName = topicID.flatMap { snap.topics[$0] }
            let created = e["createdAt"]?.string ?? meta["_createdAt"]?.string ?? ""
            let createdDay = created.count >= 10 ? String(created.prefix(10)) : nil
            let content = e["content"]?.string ?? ""
            let widget = meta["_widgetType"]?.string

            // Saved chats aren't used at all. Wellness check-ins: the last week's
            // numbers and choices (the wellness card), never their notes.
            if widget == "saved-chat" { continue }
            if widget == "wellness-checkin" {
                if let w = WellnessDay(entryID: id, fields: cf), w.date >= Day.addDays(Day.key(for: now), -7) { snap.wellness.append(w) }
                continue
            }

            switch kind(of: topicName) {
            case "task":
                let status: PlanTask.Status = cf["isCompleted"]?.bool == true ? .done
                    : (cf["isInProgress"]?.bool == true || cf["isInReview"]?.bool == true) ? .inProgress
                    : cf["isBacklog"]?.bool == true ? .backlog : .todo
                snap.tasks.append(PlanTask(
                    id: id, title: name(cf["taskDescription"], content), status: status,
                    scheduledDate: day(cf["scheduledDate"]), scheduledTime: nonEmpty(cf["scheduledTime"]),
                    scheduledPart: nonEmpty(cf["scheduledPart"]), deadline: day(cf["deadline"]),
                    deadlineTime: nonEmpty(cf["deadlineTime"]), priority: cf["priority"]?.string ?? "none",
                    goalID: idString(cf["parentGoalId"]), milestoneID: idString(cf["parentMilestoneId"]),
                    openChecklistItems: cf["taskFormat"]?.string == "list"
                        ? (cf["checklist"]?.array ?? []).filter { $0["done"]?.bool != true }.count : 0,
                    createdDay: createdDay))
            case "goal":
                var status = cf["goalStatus"]?.string ?? "new"
                if status == "active" || status == "archived" { status = "new" }
                snap.goals.append(Goal(id: id, title: name(cf["goalObjective"], content), status: status,
                                       longTerm: cf["goalType"]?.string == "long_term",
                                       category: nonEmpty(cf["goalCategory"]), startOn: day(cf["startOn"]),
                                       targetDate: day(cf["targetDate"])))
            case "milestone":
                let status = cf["isCompleted"]?.bool == true ? "completed" : (cf["milestoneStatus"]?.string ?? "not_started")
                snap.milestones.append(Milestone(id: id, title: name(cf["milestoneObjective"], content), status: status,
                                                 goalID: idString(cf["parentGoalId"]), startOn: day(cf["startOn"]),
                                                 targetDate: day(cf["targetDate"])))
            case "event", "meeting":
                let meeting = kind(of: topicName) == "meeting"
                guard let start = day(cf["startDate"]) ?? createdDay else { continue }
                snap.calendar.append(CalendarItem(
                    id: id, isMeeting: meeting,
                    title: name(meeting ? cf["meetingName"] : (cf["eventName"] ?? cf["calendarTitle"]), content),
                    startDate: start, startTime: nonEmpty(cf["startTime"]), endDate: day(cf["endDate"]),
                    endTime: nonEmpty(cf["endTime"]), allDay: cf["allDay"]?.bool ?? false,
                    location: nonEmpty(cf["location"]), attendees: meeting ? nonEmpty(cf["attendees"]) : nil,
                    repeatRule: RepeatRule(fields: cf)))
            case "habit":
                var log: [String: String] = [:]
                for (month, v) in habitLog[id]?.object ?? [:] { if let s = v.string { log[month] = s } }
                snap.habits.append(Habit(
                    id: id, name: name(cf["habitName"], content), targetCount: max(1, cf["targetCount"]?.int ?? 1),
                    targetPeriod: cf["targetPeriod"]?.string ?? "day",
                    days: (cf["days"]?.array ?? []).compactMap(\.int), isActive: cf["isActive"]?.bool != false,
                    goalID: idString(cf["parentGoalId"]), log: log))
            case "allergy":
                let a = name(cf["allergen"], content).trimmingCharacters(in: .whitespacesAndNewlines)
                if !a.isEmpty { snap.allergyList = (snap.allergyList ?? []) + [a] }
            case "medication":
                snap.medications.append(Medication(
                    id: id, name: name(cf["medicationName"], content), dosage: cf["dosage"]?.string ?? "",
                    frequency: cf["frequency"]?.string ?? "custom",
                    scheduleTimes: (cf["scheduleTimes"]?.array ?? []).compactMap(\.string),
                    isActive: cf["isActive"]?.bool != false))
            case "priorities":
                let items = (cf["priorities"]?.array ?? []).compactMap { i -> PriorityList.Item? in
                    guard let t = i["text"]?.string, !t.isEmpty else { return nil }
                    return .init(text: t, done: i["done"]?.bool ?? false)
                }
                if created > (newestPriorities?.created ?? "") {
                    newestPriorities = (created, PriorityList(day: createdDay ?? "", items: items))
                }
            case nil:
                // A text entry: the journal, or a plain topic of the person's own. Private.
                let text = plainText(fromHTML: content)
                if content == "[Decryption failed]" { continue }
                journal.append(TransientJournalEntry(id: id, day: createdDay ?? "", topicIDs: topicID.map { [$0] } ?? [], text: text))
            default:
                continue // meals, symptoms, recipes, wins… not used
            }
        }
        snap.priorities = newestPriorities?.list

        // Dose logs from the last 60 days.
        let cutoff = Day.addDays(Day.key(for: now), -60)
        for l in kept.features.contains("doses") ? [] : root["medicationDoseLogs"]?.array ?? [] {
            guard let date = day(l["date"]), date >= cutoff, let med = idString(l["medicationPostId"]) else { continue }
            snap.doseLogs.append(DoseLog(date: date, medicationID: med,
                                         scheduledTime: String((l["scheduledTime"]?.string ?? "").prefix(5)),
                                         status: l["status"]?.string ?? "pending", asNeeded: l["asNeeded"]?.bool ?? false))
        }
        snap.doseLogs.sort { ($0.date, $0.scheduledTime) < ($1.date, $1.scheduledTime) }

        // Vision and areas.
        let gc = settings["goalCategories"] ?? [:]
        let hidden = Set((gc["hidden"]?.array ?? []).compactMap { $0.string?.lowercased() })
        let builtIns = ["Health", "Career", "Finances", "Relationships", "Growth", "Home"]
        let added = (gc["added"]?.array ?? []).compactMap(\.string)
        let areas = gc["areas"]?.object ?? [:]
        snap.vision = Vision(
            overall: nonEmpty(gc["vision"]),
            areas: (builtIns + added).filter { !hidden.contains($0.lowercased()) }.map {
                VisionArea(name: $0, vision: nonEmpty(areas[$0.lowercased()]?["vision"]))
            })

        snap.bills = kept.features.contains("bills") ? [] : bills(from: root["finance"] ?? [:])
        return Result(snapshot: snap, journal: journal)
    }

    /// Bill schedules. Reads `amountCents` only to decide whether part payments
    /// add up to a paid due date; nothing about money is kept.
    static func bills(from finance: JSONValue) -> [BillSchedule] {
        (finance["bills"]?.array ?? []).compactMap { b in
            guard let id = idString(b["id"]), let name = b["name"]?.string, let due = day(b["dueDate"]),
                  let freq = BillSchedule.Frequency(rawValue: b["frequency"]?.string ?? "") else { return nil }
            let status = b["status"]?.string ?? "active"
            if status == "cancelled" { return nil }
            let amount = b["amountCents"]?.double ?? 0
            var byDue: [String: (full: Bool, sum: Double)] = [:]
            for p in b["payments"]?.array ?? [] {
                guard let forDue = day(p["forDue"]) else { continue }
                var entry = byDue[forDue] ?? (false, 0)
                if p["partial"]?.bool == true { entry.sum += p["amountCents"]?.double ?? 0 } else { entry.full = true }
                byDue[forDue] = entry
            }
            let paid = Set(byDue.filter { $0.value.full || $0.value.sum >= amount }.keys)
            return BillSchedule(id: id, name: name, isSubscription: b["kind"]?.string == "subscription", frequency: freq,
                                anchorDue: due, autopay: b["autopay"]?.bool ?? false, paused: status == "paused",
                                paidDues: paid)
        }
    }

    // MARK: helpers

    /// Chronicles' `topicKind`: the built-in kind a topic name holds, nil for a text topic.
    public static func kind(of topicName: String?) -> String? {
        guard let n = topicName?.trimmingCharacters(in: .whitespaces).lowercased(), !n.isEmpty else { return nil }
        let map: [String: String] = [
            "task": "task", "tasks": "task", "goal": "goal", "milestone": "milestone",
            "event": "event", "events": "event", "meeting": "meeting", "meetings": "meeting",
            "meals": "food", "medication": "medication", "symptom": "symptom", "exercise": "exercise",
            "allergy": "allergy", "shopping list": "shopping_list", "recipe": "recipe", "recipes": "recipe",
            "priorities": "priorities", "wins": "wins", "wellness": "wellness", "menu plan": "menu_plan",
            "change": "change", "changes": "change", "routine": "routine", "routines": "routine",
            "exercise schedule": "routine", "exercise routine": "routine", "training plan": "training_plan",
            "training plans": "training_plan", "media": "media", "media journal": "media", "media library": "media",
            "habit": "habit", "habits": "habit",
        ]
        if let k = map[n] { return k }
        // Smith's own topics (memories, letters, summaries): not journal, not plan data
        // (The old "Letters" name too: never summarized as journal, whoever wrote in it)
        if SmithTopics.which(n) != nil || SmithTopics.isLegacyLetters(n) { return "smith" }
        if n.contains("time track") || n.hasPrefix("timesheet") || n == "time log" || n == "time tracker" { return "time_tracking" }
        return nil
    }

    static func idString(_ v: JSONValue?) -> String? {
        switch v {
        case .number(let n)?: return Int64(exactly: n.rounded(.towardZero)).map { String($0) }
        case .string(let s)? where !s.isEmpty: return s
        default: return nil
        }
    }

    static func nonEmpty(_ v: JSONValue?) -> String? {
        guard let s = v?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func day(_ v: JSONValue?) -> String? {
        guard let s = nonEmpty(v), s.count >= 10, Day.isValid(String(s.prefix(10))) else { return nil }
        return String(s.prefix(10))
    }

    /// The entry's name field, else the first line of its text (Chronicles' display title, 70 characters).
    static func name(_ field: JSONValue?, _ html: String) -> String {
        if let n = nonEmpty(field) { return n }
        let first = plainText(fromHTML: html).split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? "Untitled" : String(first.prefix(70))
    }

    /// TipTap HTML → plain text with line breaks.
    public static func plainText(fromHTML html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"<(br|/p|/h[1-6]|/li|/blockquote|/pre)\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // "&amp;" last, so "&amp;lt;" stays "&lt;".
        let entities = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
