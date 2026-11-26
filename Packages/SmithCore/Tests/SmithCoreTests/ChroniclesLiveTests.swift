import Foundation
import CryptoKit
import Testing
@testable import SmithCore

/// A fake Chronicles server: real encryption (the vectors' master key), the
/// routes an assistant session uses, and a record of every call.
final class FakeChronicles: ChroniclesTransport, @unchecked Sendable {
    let lock = NSLock()
    let mk: SymmetricKey
    let wrap: JSONValue
    let secret: String
    var entries: [Int: JSONValue] = [:]
    var hidden: Set<Int> = []
    var nextID = 1000
    var settings: [String: JSONValue] = [:]
    var doses: [String: JSONValue] = [:]   // uuid → {id, date, payload, iv}
    var bills: [String: JSONValue] = [:]   // id → {id, payload, iv}
    var calls: [String] = []
    var created: [Int] = []
    var cursor = 1
    /// "rekey": every request answers 409 (moving to a new key); "limit": creating answers 429
    var mode: String?

    init() throws {
        let url = Bundle.module.url(forResource: "chronicles-vectors", withExtension: "json", subdirectory: "Fixtures")!
        let v = try JSONValue.parse(Data(contentsOf: url))
        mk = SymmetricKey(data: Data(base64Encoded: v["masterKey"]!.string!)!)
        wrap = v["wrap"]!.array![0]
        secret = v["authSecret"]!.array![0]["secret"]!.string!
    }

    static let email = "  Henry.Smith@Example.COM "
    static let password = "correct horse battery staple"

    func put(entry id: Int, content: String, metadata: JSONValue) throws {
        let e = try ChroniclesCrypto.encryptPost(content: content, metadata: metadata, id: id, key: mk)
        entries[id] = ["id": .number(Double(id)), "contentEncrypted": .string(e.contentEncrypted), "contentIv": .string(e.contentIv),
                       "metadataEncrypted": .string(e.metadataEncrypted), "metadataIv": .string(e.metadataIv),
                       "createdAt": "2026-11-20T10:00:00.000Z", "updatedAt": "2026-11-20T10:00:00.000Z", "changed": .number(Double(cursor))]
    }

    func decrypt(_ id: Int) -> (String, JSONValue)? {
        guard let r = entries[id] else { return nil }
        let p = EncryptedPost(contentEncrypted: r["contentEncrypted"]!.string!, contentIv: r["contentIv"]!.string!,
                              metadataEncrypted: r["metadataEncrypted"]!.string!, metadataIv: r["metadataIv"]!.string!)
        return try? ChroniclesCrypto.decryptPost(p, id: id, keys: [mk])
    }

    func openDose(_ uuid: String) -> JSONValue? {
        guard let d = doses[uuid], let date = d["date"]?.string else { return nil }
        return try? ChroniclesCrypto.openRecord(kind: "dose", id: ChroniclesCrypto.doseRecordID(uuid: uuid, date: date),
                                                payload: d["payload"]!.string!, iv: d["iv"]!.string!, keys: [mk])
    }

    func openBill(_ id: String) -> JSONValue? {
        guard let b = bills[id] else { return nil }
        return try? ChroniclesCrypto.openRecord(kind: "bills", id: id, payload: b["payload"]!.string!, iv: b["iv"]!.string!, keys: [mk])
    }

    func send(method: String, path: String, body: JSONValue?, token: String?) async throws -> HTTPResponse {
        try lock.withLock { try handle(method: method, path: path, body: body, token: token) }
    }

    func handle(method: String, path: String, body: JSONValue?, token: String?) throws -> HTTPResponse {
        calls.append("\(method) \(path)")
        let p = path.split(separator: "?").first.map(String.init) ?? path
        if p == "/api/auth/login" {
            guard body?["client"]?.string == "smith", body?["authSecret"]?.string == secret else { return HTTPResponse(status: 401, body: ["error": "Invalid credentials"]) }
            return HTTPResponse(status: 200, body: ["token": .string(String(repeating: "a", count: 44)), "encryption": [
                "encryptionEnabled": true, "kekSalt": wrap["salt"]!, "encryptedMasterKey": wrap["wrapped"]!,
                "kekWrapIv": wrap["iv"]!, "kekIterations": wrap["iterations"]!]])
        }
        guard token == String(repeating: "a", count: 44) else { return HTTPResponse(status: 401, body: ["error": "Invalid session"]) }
        if mode == "rekey" { return HTTPResponse(status: 409, body: ["error": "Chronicles is moving your journal to a new key. Try again once it has finished."]) }
        if mode == "limit", method == "POST", path.split(separator: "?").first == "/api/entries" {
            return HTTPResponse(status: 429, body: ["error": "The Chronicles AI app has added as many entries as it may in a day"])
        }
        let visible = entries.keys.filter { !hidden.contains($0) }.sorted()
        switch (method, p) {
        case ("GET", "/api/entries/cursor"): return HTTPResponse(status: 200, body: ["cursor": .string(String(cursor))])
        case ("GET", "/api/entries"):
            return HTTPResponse(status: 200, body: ["entries": .array(visible.map { entries[$0]! }), "more": false])
        case ("GET", "/api/entries/changes"):
            let since = Int(path.components(separatedBy: "since=").last ?? "0") ?? 0
            let changed = visible.filter { (entries[$0]!["changed"]?.int ?? 0) >= since }.map { entries[$0]! }
            return HTTPResponse(status: 200, body: ["reset": false, "cursor": .string(String(cursor)), "entries": .array(changed), "deleted": []])
        case ("GET", "/api/entries/visible-ids"): return HTTPResponse(status: 200, body: ["ids": .array(visible.map { .number(Double($0)) })])
        case ("POST", "/api/entries/ids"):
            nextID += 1
            return HTTPResponse(status: 200, body: ["ids": [.number(Double(nextID))]])
        case ("POST", "/api/entries"):
            let id = body!["id"]!.int!
            var row = body!.object!
            row["createdAt"] = "2026-11-25T14:00:00.000Z"; row["updatedAt"] = "2026-11-25T14:00:00.000Z"; row["changed"] = .number(Double(cursor))
            entries[id] = .object(row); created.append(id)
            return HTTPResponse(status: 201, body: .object(row))
        case ("GET", "/api/topics"):
            let names = [1: "Task", 2: "Journal", 3: "Meals", 4: "Medication", 5: "Habits", 6: "Therapy notes", 7: "Idea"]
            return HTTPResponse(status: 200, body: .array(try names.sorted { $0.key < $1.key }.map { id, name in
                let s = try ChroniclesCrypto.sealRecord(kind: "topic", id: String(id), record: ["name": .string(name), "icon": .null], key: mk)
                return ["id": .number(Double(id)), "payload": .string(s.payload), "iv": .string(s.iv), "color": .null]
            }))
        case ("GET", "/api/settings"):
            return HTTPResponse(status: 200, body: .array(settings.map { ["key": .string($0.key), "value": $0.value] }))
        case ("PUT", "/api/settings"):
            guard body?["key"]?.string == "habitLog" else { return HTTPResponse(status: 403, body: ["error": "Not available"]) }
            settings["habitLog"] = body!["value"]!
            return HTTPResponse(status: 200, body: [:])
        case ("GET", "/api/doses/all"):
            return HTTPResponse(status: 200, body: ["records": .array(Array(doses.values))])
        case ("GET", "/api/doses"):
            let date = path.components(separatedBy: "date=").last ?? ""
            return HTTPResponse(status: 200, body: ["records": .array(doses.values.filter { $0["date"]?.string == date })])
        case ("GET", "/api/finance/bills"):
            return HTTPResponse(status: 200, body: ["records": .array(Array(bills.values)), "more": false])
        default: break
        }
        if p.hasPrefix("/api/entries/"), let id = Int(p.dropFirst("/api/entries/".count)) {
            if hidden.contains(id) { return HTTPResponse(status: 404, body: ["error": "Entry not found"]) }
            switch method {
            case "GET": return entries[id].map { HTTPResponse(status: 200, body: $0) } ?? HTTPResponse(status: 404, body: [:])
            case "PUT":
                var row = body!.object!; row["id"] = .number(Double(id)); row["changed"] = .number(Double(cursor))
                entries[id] = .object(row)
                return HTTPResponse(status: 200, body: .object(row))
            case "DELETE":
                guard created.contains(id) else { return HTTPResponse(status: 403, body: ["error": "Can only undo what it just created"]) }
                entries[id] = nil
                return HTTPResponse(status: 200, body: ["success": true])
            default: break
            }
        }
        if method == "PUT", p.hasPrefix("/api/doses/") {
            let uuid = String(p.dropFirst("/api/doses/".count))
            doses[uuid] = ["id": .string(uuid), "date": body!["date"]!, "payload": body!["payload"]!, "iv": body!["iv"]!]
            return HTTPResponse(status: 200, body: ["record": [:]])
        }
        if method == "PUT", p.hasPrefix("/api/finance/bills/") {
            let id = String(p.dropFirst("/api/finance/bills/".count))
            guard bills[id] != nil else { return HTTPResponse(status: 404, body: ["error": "Bill not found"]) }
            bills[id] = ["id": .string(id), "payload": body!["payload"]!, "iv": body!["iv"]!]
            return HTTPResponse(status: 200, body: ["record": [:]])
        }
        return HTTPResponse(status: 403, body: ["error": "Not available to the Chronicles AI app"])
    }
}

/// A seeded account: a task, a journal entry, a hidden therapy note, a medication, a habit and a bill.
func seededServer() throws -> FakeChronicles {
    let s = try FakeChronicles()
    try s.put(entry: 10, content: "<p>Finish launch deck</p>", metadata: ["_taxonomyId": 1, "_customFields": [
        "taskDescription": "Finish launch deck", "isCompleted": false, "isInProgress": false, "scheduledDate": "2026-11-25", "priority": "high"]])
    try s.put(entry: 20, content: "<p>Today the landlord meeting went badly CANARY-LIVE-JOURNAL-7X</p>", metadata: ["_taxonomyId": 2])
    try s.put(entry: 30, content: "<p>CANARY-LIVE-THERAPY-2Q</p>", metadata: ["_taxonomyId": 6])
    s.hidden = [30]
    try s.put(entry: 40, content: "<p>Vitamin D</p>", metadata: ["_taxonomyId": 4, "_customFields": [
        "medicationName": "Vitamin D", "dosage": "1000 IU", "frequency": "once_daily", "scheduleTimes": ["08:00"], "isActive": true]])
    try s.put(entry: 50, content: "<p>Exercise</p>", metadata: ["_taxonomyId": 5, "_customFields": [
        "habitName": "Exercise", "targetCount": 1, "targetPeriod": "day", "days": [], "isActive": true]])
    s.settings["habitLog"] = try ChroniclesCrypto.sealSetting(key: "habitLog", value: ["50": ["2026-11": "01"]], mk: s.mk)
    // Sealed, as Chronicles stores it; a readable name would be the server's word alone
    s.settings["displayName"] = try ChroniclesCrypto.sealSetting(key: "displayName", value: "Henry", mk: s.mk)
    s.settings["timezone"] = "Mars/Olympus"   // readable: not believed
    s.settings["dashboardConfig"] = try ChroniclesCrypto.sealSetting(key: "dashboardConfig", value: [
        "hidden": [], "places": [["name": "Portland", "latitude": 45.52, "longitude": -122.68, "timezone": "America/Los_Angeles"]]], mk: s.mk)
    s.settings["aiConfig"] = try ChroniclesCrypto.sealSetting(key: "aiConfig", value: [
        "_rev": 3, "enabled": true, "provider": "anthropic", "model": "claude-opus-5-5", "apiKey": "sk-ant-TEST-KEY",
        "chatNotes": "CANARY-LIVE-CHATNOTES"], mk: s.mk)
    let billID = "0b5c8f4e-8a51-4c3f-9d55-3a1f7c2e9b10"
    let bill: JSONValue = ["name": "Rent", "kind": "bill", "amountCents": 123456, "frequency": "monthly", "dueDate": "2026-01-26",
                           "status": "active", "notes": "CANARY-LIVE-BILLNOTE", "payments": []]
    let sealed = try ChroniclesCrypto.sealRecord(kind: "bills", id: billID, record: bill, key: s.mk)
    s.bills[billID] = ["id": .string(billID), "payload": .string(sealed.payload), "iv": .string(sealed.iv)]
    return s
}

@Suite struct ChroniclesLiveTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-25T14:00:00Z")!
    let tz = TimeZone(identifier: "UTC")!

    func unlocked(_ server: FakeChronicles) async throws -> (ChroniclesClient, ChroniclesSession) {
        let client = ChroniclesClient(transport: server)
        guard case .unlocked(let s) = try await client.signIn(email: FakeChronicles.email, password: FakeChronicles.password) else {
            Issue.record("expected unlock"); throw ChroniclesError.locked
        }
        return (client, s)
    }

    @Test func signInUnlocksAndWrongPasswordFails() async throws {
        let server = try seededServer()
        let client = ChroniclesClient(transport: server)
        await #expect(throws: ChroniclesError.self) { _ = try await client.signIn(email: FakeChronicles.email, password: "wrong") }
        let (_, s) = try await unlocked(server)
        #expect(s.token.count == 44)
    }

    @Test func liveSyncBuildsTheSnapshotWithoutPrivateText() async throws {
        let server = try seededServer()
        let (client, session) = try await unlocked(server)
        let sync = ChroniclesLiveSync(client: client, session: session)
        let r = try await sync.refresh(now: now)
        #expect(r.snapshot.tasks.map(\.title) == ["Finish launch deck"])
        #expect(r.snapshot.medications.first?.name == "Vitamin D")
        #expect(r.snapshot.habits.first?.count(on: "2026-11-02") == 1)
        #expect(r.snapshot.bills.first?.name == "Rent")
        #expect(r.snapshot.displayName == "Henry")
        #expect(r.snapshot.timeZone == nil)
        // The account's own Anthropic key, for memory only; nothing else from that setting
        #expect(r.anthropicKey == "sk-ant-TEST-KEY")
        // Chronicles' home city, for the weather
        #expect(r.homePlace == HomePlace(name: "Portland", latitude: 45.52, longitude: -122.68, timezone: "America/Los_Angeles"))
        #expect(ChroniclesLiveSync.anthropicKey(["enabled": false, "provider": "anthropic", "apiKey": "k"]) == nil)
        #expect(ChroniclesLiveSync.anthropicKey(["enabled": true, "provider": "openai", "apiKey": "k"]) == nil)
        // Journal text only as transient entries for the on-device summary; the hidden one never arrives
        #expect(r.journal.map(\.id) == ["20"])
        let json = String(data: try JSONEncoder().encode(r.snapshot), encoding: .utf8)!
        for c in ["CANARY-LIVE-JOURNAL-7X", "CANARY-LIVE-THERAPY-2Q", "CANARY-LIVE-BILLNOTE", "123456", "sk-ant-TEST-KEY", "CANARY-LIVE-CHATNOTES"] { #expect(!json.contains(c)) }
        #expect(!server.calls.contains { $0.contains("expenses") || $0.contains("budget") || $0.contains("savings") })

        // Later: an entry hidden from AI drops out; a new one appears
        server.lock.withLock { server.cursor = 2; server.hidden.insert(20) }
        try server.lock.withLock { try server.put(entry: 11, content: "<p>Call the bank</p>", metadata: ["_taxonomyId": 1, "_customFields": ["taskDescription": "Call the bank", "isCompleted": false]]) }
        let r2 = try await sync.refresh(now: now)
        #expect(Set(r2.snapshot.tasks.map(\.title)) == ["Finish launch deck", "Call the bank"])
        #expect(r2.removedJournalIDs == ["20"])
        #expect(r2.journal.isEmpty)
    }

    /// Smith's own check, after decrypting: the server leaves hidden entries out,
    /// but one it sent by mistake still never reaches the snapshot or the summaries.
    @Test func entriesKeptFromAIAreDroppedEvenIfTheServerSendsThem() async throws {
        let server = try seededServer()
        // Sent by the server (not on its hidden list), yet marked hidden inside the encrypted entry…
        try server.put(entry: 12, content: "<p>CANARY-SWITCH-TASK</p>", metadata: ["_taxonomyId": 1, "_aiHidden": true, "_customFields": ["taskDescription": "CANARY-SWITCH-TASK", "isCompleted": false]])
        try server.put(entry: 21, content: "<p>CANARY-SWITCH-JOURNAL</p>", metadata: ["_taxonomyId": 2, "_aiHidden": true])
        // …or in a topic the account keeps from AI
        try server.put(entry: 31, content: "<p>CANARY-TOPIC-THERAPY</p>", metadata: ["_taxonomyId": 6])
        try server.put(entry: 32, content: "<p>CANARY-TOPIC-AS-TEXT</p>", metadata: ["_taxonomyId": "6"])
        server.settings["aiPrivacy"] = ["appEnabled": true, "hiddenTopicIds": [6], "hiddenFeatures": []]
        let (client, session) = try await unlocked(server)
        let sync = ChroniclesLiveSync(client: client, session: session)
        let r = try await sync.refresh(now: now)
        #expect(r.snapshot.tasks.map(\.title) == ["Finish launch deck"])
        #expect(r.journal.map(\.id) == ["20"])
        #expect(r.hiddenTopicIDs == [6])
        for id in [12, 21, 31, 32] { #expect(await sync.entry(id) == nil) }
        let json = String(data: try JSONEncoder().encode(r.snapshot), encoding: .utf8)!
        for c in ["CANARY-SWITCH-TASK", "CANARY-SWITCH-JOURNAL", "CANARY-TOPIC-THERAPY", "CANARY-TOPIC-AS-TEXT"] { #expect(!json.contains(c)) }

        // The same on the change feed
        server.lock.withLock { server.cursor = 2 }
        try server.lock.withLock { try server.put(entry: 13, content: "<p>CANARY-LATER</p>", metadata: ["_taxonomyId": 1, "_aiHidden": true, "_customFields": ["taskDescription": "CANARY-LATER", "isCompleted": false]]) }
        let r2 = try await sync.refresh(now: now)
        #expect(r2.snapshot.tasks.map(\.title) == ["Finish launch deck"])
        #expect(await sync.entry(13) == nil)
    }

    /// The sealed copy of the choices is what Smith believes. A server whose own
    /// readable copy lists nothing hidden still can't have Smith hold a hidden
    /// topic's entries, or ask for a feature kept from AI.
    @Test func theSealedChoicesHoldWhateverTheServersCopySays() async throws {
        let server = try seededServer()
        try server.put(entry: 31, content: "<p>CANARY-SEALED-TOPIC</p>", metadata: ["_taxonomyId": 6])
        server.settings["aiPrivacy"] = ["appEnabled": true, "hiddenTopicIds": [], "hiddenFeatures": []]
        server.settings["aiPrivacySealed"] = try ChroniclesCrypto.sealSetting(key: "aiPrivacySealed",
            value: ["_rev": 3, "appEnabled": true, "hiddenTopicIds": [6], "hiddenFeatures": ["doses", "habits"]], mk: server.mk)
        let (client, session) = try await unlocked(server)
        let sync = ChroniclesLiveSync(client: client, session: session)
        let r = try await sync.refresh(now: now)
        #expect(r.hiddenTopicIDs == [6])
        #expect(await sync.entry(31) == nil)
        let json = String(data: try JSONEncoder().encode(r.snapshot), encoding: .utf8)!
        #expect(!json.contains("CANARY-SEALED-TOPIC"))
        let kept = ChroniclesLiveSync.keptFromAI(try await client.settings(session))
        #expect(kept.features == ["doses", "habits"])

        // A readable value under the sealed key is the server's own: never taken
        server.lock.withLock { server.settings["aiPrivacySealed"] = ["appEnabled": true, "hiddenTopicIds": [9], "hiddenFeatures": ["bills"]] }
        let plain = ChroniclesLiveSync.keptFromAI(try await client.settings(session))
        #expect(plain.topics.isEmpty && plain.features.isEmpty)
    }

    /// A topic put on the "Don't share with AI" list: what Smith holds from it goes at the next refresh.
    @Test func aTopicHiddenLaterDropsWhatIsHeld() async throws {
        let server = try seededServer()
        let (client, session) = try await unlocked(server)
        let sync = ChroniclesLiveSync(client: client, session: session)
        #expect(try await sync.refresh(now: now).snapshot.tasks.count == 1)
        server.lock.withLock { server.cursor = 2; server.settings["aiPrivacy"] = ["appEnabled": true, "hiddenTopicIds": [1], "hiddenFeatures": []] }
        let r = try await sync.refresh(now: now)
        #expect(r.snapshot.tasks.isEmpty)
        #expect(await sync.entry(10) == nil)
    }

    /// An entry shared with AI again didn't change, so the change feed never
    /// sends it: Smith finds it by comparing the ids it may see with what it holds.
    @Test func entriesSharedWithAIAgainArePickedUp() async throws {
        let server = try seededServer()
        try server.put(entry: 14, content: "<p>Renew passport</p>", metadata: ["_taxonomyId": 1, "_customFields": ["taskDescription": "Renew passport", "isCompleted": false]])
        try server.put(entry: 22, content: "<p>A quiet day</p>", metadata: ["_taxonomyId": 2])
        server.hidden = [30, 14, 22]
        let (client, session) = try await unlocked(server)
        let sync = ChroniclesLiveSync(client: client, session: session)
        let r = try await sync.refresh(now: now)
        #expect(r.snapshot.tasks.map(\.title) == ["Finish launch deck"])
        #expect(r.journal.map(\.id) == ["20"])

        // Time passes: the sync's cursor moves on past everything written so far
        server.lock.withLock { server.cursor = 2 }
        _ = try await sync.refresh(now: now)
        // Shared again: nothing about the entries changed, only the server's list
        server.lock.withLock { server.cursor = 3; server.hidden = [30] }
        let r2 = try await sync.refresh(now: now)
        #expect(Set(r2.snapshot.tasks.map(\.title)) == ["Finish launch deck", "Renew passport"])
        #expect(r2.journal.map(\.id) == ["22"])
        #expect(!r2.isFullLoad)
        #expect(server.calls.contains("GET /api/entries/14") && server.calls.contains("GET /api/entries/22"))

        // Nothing is fetched again once it is held
        let before = server.calls.count
        _ = try await sync.refresh(now: now)
        #expect(!server.calls[before...].contains { $0.hasPrefix("GET /api/entries/1") || $0.hasPrefix("GET /api/entries/2") })
    }

    /// Many shared again at once (a whole topic taken off the list): one fresh load, not a request each.
    @Test func manySharedAgainAtOnceReloadsEverything() async throws {
        let server = try seededServer()
        var hidden: Set<Int> = [30]
        for i in 0...ChroniclesLiveSync.refetchLimit {
            try server.put(entry: 200 + i, content: "<p>Task \(i)</p>", metadata: ["_taxonomyId": 1, "_customFields": ["taskDescription": .string("Task \(i)"), "isCompleted": false]])
            hidden.insert(200 + i)
        }
        server.hidden = hidden
        let (client, session) = try await unlocked(server)
        let sync = ChroniclesLiveSync(client: client, session: session)
        _ = try await sync.refresh(now: now)
        server.lock.withLock { server.cursor = 2 }
        _ = try await sync.refresh(now: now)
        server.lock.withLock { server.cursor = 3; server.hidden = [30] }
        let r = try await sync.refresh(now: now)
        #expect(r.isFullLoad)
        #expect(r.snapshot.tasks.count == ChroniclesLiveSync.refetchLimit + 2)
        #expect(!server.calls.contains("GET /api/entries/200"))
    }

    func actions(_ server: FakeChronicles, writes: Collector) async throws -> [LocalTool] {
        let (client, session) = try await unlocked(server)
        let sync = ChroniclesLiveSync(client: client, session: session)
        let snap = try await sync.refresh(now: now).snapshot
        let writer = ChroniclesWriter(client: client, session: session)
        var ctx = ChroniclesActionContext(
            writer: { writer }, snapshot: { snap }, topicID: { await sync.topicID(named: $0) }, hiddenTopicIDs: { [6] },
            estimateNutrients: { _, _, _ in ["calories": 310, "protein": 9, "carbs": 54, "fat": 6, "iron": 2.1, "vitaminD": 0, "vitaminB12": 0, "vitaminC": 3.5] },
            didWrite: { writes.add($0.summary) }, now: { self.now }, timeZone: tz)
        ctx.medication = { await sync.medication($0) }
        ctx.hasDoseLink = { await sync.hasDoseLink($0) }
        return ChroniclesActionTools.all(ctx)
    }

    func tool(_ tools: [LocalTool], _ name: String) -> LocalTool { tools.first { $0.name == name }! }

    @Test func inferredActionsAskFirstAndWriteNothing() async throws {
        let server = try seededServer()
        let tools = try await actions(server, writes: Collector())
        let before = server.entries.count
        let out = try await tool(tools, "log_meal").run(["description": "coffee", "explicit": false])
        #expect(out.hasPrefix("Not done."))
        #expect(server.entries.count == before)
        #expect(!server.calls.contains { $0.hasPrefix("POST /api/entries") })
    }

    @Test func logMealSavesChroniclesShapeAndUndoes() async throws {
        let server = try seededServer()
        let writes = Collector()
        let tools = try await actions(server, writes: writes)
        let out = try await tool(tools, "log_meal").run(["description": "oatmeal with blueberries", "meal_type": "breakfast", "explicit": true])
        #expect(out.contains("Logged oatmeal with blueberries for breakfast, about 310 calories"))
        let id = try #require(server.created.last)
        let (content, meta) = try #require(server.decrypt(id))
        #expect(content == "<p>oatmeal with blueberries</p>")
        #expect(meta["_taxonomyId"]?.int == 3)
        let cf = try #require(meta["_customFields"])
        #expect(cf["mealDescription"]?.string == "oatmeal with blueberries")
        #expect(cf["consumedDate"]?.string == "2026-11-25")
        #expect(cf["calories"]?.string == "310")
        #expect(cf["nutrientSource"]?["calories"]?.string == "ai")
        #expect(meta["_createdAt"] != nil)
        // Undo within the window: the server lets it delete its own new entry
        try await ChroniclesWriter(client: ChroniclesClient(transport: server), session: try await unlocked(server).1).undo(.deleteEntry(id: id))
        #expect(server.entries[id] == nil)
    }

    @Test func doseHabitTaskAndBill() async throws {
        let server = try seededServer()
        let tools = try await actions(server, writes: Collector())
        let (client, session) = try await unlocked(server)
        let writer = ChroniclesWriter(client: client, session: session)

        // Dose: the scheduled 08:00 one, ticked taken
        #expect(try await tool(tools, "log_dose").run(["medication": "vitamin d", "status": "taken", "explicit": true]) == "Marked Vitamin D (08:00) taken.")
        let dose = try #require(server.doses.values.first)
        let rec = try #require(server.openDose(dose["id"]!.string!))
        #expect(rec["status"]?.string == "taken" && rec["scheduledTime"]?.string == "08:00" && rec["medicationPostId"]?.int == 40)
        // Vitamin D 1000 IU: a "medication" Meals row with 25 mcg, linked to this dose (as Chronicles' dashboard does)
        let mealID = try #require(server.created.last)
        let (_, mealMeta) = try #require(server.decrypt(mealID))
        #expect(mealMeta["_doseLink"]?.string == "40|2026-11-25|08:00")
        #expect(mealMeta["_customFields"]?["mealType"]?.string == "medication")
        #expect(mealMeta["_customFields"]?["vitaminD"]?.string == "25")
        #expect(mealMeta["_customFields"]?["nutrientSource"]?["vitaminD"]?.string == "manual")
        try await writer.undo(.all([.restoreDose(uuid: dose["id"]!.string!, date: "2026-11-25", previous: nil), .deleteEntry(id: mealID)]))
        #expect(server.openDose(dose["id"]!.string!)?["status"]?.string == "pending")
        #expect(server.entries[mealID] == nil)

        // Habit: one more check-in on the 25th, in base 36
        #expect(try await tool(tools, "check_habit").run(["habit": "exercise", "explicit": true]) == "Checked off Exercise.")
        let log = try ChroniclesCrypto.openSetting(key: "habitLog", sealed: server.settings["habitLog"]!, keys: [server.mk])
        #expect(log["50"]?["2026-11"]?.string == "0100000000000000000000001")

        // Task: done, then undo puts it back
        #expect(try await tool(tools, "set_task_status").run(["task": "launch deck", "status": "done", "explicit": true]) == "Marked \"Finish launch deck\" done.")
        #expect(server.decrypt(10)?.1["_customFields"]?["isCompleted"]?.bool == true)

        // Bill: paid for its next due date; nothing about the amount reaches what Smith says
        let said = try await tool(tools, "mark_bill_paid").run(["bill": "rent", "explicit": true])
        #expect(said == "Rent marked paid for Thu 26 Nov.")
        #expect(!said.contains("1234") && !said.contains("$"))
        let bill = try #require(server.openBill("0b5c8f4e-8a51-4c3f-9d55-3a1f7c2e9b10"))
        #expect(bill["payments"]?.array?.first?["amountCents"]?.int == 123456)
        #expect(bill["payments"]?.array?.first?["forDue"]?.string == "2026-11-26")
        #expect(bill["notes"]?.string == "CANARY-LIVE-BILLNOTE") // the rest of the bill is kept as it was
    }

    @Test func notesNeverGoIntoTopicsKeptFromAI() async throws {
        let server = try seededServer()
        let tools = try await actions(server, writes: Collector())
        let refused = try await tool(tools, "save_note").run(["text": "a private thought", "topic": "Therapy notes", "explicit": true])
        #expect(refused.contains("keep Therapy notes from AI"))
        #expect(server.created.isEmpty)
        let saved = try await tool(tools, "save_note").run(["text": "Paint the shed blue", "topic": "Idea", "explicit": true])
        #expect(saved == "Saved to Idea.")
    }

    @Test func medicationNutrientsLikeChronicles() {
        #expect(MedNutrients.parse(name: "Vitamin D3", dosage: "1,000 IU") == ["vitaminD": 25])
        #expect(MedNutrients.parse(name: "B12", dosage: "1 mg") == ["vitaminB12": 1000])
        #expect(MedNutrients.parse(name: "Iron", dosage: "65 mg") == ["iron": 65])
        #expect(MedNutrients.parse(name: "Vitamin C", dosage: "1 g") == ["vitaminC": 1000])
        #expect(MedNutrients.parse(name: "Multivitamin", dosage: "1 tablet").isEmpty)
        #expect(MedNutrients.parse(name: "Cetirizine", dosage: "10 mg").isEmpty)
        #expect(MedNutrients.forDose(medicationFields: ["dosage": "1000 IU", "vitaminD": "50"], name: "Vitamin D") == ["vitaminD": 50])
        // A stale AI answer falls back to the name and dosage
        #expect(MedNutrients.forDose(medicationFields: ["dosage": "1000 IU", "vitaminD": "50", "doseNutrientSource": "ai", "doseNutrientBasis": "old"], name: "Vitamin D") == ["vitaminD": 25])
    }

    @Test func serverLimitsAndReKeys() async throws {
        let server = try seededServer()
        let (client, session) = try await unlocked(server)
        let sync = ChroniclesLiveSync(client: client, session: session)
        _ = try await sync.refresh(now: now)

        // 429: the day's entries used up — the tool says so in Chronicles' words, nothing is written
        server.lock.withLock { server.mode = "limit" }
        let tools = try await actions(server, writes: Collector())
        await #expect(throws: ChroniclesError.limit("The Chronicles AI app has added as many entries as it may in a day")) {
            _ = try await tool(tools, "add_task").run(["title": "Buy stamps", "explicit": true])
        }

        // 409 while moving to a new key: sync waits (Smith keeps what it has)
        server.lock.withLock { server.mode = "rekey" }
        await #expect(throws: ChroniclesError.rekeying("Chronicles is moving your journal to a new key. Try again once it has finished.")) {
            _ = try await sync.refresh(now: now)
        }

        // Done: everything is under a new key, so the key in memory opens nothing — never an empty day
        let newKey = SymmetricKey(size: .bits256)
        try server.lock.withLock {
            server.mode = nil
            for (id, row) in server.entries {
                guard let (content, meta) = server.decrypt(id) else { continue }
                let e = try ChroniclesCrypto.encryptPost(content: content, metadata: meta, id: id, key: newKey)
                var r = row.object!
                r["contentEncrypted"] = .string(e.contentEncrypted); r["contentIv"] = .string(e.contentIv)
                r["metadataEncrypted"] = .string(e.metadataEncrypted); r["metadataIv"] = .string(e.metadataIv)
                server.entries[id] = .object(r)
            }
        }
        await #expect(throws: ChroniclesError.keyChanged) { _ = try await ChroniclesLiveSync(client: client, session: session).refresh(now: now) }
    }

    @Test func smithNotesThingsOnHisOwn() {
        var a = AboutYouStore()
        let f = a.note("Doctor's appointment went well; follow-up in March", category: .updates, day: "2026-11-25")
        #expect(f?.text == "Wed 25 Nov: Doctor's appointment went well; follow-up in March")
        #expect(f?.source == .noticed && f?.confirmed == false)
        #expect(a.note("Wed 25 Nov: Doctor's appointment went well; follow-up in March", category: .updates, day: "2026-11-25") == nil)
        a.delete(f!.id)
        #expect(a.note("Doctor's appointment went well; follow-up in March", category: .updates, day: "2026-11-25") == nil) // don't learn it again
        a.paused = true
        #expect(a.note("Loves jazz", category: .likes) == nil)
        #expect(PersonaPrompt.system(spoken: false).contains("save it right"))
    }

    @Test func habitDigitsAndShapes() {
        let next = ChroniclesWriter.incrementHabit(["7": ["2026-11": "1"]], habitID: 7, day: "2026-11-03", by: 1)
        #expect(next["7"]?["2026-11"]?.string == "101")
        let back = ChroniclesWriter.incrementHabit(next, habitID: 7, day: "2026-11-03", by: -1)
        #expect(back["7"]?["2026-11"]?.string == "1")
        #expect(ChroniclesShapes.parseNutrients(#"{"calories": 310.4, "protein": 9, "carbs": 54, "fat": 6, "iron": 0.456, "vitaminD": 0, "vitaminB12": 0, "vitaminC": 3.5}"#)?["iron"] == 0.46)
        #expect(ChroniclesShapes.parseNutrients(#"{"calories": 99999}"#) == nil)
        #expect(ChroniclesShapes.html("one\ntwo <b>") == "<p>one</p><p>two &lt;b&gt;</p>")
    }
}
