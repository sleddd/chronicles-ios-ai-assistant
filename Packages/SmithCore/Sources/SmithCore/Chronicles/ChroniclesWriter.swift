import Foundation

// Writes to Chronicles, the same shapes Chronicles itself saves
// (client/src/utils/chatSaveFields.ts, services/api.ts doses, utils/habits.ts,
// utils/finance.ts markBillPaid). Every update re-reads the record first:
// Chronicles keeps whichever save comes last.

/// How to put something back, within the server's undo window for new entries.
public enum UndoAction: Sendable, Equatable {
    case deleteEntry(id: Int)
    case restoreEntry(id: Int, content: String, metadata: JSONValue)
    case restoreDose(uuid: String, date: String, previous: JSONValue?)
    case restoreHabitLog(previous: JSONValue)
    case removeBillPayment(billID: String, paymentID: String)
    /// Several at once (a dose and the Meals row it added), undone last first.
    indirect case all([UndoAction])
}

public struct WriteResult: Sendable, Equatable {
    /// What happened, for Smith to say ("Logged oatmeal for breakfast.")
    public var summary: String
    public var undo: UndoAction?
    public init(summary: String, undo: UndoAction?) { self.summary = summary; self.undo = undo }
}

public struct ChroniclesWriter: Sendable {
    public let client: ChroniclesClient
    public let session: ChroniclesSession
    public init(client: ChroniclesClient, session: ChroniclesSession) { self.client = client; self.session = session }

    // MARK: entries

    public func createEntry(content: String, metadata: JSONValue, now: Date = Date()) async throws -> Int {
        let ids = try await client.call("POST", "/api/entries/ids", ["count": 1], session).body["ids"]?.array ?? []
        guard let id = ids.first?.int else { throw ChroniclesError.server(500, "No entry id") }
        var meta = metadata.object ?? [:]
        if meta["_createdAt"] == nil {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            meta["_createdAt"] = .string(iso.string(from: now))
        }
        let enc = try ChroniclesCrypto.encryptPost(content: content, metadata: .object(meta), id: id, key: session.key)
        try await client.call("POST", "/api/entries", [
            "id": .number(Double(id)), "format": 3, "isEncrypted": true,
            "contentEncrypted": .string(enc.contentEncrypted), "contentIv": .string(enc.contentIv),
            "metadataEncrypted": .string(enc.metadataEncrypted), "metadataIv": .string(enc.metadataIv),
        ], session)
        return id
    }

    /// Fresh read, change, save. Returns the entry as it was (for undo).
    public func updateEntry(id: Int, change: (inout String, inout [String: JSONValue]) throws -> Void) async throws -> (content: String, metadata: JSONValue) {
        let row = try await client.call("GET", "/api/entries/\(id)", nil, session).body
        guard let current = client.decryptEntry(row, session) else { throw ChroniclesError.notFound("That entry couldn’t be opened.") }
        var content = current.content
        var meta = current.metadata.object ?? [:]
        try change(&content, &meta)
        let enc = try ChroniclesCrypto.encryptPost(content: content, metadata: .object(meta), id: id, key: session.key)
        try await client.call("PUT", "/api/entries/\(id)", [
            "format": 3,
            "contentEncrypted": .string(enc.contentEncrypted), "contentIv": .string(enc.contentIv),
            "metadataEncrypted": .string(enc.metadataEncrypted), "metadataIv": .string(enc.metadataIv),
        ], session)
        return (current.content, current.metadata)
    }

    // MARK: doses

    /// The dose record for this medication, time and day, if there is one.
    func existingDose(medicationID: Int, scheduledTime: String, date: String) async throws -> (uuid: String, record: JSONValue)? {
        let r = try await client.call("GET", "/api/doses?date=\(date)", nil, session)
        for row in r.body["records"]?.array ?? [] {
            guard let id = row["id"]?.string, let p = row["payload"]?.string, let iv = row["iv"]?.string,
                  let rid = try? ChroniclesCrypto.doseRecordID(uuid: id, date: date),
                  let rec = try? ChroniclesCrypto.openRecord(kind: ChroniclesCrypto.RecordKind.dose, id: rid, payload: p, iv: iv, keys: session.keys)
            else { continue }
            if rec["medicationPostId"]?.int == medicationID, rec["scheduledTime"]?.string == scheduledTime, rec["asNeeded"]?.bool != true {
                return (id, rec)
            }
        }
        return nil
    }

    func putDose(uuid: String, date: String, record: JSONValue) async throws {
        let rid = try ChroniclesCrypto.doseRecordID(uuid: uuid, date: date)
        let sealed = try ChroniclesCrypto.sealRecord(kind: ChroniclesCrypto.RecordKind.dose, id: rid, record: record, key: session.key)
        try await client.call("PUT", "/api/doses/\(uuid)", ["format": 2, "date": .string(date), "payload": .string(sealed.payload), "iv": .string(sealed.iv)], session)
    }

    /// A scheduled dose taken or skipped (one record per medication, time and day — Chronicles' rule).
    public func logDose(medicationID: Int, scheduledTime: String, date: String, status: String, takenAt: String?) async throws -> UndoAction {
        let existing = try await existingDose(medicationID: medicationID, scheduledTime: scheduledTime, date: date)
        let uuid = existing?.uuid ?? UUID().uuidString.lowercased()
        let record: JSONValue = [
            "medicationPostId": .number(Double(medicationID)), "scheduledTime": .string(scheduledTime), "status": .string(status),
            "takenAt": status == "taken" ? .string(takenAt ?? Self.takenAtText(Date())) : .null,
        ]
        try await putDose(uuid: uuid, date: date, record: record)
        return .restoreDose(uuid: uuid, date: date, previous: existing?.record)
    }

    /// An as-needed dose: its own record every time, timed to the second.
    public func logAsNeededDose(medicationID: Int, date: String, now: Date = Date()) async throws -> UndoAction {
        let uuid = UUID().uuidString.lowercased()
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let record: JSONValue = [
            "medicationPostId": .number(Double(medicationID)), "scheduledTime": .string(f.string(from: now)),
            "status": "taken", "takenAt": .string(Self.takenAtText(now)), "asNeeded": true,
        ]
        try await putDose(uuid: uuid, date: date, record: record)
        // No delete for the AI app: undo marks it not taken
        return .restoreDose(uuid: uuid, date: date, previous: nil)
    }

    /// "1:35 PM", the way Chronicles shows a taken time.
    static func takenAtText(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    // MARK: habits

    /// Adds one check-in for a habit on a day (Chronicles' habitLog: one base-36 count per day).
    public func checkHabit(habitID: Int, day: String) async throws -> UndoAction {
        let rows = try await client.call("GET", "/api/settings", nil, session).body.array ?? []
        let sealed = rows.first { $0["key"]?.string == "habitLog" }?["value"]
        let previous = try sealed.map { try ChroniclesCrypto.openSetting(key: "habitLog", sealed: $0, keys: session.keys) } ?? .object([:])
        let next = Self.incrementHabit(previous, habitID: habitID, day: day, by: 1)
        try await putHabitLog(next)
        return .restoreHabitLog(previous: previous)
    }

    func putHabitLog(_ value: JSONValue) async throws {
        let sealed = try ChroniclesCrypto.sealSetting(key: "habitLog", value: value, mk: session.key)
        try await client.call("PUT", "/api/settings", ["key": "habitLog", "value": sealed], session)
    }

    static func incrementHabit(_ log: JSONValue, habitID: Int, day: String, by delta: Int) -> JSONValue {
        guard let (_, _, d) = Day.parse(day) else { return log }
        var all = log.object ?? [:]
        var months = all[String(habitID)]?.object ?? [:]
        let month = String(day.prefix(7))
        var digits = Array(months[month]?.string ?? "")
        while digits.count < d { digits.append("0") }
        let now = Int(String(digits[d - 1]), radix: 36) ?? 0
        let next = max(0, min(35, now + delta))
        digits[d - 1] = Character(String(next, radix: 36))
        var text = String(digits)
        while text.hasSuffix("0") { text.removeLast() }
        months[month] = .string(text)
        all[String(habitID)] = .object(months)
        return .object(all)
    }

    // MARK: bills

    /// Records a payment for the next unpaid due date (Chronicles' markBillPaid).
    /// The amount is read here, in memory, to record the payment, and goes nowhere else.
    public func markBillPaid(billID: String, today: String) async throws -> (summary: String, undo: UndoAction) {
        let r = try await client.call("GET", "/api/finance/bills?v=2", nil, session)
        guard let row = (r.body["records"]?.array ?? []).first(where: { $0["id"]?.string == billID }),
              let p = row["payload"]?.string, let iv = row["iv"]?.string,
              var bill = try ChroniclesCrypto.openRecord(kind: "bills", id: billID, payload: p, iv: iv, keys: session.keys).object
        else { throw ChroniclesError.notFound("That bill wasn’t found.") }
        let schedule = ExportParser.bills(from: ["bills": [.object(bill.merging(["id": .string(billID)]) { a, _ in a })]]).first
        guard let schedule, let due = schedule.nextUnpaidDue(today: today) else {
            throw ChroniclesError.refused("That bill is already marked paid.")
        }
        let amount = bill["amountCents"]?.double ?? 0
        let paidSoFar = (bill["payments"]?.array ?? []).filter { $0["forDue"]?.string == due }.compactMap { $0["amountCents"]?.double }.reduce(0, +)
        let paymentID = UUID().uuidString.lowercased()
        let iso = ISO8601DateFormatter()
        let payment: JSONValue = [
            "id": .string(paymentID), "forDue": .string(due), "paidOn": .string(today), "paidAt": .string(iso.string(from: Date())),
            "amountCents": .number(max(0, amount - paidSoFar)),
        ]
        bill["payments"] = .array((bill["payments"]?.array ?? []) + [payment])
        try await putBill(billID, .object(bill))
        let name = bill["name"]?.string ?? "The bill"
        return ("\(name) marked paid for \(Day.short(due)).", .removeBillPayment(billID: billID, paymentID: paymentID))
    }

    func putBill(_ id: String, _ record: JSONValue) async throws {
        let sealed = try ChroniclesCrypto.sealRecord(kind: "bills", id: id, record: record, key: session.key)
        try await client.call("PUT", "/api/finance/bills/\(id)", ["payload": .string(sealed.payload), "iv": .string(sealed.iv)], session)
    }

    // MARK: undo

    public func undo(_ action: UndoAction) async throws {
        switch action {
        case .all(let actions):
            for a in actions.reversed() { try await undo(a) }
        case .deleteEntry(let id):
            try await client.call("DELETE", "/api/entries/\(id)", nil, session)
        case .restoreEntry(let id, let content, let metadata):
            _ = try await updateEntry(id: id) { c, m in c = content; m = metadata.object ?? [:] }
        case .restoreDose(let uuid, let date, let previous):
            // Back to what it was, or to "not taken" (the AI app never deletes a dose)
            var rec = previous?.object ?? [:]
            if previous == nil {
                let current = try await client.call("GET", "/api/doses?date=\(date)", nil, session).body["records"]?.array ?? []
                if let row = current.first(where: { $0["id"]?.string == uuid }), let p = row["payload"]?.string, let iv = row["iv"]?.string {
                    rec = (try ChroniclesCrypto.openRecord(kind: ChroniclesCrypto.RecordKind.dose, id: try ChroniclesCrypto.doseRecordID(uuid: uuid, date: date),
                                                          payload: p, iv: iv, keys: session.keys)).object ?? [:]
                }
                rec["status"] = "pending"; rec["takenAt"] = .null
            }
            try await putDose(uuid: uuid, date: date, record: .object(rec))
        case .restoreHabitLog(let previous):
            try await putHabitLog(previous)
        case .removeBillPayment(let billID, let paymentID):
            let r = try await client.call("GET", "/api/finance/bills?v=2", nil, session)
            guard let row = (r.body["records"]?.array ?? []).first(where: { $0["id"]?.string == billID }),
                  let p = row["payload"]?.string, let iv = row["iv"]?.string,
                  var bill = try ChroniclesCrypto.openRecord(kind: "bills", id: billID, payload: p, iv: iv, keys: session.keys).object else { return }
            bill["payments"] = .array((bill["payments"]?.array ?? []).filter { $0["id"]?.string != paymentID })
            try await putBill(billID, .object(bill))
        }
    }
}

// MARK: - Shapes (as Chronicles saves them)

public enum ChroniclesShapes {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Plain text → Chronicles' entry HTML: one <p> per line.
    public static func html(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { "<p>\(escape(String($0)))</p>" }.joined()
    }

    /// Chronicles' mealForNow.
    public static func mealForNow(_ now: Date = Date(), calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: now)
        if h < 11 { return "breakfast" }
        if h < 15 { return "lunch" }
        if h >= 17 && h < 21 { return "dinner" }
        return "snack"
    }

    public static func hhmm(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// A Meals entry (chatSaveFields' meals shape), names capped at 200 characters.
    public static func meal(name: String, mealType: String?, date: String, time: String, ingredients: String?, topicID: Int,
                            nutrients: [String: Double]? = nil) -> (content: String, metadata: JSONValue) {
        let n = String(name.prefix(200))
        var cf: [String: JSONValue] = [
            "mealDescription": .string(n), "mealType": .string(mealType ?? "snack"), "consumedDate": .string(date),
            "consumedTime": .string(time), "ingredients": .string(ingredients ?? ""), "notes": "",
        ]
        if let nutrients, !nutrients.isEmpty {
            var sources: [String: JSONValue] = [:]
            for (k, v) in nutrients {
                cf[k] = .string(k == "calories" ? String(Int(v.rounded())) : String(v))
                sources[k] = "ai"
            }
            cf["nutrientSource"] = .object(sources)
            let basis = JSONValue.array([.string(n), .string(n), .string(mealType ?? "snack"), .string(ingredients ?? "")])
            let basisText = String(data: (try? basis.encoded(sortedKeys: false)) ?? Data(), encoding: .utf8) ?? ""
            cf["nutritionBasis"] = .string(basisText)
            if nutrients["calories"] != nil { cf["caloriesSource"] = "ai"; cf["calorieBasis"] = .string(basisText) }
        }
        return (html(n), ["_taxonomyId": .number(Double(topicID)), "_customFields": .object(cf)])
    }

    /// A task (chatSaveFields' task shape).
    public static func task(title: String, date: String?, time: String?, deadline: String?, priority: String?, goalID: Int?, topicID: Int) -> (content: String, metadata: JSONValue) {
        let t = String(title.prefix(200))
        var cf: [String: JSONValue] = [
            "taskDescription": .string(t), "isCompleted": false, "isInProgress": false, "priority": .string(priority ?? "none"),
            "deadline": .string(deadline ?? ""), "parentGoalId": goalID.map { .number(Double($0)) } ?? .null, "parentMilestoneId": .null,
            "notes": "",
        ]
        if let date { cf["scheduledDate"] = .string(date) }
        if let time { cf["scheduledTime"] = .string(time) }
        return (html(t), ["_taxonomyId": .number(Double(topicID)), "_customFields": .object(cf)])
    }

    /// Chronicles' taskFieldsForStatus: done / in progress / to do.
    public static func setTaskStatus(_ meta: inout [String: JSONValue], to status: String) {
        var cf = meta["_customFields"]?.object ?? [:]
        cf["isCompleted"] = .bool(status == "done")
        cf["isInProgress"] = .bool(status == "in_progress")
        cf["isInReview"] = false
        if status != "backlog" { cf["isBacklog"] = false }
        meta["_customFields"] = .object(cf)
    }

    /// The nutrition prompt Chronicles' own estimator uses (services/aiAssistant.ts).
    public static let nutritionSystem =
        "You are a nutrition assistant inside a personal health journal. " +
        "For a food, drink or supplement the user logged, estimate the nutrients in the amount described. " +
        "When details are missing, assume a typical single portion (or one dose for a supplement). " +
        "Use 0 for nutrients the item does not contain. " +
        "Reply with only a JSON object containing exactly the requested keys with numeric values, and nothing else."

    public static let nutrientLimits: [(key: String, unit: String, max: Double)] = [
        ("calories", "calories (kcal)", 20000), ("protein", "protein (g)", 1000), ("carbs", "carbs (g)", 2000), ("fat", "fat (g)", 1000),
        ("iron", "iron (mg)", 1000), ("vitaminD", "vitaminD (mcg)", 10000), ("vitaminB12", "vitaminB12 (mcg)", 100000), ("vitaminC", "vitaminC (mg)", 100000),
    ]

    public static func nutritionPrompt(item: String, mealType: String?, ingredients: String?) -> String {
        [
            "Item: \(item)",
            mealType.map { "Logged as: \($0)" } ?? "",
            (ingredients?.isEmpty == false) ? "Ingredients: \(ingredients!)" : "",
            "Estimate these and reply with JSON using exactly these keys: \(nutrientLimits.map(\.unit).joined(separator: ", ")).",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Chronicles' parseNutrients: every key present, finite and within its limit.
    public static func parseNutrients(_ text: String) -> [String: Double]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let v = try? JSONValue.parse(Data(text[start...end].utf8)) else { return nil }
        var out: [String: Double] = [:]
        for (key, _, max) in nutrientLimits {
            guard let n = v[key]?.double ?? v[key]?.string.flatMap(Double.init), n.isFinite, n >= 0, n <= max else { return nil }
            out[key] = key == "calories" ? n.rounded() : (abs(n) < 1 ? (n * 100).rounded() / 100 : (n * 10).rounded() / 10)
        }
        return out
    }
}
