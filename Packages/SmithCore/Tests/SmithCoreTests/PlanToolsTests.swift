import Foundation
import Testing
@testable import SmithCore

/// Editing the plan: tasks, blockers, deleting, priorities, events and tags.
@Suite struct PlanToolsTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-25T14:00:00Z")!
    let tz = TimeZone(identifier: "UTC")!

    /// The seeded account, plus two more tasks, a priorities list, two events and two tagged journal entries.
    func planServer() throws -> FakeChronicles {
        let s = try seededServer()
        try s.put(entry: 11, content: "<p>Get passport</p>", metadata: ["_taxonomyId": 1, "_customFields": [
            "taskDescription": "Get passport", "isCompleted": false, "scheduledDate": "2026-11-25", "scheduledTime": "09:00", "priority": "none"]])
        try s.put(entry: 12, content: "<p>Book flights</p>", metadata: ["_taxonomyId": 1, "_customFields": [
            "taskDescription": "Book flights", "isCompleted": false, "scheduledDate": "2026-11-25", "priority": "medium",
            "blockers": [["id": "b1", "taskId": 11], ["id": "b2", "note": "  waiting on\nDana's reply  "], ["id": "b3", "taskId": 999], ["note": ""]]]])
        try s.put(entry: 13, content: "<p>Some notes of their own</p>", metadata: ["_taxonomyId": 1, "_customFields": [
            "taskDescription": "Call the bank", "isCompleted": false, "deadline": "2026-11-27", "priority": "low"]])
        try s.put(entry: 60, content: "<p>Dentist</p>", metadata: ["_taxonomyId": 8, "_customFields": [
            "eventName": "Dentist", "startDate": "2026-11-26", "startTime": "10:00", "endTime": "11:00", "endDate": "", "allDay": false]])
        try s.put(entry: 61, content: "<p>Conference</p>", metadata: ["_taxonomyId": 8, "_customFields": [
            "eventName": "Conference", "startDate": "2026-12-01", "endDate": "2026-12-03", "allDay": true]])
        try s.put(entry: 62, content: "<p>Team sync</p>", metadata: ["_taxonomyId": 8, "_customFields": [
            "eventName": "Team sync", "startDate": "2026-11-02", "startTime": "09:30", "allDay": false, "repeat": "weekly", "repeatInterval": 1]])
        try s.put(entry: 70, content: "<p>Priorities: 11/25/2026</p>", metadata: ["_taxonomyId": 9, "_customFields": [
            "priorities": [["id": "p1", "text": "Ship the deck", "done": false], ["id": "p2", "text": "Call Mum", "done": false]]]])
        try s.put(entry: 21, content: "<p>CANARY-TAGGED-JOURNAL-4Z private words</p>", metadata: ["_taxonomyId": 2, "_customFields": ["tags": ["Travel", "travel", " work  trip ", 5]]])
        try s.put(entry: 22, content: "<p>CANARY-IDEA-8Q</p>", metadata: ["_taxonomyId": 7, "_customFields": ["tags": ["ideas"]]])
        return s
    }

    func unlocked(_ server: FakeChronicles) async throws -> (ChroniclesClient, ChroniclesSession) {
        let client = ChroniclesClient(transport: server)
        guard case .unlocked(let s) = try await client.signIn(email: FakeChronicles.email, password: FakeChronicles.password) else {
            Issue.record("expected unlock"); throw ChroniclesError.locked
        }
        return (client, s)
    }

    struct Setup {
        var tools: [LocalTool]
        var writer: ChroniclesWriter
        var snapshot: ChroniclesSnapshot
        var journal: [TransientJournalEntry]
        func tool(_ name: String) -> LocalTool { tools.first { $0.name == name }! }
    }

    func setup(_ server: FakeChronicles, writes: Collector = Collector(), tagged: [TaggedEntry]? = nil) async throws -> Setup {
        let (client, session) = try await unlocked(server)
        let sync = ChroniclesLiveSync(client: client, session: session)
        let r = try await sync.refresh(now: now)
        let snap = r.snapshot
        let writer = ChroniclesWriter(client: client, session: session)
        let records = r.journal.map { JournalRecord(id: $0.id, day: $0.day, topicIDs: $0.topicIDs, fingerprint: "x", tags: $0.tags.isEmpty ? nil : $0.tags) }
        let visible = tagged ?? TaggedEntry.visible(records, mode: .general, neverMention: [], topics: snap.topics)
        var ctx = ChroniclesActionContext(
            writer: { writer }, snapshot: { snap }, topicID: { await sync.topicID(named: $0) }, hiddenTopicIDs: { [6] },
            estimateNutrients: { _, _, _ in nil }, didWrite: { writes.add($0.summary) }, now: { self.now }, timeZone: tz)
        ctx.taggedEntries = { visible }
        return Setup(tools: ChroniclesActionTools.all(ctx), writer: writer, snapshot: snap, journal: r.journal)
    }

    func fields(_ server: FakeChronicles, _ id: Int) -> JSONValue { server.decrypt(id)?.1["_customFields"] ?? [:] }

    // MARK: reading

    @Test func blockersTypesAndTagsAreRead() async throws {
        let s = try await setup(try planServer())
        let flights = try #require(s.snapshot.tasks.first { $0.id == "12" })
        // Tidied: one line, the empty note dropped, the missing task kept (it just doesn't block)
        #expect(flights.blockers.map(\.note) == [nil, "waiting on Dana's reply", nil])
        #expect(flights.blockerWords(in: s.snapshot.tasks) == ["Get passport", "waiting on Dana's reply"])
        #expect(s.snapshot.priorities?.entryID == "70")
        #expect(s.snapshot.priorities?.items.map(\.id) == ["p1", "p2"])
        let travel = try #require(s.journal.first { $0.id == "21" })
        #expect(travel.tags == ["Travel", "work trip"])
        #expect(s.snapshot.taskTypes == ["Regular task", "Small victory"])
    }

    @Test func aDoneTaskNoLongerBlocks() async throws {
        var snap = try await setup(try planServer()).snapshot
        let i = try #require(snap.tasks.firstIndex { $0.id == "11" })
        snap.tasks[i].status = .done
        let flights = try #require(snap.tasks.first { $0.id == "12" })
        #expect(flights.blockerWords(in: snap.tasks) == ["waiting on Dana's reply"])
    }

    @Test func todayShowsWhatIsBlocked() async throws {
        let snap = try await setup(try planServer()).snapshot
        let o = DayOverview.make(snap, today: "2026-11-25")
        #expect(o.blockedBy["12"] == ["Get passport", "waiting on Dana's reply"])
        #expect(o.blockedTasks.map(\.title) == ["Book flights"])
        #expect(o.nextTask?.title == "Get passport")
        #expect(o.priorityItems.map(\.text) == ["Ship the deck", "Call Mum"])
        #expect(o.contextText().contains("Book flights (medium priority, blocked by: Get passport; waiting on Dana's reply)"))
    }

    @Test func findTasksShowsIdsTypesAndBlockers() async throws {
        let snap = try await setup(try planServer()).snapshot
        let out = try await FindTasksTool { snap }.run(["blocked_only": true])
        #expect(out.contains("- Book flights (todo, scheduled 2026-11-25, medium priority, blocked by: Get passport; waiting on Dana's reply, id 12)"))
        #expect(!out.contains("Finish launch deck"))
        #expect(out.contains("Task types: Regular task, Small victory."))
    }

    @Test func olderSavedSnapshotsStillOpen() throws {
        // Saved before blockers, task types and priority ids were read
        let json = #"{"exportedAt":0,"tasks":[{"id":"1","title":"T","status":"todo","priority":"none","openChecklistItems":0}],"goals":[],"milestones":[],"calendar":[],"habits":[],"medications":[],"doseLogs":[],"priorities":{"day":"2026-11-25","items":[{"text":"A","done":false}]},"vision":{"areas":[]},"bills":[],"topics":{},"wellness":[]}"#
        let snap = try JSONDecoder().decode(ChroniclesSnapshot.self, from: Data(json.utf8))
        #expect(snap.tasks[0].blockers.isEmpty && snap.tasks[0].taskType == nil)
        #expect(snap.priorities?.entryID == nil)
        let rec = try JSONDecoder().decode(JournalRecord.self, from: Data(#"{"id":"1","day":"2026-11-25","topicIDs":[],"fingerprint":"f","themes":[]}"#.utf8))
        #expect(rec.tags == nil)
    }

    // MARK: tasks

    @Test func editTaskAsksFirstThenMovesItAndUndoes() async throws {
        let server = try planServer()
        let s = try await setup(server)
        let ask = try await s.tool("edit_task").run(["task": "launch deck", "date": "2026-11-28", "explicit": false])
        #expect(ask.hasPrefix("Not done.") && ask.contains("planned for Sat 28 Nov"))
        #expect(fields(server, 10)["scheduledDate"]?.string == "2026-11-25")

        let out = try await s.tool("edit_task").run(["task": "launch deck", "date": "2026-11-28", "time": "15:30", "priority": "urgent",
                                                    "type": "small victory", "explicit": true])
        #expect(out == "Changed \"Finish launch deck\": planned for Sat 28 Nov, at 15:30, urgent priority, type Small victory.")
        let cf = fields(server, 10)
        #expect(cf["scheduledDate"]?.string == "2026-11-28" && cf["scheduledTime"]?.string == "15:30")
        #expect(cf["priority"]?.string == "urgent" && cf["taskType"]?.string == "Small victory")
        #expect(cf["isCompleted"]?.bool == false)   // untouched

        try await s.writer.undo(.restoreFields(id: 10, fields: ["scheduledDate": "2026-11-25", "scheduledTime": nil, "priority": "high", "taskType": nil]))
        #expect(fields(server, 10)["scheduledDate"]?.string == "2026-11-25" && fields(server, 10)["scheduledTime"] == nil)
    }

    @Test func clearingTheDateClearsTheTimeAndUnknownTypesAreRefused() async throws {
        let server = try planServer()
        let s = try await setup(server)
        _ = try await s.tool("edit_task").run(["task": "passport", "date": "none", "explicit": true])
        #expect(fields(server, 11)["scheduledDate"]?.string == "" && fields(server, 11)["scheduledTime"]?.string == "")
        let bad = try await s.tool("edit_task").run(["task": "passport", "type": "Errand", "explicit": true])
        #expect(bad.contains("no task type called \"Errand\""))
        let badDate = try await s.tool("edit_task").run(["task": "passport", "date": "Friday", "explicit": true])
        #expect(badDate == "date must be YYYY-MM-DD.")
    }

    @Test func renamingKeepsTextOfTheirOwn() async throws {
        let server = try planServer()
        let s = try await setup(server)
        _ = try await s.tool("edit_task").run(["task": "launch deck", "title": "Finish the launch deck", "explicit": true])
        #expect(server.decrypt(10)?.0 == "<p>Finish the launch deck</p>")
        _ = try await s.tool("edit_task").run(["task": "bank", "title": "Ring the bank", "explicit": true])
        #expect(server.decrypt(13)?.0 == "<p>Some notes of their own</p>")
        #expect(fields(server, 13)["taskDescription"]?.string == "Ring the bank")
    }

    @Test func blockersAddRemoveAndClear() async throws {
        let server = try planServer()
        let s = try await setup(server)
        let tool = s.tool("task_blockers")
        #expect(try await tool.run(["task": "launch deck", "action": "add", "note": "waiting on the numbers", "explicit": false]).hasPrefix("Not done."))
        #expect(try await tool.run(["task": "launch deck", "action": "add", "blocked_by_task": "launch deck", "explicit": true]) == "A task can't block itself.")
        #expect(try await tool.run(["task": "launch deck", "action": "add", "blocked_by_task": "bank", "explicit": true])
                == "\"Finish launch deck\" is now blocked by \"Call the bank\".")
        _ = try await tool.run(["task": "launch deck", "action": "add", "note": "waiting on the numbers", "explicit": true])
        let list = fields(server, 10)["blockers"]?.array ?? []
        #expect(list.count == 2)
        #expect(list[0]["taskId"]?.int == 13 && list[1]["note"]?.string == "waiting on the numbers")
        #expect(list.allSatisfy { ($0["id"]?.string ?? "").count > 8 })

        // Removing from Smith's view of the task (the flights' Dana note)
        #expect(try await tool.run(["task": "flights", "action": "remove", "which": "Dana", "explicit": true]) == "Took that blocker off \"Book flights\".")
        #expect((fields(server, 12)["blockers"]?.array ?? []).map { $0["id"]?.string } == ["b1", "b3"])
        #expect(try await tool.run(["task": "flights", "action": "clear", "explicit": true]) == "Cleared the blockers on \"Book flights\".")
        #expect(fields(server, 12)["blockers"]?.array?.isEmpty == true)
    }

    @Test func aBlockerSavedWithoutAnIdCanStillBeRemoved() async throws {
        let server = try planServer()
        // No ids: every read makes new ones, so Smith's copy and the fresh read differ
        try server.put(entry: 12, content: "<p>Book flights</p>", metadata: ["_taxonomyId": 1, "_customFields": [
            "taskDescription": "Book flights", "isCompleted": false, "priority": "medium",
            "blockers": [["taskId": 11], ["note": "waiting on Dana"]]]])
        let s = try await setup(server)
        let tool = s.tool("task_blockers")
        #expect(try await tool.run(["task": "flights", "action": "remove", "which": "Dana", "explicit": true]) == "Took that blocker off \"Book flights\".")
        let left = fields(server, 12)["blockers"]?.array ?? []
        #expect(left.count == 1 && left[0]["taskId"]?.int == 11)
        // Gone in Chronicles since Smith looked: said so, not claimed
        #expect(try await tool.run(["task": "flights", "action": "remove", "which": "Dana", "explicit": true])
                == "That blocker wasn't on \"Book flights\" any more; nothing was changed.")
    }

    @Test func deleteKeepsACopyAndUndoPutsItBack() async throws {
        let server = try planServer()
        let writes = Collector()
        let s = try await setup(server, writes: writes)
        #expect(try await s.tool("delete_task").run(["task": "bank", "explicit": false]).hasPrefix("Not done."))
        #expect(server.entries[13] != nil)
        let out = try await s.tool("delete_task").run(["task": "bank", "explicit": true])
        #expect(out == "Deleted the task \"Call the bank\". Chronicles keeps a copy for two weeks.")
        #expect(server.entries[13] == nil)
        let change = try #require(server.keptDeletes.keys.first)
        try await s.writer.undo(.restoreDeleted(changeID: change))
        #expect(server.entries[13] != nil)
        #expect(fields(server, 13)["taskDescription"]?.string == "Call the bank")
    }

    @Test func deleteOnAnOlderChroniclesSaysSo() async throws {
        let server = try planServer()
        server.mode = "oldDelete"
        let s = try await setup(server)
        let out = try await s.tool("delete_task").run(["task": "bank", "explicit": true])
        #expect(out.contains("didn't let Smith delete it"))
        #expect(server.entries[13] != nil)
    }

    @Test func ambiguousNamesAskWhichOne() async throws {
        let s = try await setup(try planServer())
        let none = try await s.tool("edit_task").run(["task": "groceries", "priority": "low", "explicit": true])
        #expect(none == "No task matches \"groceries\".")
        let two = try await s.tool("edit_task").run(["task": "book bank", "priority": "low", "explicit": true])
        #expect(two.hasPrefix("Which one?"))
    }

    // MARK: priorities

    @Test func prioritiesListChanges() {
        let items: [PriorityList.Item] = [.init(text: "Ship the deck", done: false, id: "p1"), .init(text: "Call Mum", done: false, id: "p2")]
        let (added, s1) = EditPrioritiesTool.apply("add", to: items, item: nil, text: "Pay rent", position: 1)
        #expect(added?.map(\.text) == ["Pay rent", "Ship the deck", "Call Mum"] && s1 == "added \"Pay rent\" to the priorities")
        let (moved, _) = EditPrioritiesTool.apply("move", to: items, item: "mum", text: nil, position: 1)
        #expect(moved?.map(\.id) == ["p2", "p1"])
        let (done, _) = EditPrioritiesTool.apply("done", to: items, item: "2", text: nil, position: nil)
        #expect(done?[1].done == true)
        let (renamed, _) = EditPrioritiesTool.apply("rename", to: items, item: "deck", text: "Ship the launch deck", position: nil)
        #expect(renamed?[0].text == "Ship the launch deck" && renamed?[0].id == "p1")
        let (gone, s2) = EditPrioritiesTool.apply("remove", to: items, item: "9", text: nil, position: nil)
        #expect(gone == nil && s2 == "There's no number 9 on the list.")
    }

    @Test func prioritiesAreSavedToTheNewestList() async throws {
        let server = try planServer()
        let s = try await setup(server)
        let out = try await s.tool("edit_priorities").run(["action": "done", "item": "mum", "explicit": true])
        #expect(out == "Ticked off \"Call Mum\".")
        let list = fields(server, 70)["priorities"]?.array ?? []
        #expect(list.map { $0["id"]?.string } == ["p1", "p2"] && list[1]["done"]?.bool == true)
        #expect(try await s.tool("edit_priorities").run(["action": "add", "text": "Pay rent", "explicit": false]).contains("add \"Pay rent\""))
        #expect(try await s.tool("edit_priorities").run(["action": "done", "item": "deck", "explicit": false]).contains("like you to tick off \"Ship the deck\""))
    }

    @Test func aPriorityIsFoundByIdWhenTheListWasReordered() async throws {
        let server = try planServer()
        let s = try await setup(server)
        // Reordered in Chronicles after Smith looked: number 2 was "Call Mum" and still means it
        try server.put(entry: 70, content: "<p>Priorities: 11/25/2026</p>", metadata: ["_taxonomyId": 9, "_customFields": [
            "priorities": [["id": "p2", "text": "Call Mum", "done": false], ["id": "p1", "text": "Ship the deck", "done": false]]]])
        #expect(try await s.tool("edit_priorities").run(["action": "done", "item": "2", "explicit": true]) == "Ticked off \"Call Mum\".")
        let list = fields(server, 70)["priorities"]?.array ?? []
        #expect(list[0]["id"]?.string == "p2" && list[0]["done"]?.bool == true && list[1]["done"]?.bool == false)
        // Removed in Chronicles since: nothing changes
        try server.put(entry: 70, content: "<p>Priorities: 11/25/2026</p>", metadata: ["_taxonomyId": 9, "_customFields": [
            "priorities": [["id": "p1", "text": "Ship the deck", "done": false]]]])
        #expect(try await s.tool("edit_priorities").run(["action": "remove", "item": "mum", "explicit": true])
                == "\"Call Mum\" isn't on the priorities list any more; nothing was changed.")
        #expect(fields(server, 70)["priorities"]?.array?.count == 1)
        // The Today page's tick: by id too, and false when the item is gone
        let mum = PriorityList.Item(text: "Call Mum", done: false, id: "p2")
        #expect(try await s.writer.updatePriorities(entryID: 70) { items in
            guard let i = items.firstIndex(where: { $0.same(mum) }) else { return nil }
            var l = items; l[i].done = true; return l
        } == false)
    }

    @Test func theTodayDoseTickGoesByMedicationID() async throws {
        let server = try planServer()
        // A second medication whose name would make "vitamin d" ask "which one?"
        try server.put(entry: 41, content: "<p>Vitamin D3</p>", metadata: ["_taxonomyId": 4, "_customFields": [
            "medicationName": "Vitamin D3", "dosage": "", "frequency": "once_daily", "scheduleTimes": ["20:00"], "isActive": true]])
        let writes = Collector()
        let s = try await setup(server, writes: writes)
        let tool = try #require(s.tool("log_dose") as? LogDoseTool)
        try await tool.markTaken(medicationID: "41", time: "20:00")
        #expect(writes.items == ["Marked Vitamin D3 (20:00) taken."])
        let rec = try #require(server.doses.values.compactMap { server.openDose($0["id"]!.string!) }.first)
        #expect(rec["medicationPostId"]?.int == 41 && rec["scheduledTime"]?.string == "20:00" && rec["status"]?.string == "taken")
        // A time that isn't on its schedule, or a medication that isn't there, is an error, not a quiet nothing
        await #expect(throws: ChroniclesError.self) { try await tool.markTaken(medicationID: "41", time: "09:00") }
        await #expect(throws: ChroniclesError.self) { try await tool.markTaken(medicationID: "999", time: "08:00") }
    }

    @Test func undoChangeUndoesSmithsRecentChanges() async throws {
        let undone = Collector()
        var ctx = ChroniclesActionContext(writer: { nil }, snapshot: { nil }, topicID: { _ in nil }, hiddenTopicIDs: { [] },
                                          estimateNutrients: { _, _, _ in nil }, didWrite: { _ in })
        ctx.recentChanges = { ["Changed \"Dentist\": moved to Fri 27 Nov.", "Deleted the task \"Book flights\"."] }
        ctx.undoChange = { i in undone.add(String(i)); return "Undid it." }
        let tool = UndoChangeTool(ctx)
        #expect(try await tool.run(["explicit": false]).contains("Dentist"))
        #expect(undone.items.isEmpty)
        #expect(try await tool.run(["explicit": true]) == "Undid it.")
        #expect(try await tool.run(["change": "flights", "explicit": true]) == "Undid it.")
        #expect(undone.items == ["0", "1"])

        ctx.recentChanges = { [] }
        #expect(try await UndoChangeTool(ctx).run(["explicit": true]).hasPrefix("Nothing you changed"))
    }

    @Test func aFirstPrioritiesListIsCreated() async throws {
        let server = try planServer()
        server.entries[70] = nil
        let s = try await setup(server)
        #expect(try await s.tool("edit_priorities").run(["action": "done", "item": "x", "explicit": true]) == "The priorities list is empty.")
        let out = try await s.tool("edit_priorities").run(["action": "add", "text": "Pay rent", "explicit": true])
        #expect(out == "Started a priorities list: added \"Pay rent\" to the priorities.")
        let id = try #require(server.created.last)
        #expect(server.decrypt(id)?.0 == "<p>Priorities: 11/25/2026</p>")
        #expect(fields(server, id)["priorities"]?.array?.first?["text"]?.string == "Pay rent")
    }

    @Test func todayPageCheckboxesSave() async throws {
        let server = try planServer()
        let s = try await setup(server)
        try await s.writer.setTaskStatus(id: 11, status: "done")
        #expect(fields(server, 11)["isCompleted"]?.bool == true)
        try await s.writer.setTaskStatus(id: 11, status: "todo")
        #expect(fields(server, 11)["isCompleted"]?.bool == false)
        try await s.writer.updatePriorities(entryID: 70) { items in
            var l = items; l[1].done = true; return l + [.init(text: "Pay rent", done: false, id: "p3")]
        }
        let list = fields(server, 70)["priorities"]?.array ?? []
        #expect(list.map { $0["id"]?.string } == ["p1", "p2", "p3"] && list[1]["done"]?.bool == true)
    }

    @Test func winsAndTheOpenShoppingListAreReadAndSaved() async throws {
        let server = try planServer()
        try server.put(entry: 80, content: "<p>Wins: 11/25/2026</p><ul><li><p>Ran 5k</p></li></ul>", metadata: ["_taxonomyId": 11, "_customFields": [
            "wins": [["id": "w1", "text": "Ran 5k"], ["text": "no id"]]]])
        try server.put(entry: 90, content: "<p>Old list</p>", metadata: ["_taxonomyId": 12, "_customFields": [
            "items": [["id": "s0", "name": "Milk", "category": "dairy", "checked": true]]]])
        try server.put(entry: 91, content: "<p>Weekend shop</p>", metadata: ["_taxonomyId": 12, "_customFields": [
            "items": [["id": "s1", "name": "Eggs", "category": "dairy", "checked": false], ["id": "s2", "name": "Bread", "category": "bakery", "checked": true]],
            "notes": "CANARY-SHOPNOTE-3T"]])
        let s = try await setup(server)
        #expect(s.snapshot.wins?.items.map(\.text) == ["Ran 5k"])
        // Every active list, newest first; the old one has everything got
        try server.put(entry: 92, content: "<p>Hardware store</p>", metadata: ["_taxonomyId": 12, "_customFields": ["items": []]])
        let all = try await setup(server).snapshot.shoppingLists ?? []
        #expect(all.map(\.title).sorted() == ["Hardware store", "Weekend shop"])
        #expect(!all.contains { $0.entryID == "90" })
        #expect(s.snapshot.shoppingLists?.map(\.entryID) == ["91"])
        let o = DayOverview.make(s.snapshot, today: "2026-11-25")
        #expect(o.contextText().contains("Wins list: Ran 5k"))
        #expect(o.contextText().contains("Shopping list (Weekend shop): still to get: Eggs"))
        #expect(!o.contextText().contains("CANARY"))

        try await s.writer.updateWins(entryID: 80) { $0 + [.init(id: "w2", text: "Fixed the sink")] }
        #expect(server.decrypt(80)?.0 == "<p>Wins: 11/25/2026</p><ul><li><p>Ran 5k</p></li><li><p>Fixed the sink</p></li></ul>")
        try await s.writer.updateShopping(entryID: 91) { items in
            var l = items; l[0].checked = true; return l + [.init(id: "s3", name: "Apples")]
        }
        let items = fields(server, 91)["items"]?.array ?? []
        #expect(items.map { $0["id"]?.string } == ["s1", "s2", "s3"] && items[0]["checked"]?.bool == true)
        #expect(items[2]["category"]?.string == "other")
        #expect(fields(server, 91)["notes"]?.string == "CANARY-SHOPNOTE-3T")   // left as it was
        let shape = ChroniclesShapes.newWins([.init(id: "w9", text: "A & B")], day: "2026-11-25", topicID: 11)
        #expect(shape.content == "<p>Wins: 11/25/2026</p><ul><li><p>A &amp; B</p></li></ul>")
    }

    @Test func medicationsHabitsAndExerciseForToday() async throws {
        let server = try planServer()
        // Wed 25 Nov: the yoga routine runs Mon/Wed/Fri at 07:00 and 18:00; the swim only on Sundays
        try server.put(entry: 100, content: "<p>Morning yoga</p>", metadata: ["_taxonomyId": 13, "_customFields": [
            "routineName": "Morning yoga", "exerciseType": "yoga", "duration": "", "days": [1, 3, 5], "scheduleTimes": ["07:00", "18:00"],
            "items": [["id": "i1", "name": "Sun salutes", "amount": "10 min"], ["id": "i2", "name": "Stretch", "amount": "90 sec"]]]])
        try server.put(entry: 101, content: "<p>Swim</p>", metadata: ["_taxonomyId": 13, "_customFields": [
            "routineName": "Swim", "exerciseType": "swimming", "duration": "45", "days": [0], "scheduleTimes": ["08:00"]]])
        try server.put(entry: 102, content: "<p>Morning yoga · Yoga · 12 min</p>", metadata: ["_taxonomyId": 14, "_routineLink": "100|2026-11-25|07:00",
            "_customFields": ["exerciseType": "yoga", "notes": "CANARY-EXERCISENOTE-6U"]])
        let s = try await setup(server)
        let r = try #require(s.snapshot.routines?.first { $0.id == "100" })
        #expect(r.minutes == 12 && r.itemIDs == ["i1", "i2"])
        let o = DayOverview.make(s.snapshot, today: "2026-11-25")
        #expect(o.exercise.map(\.key) == ["100|2026-11-25|07:00", "100|2026-11-25|18:00"])
        #expect(o.exercise.map(\.done) == [true, false])
        #expect(o.habits.map(\.name) == ["Exercise"] && o.habits[0].count == 0 && !o.habits[0].done)
        #expect(o.doses.first?.medicationID == "40")
        #expect(o.contextText().contains("Exercise today: 07:00 Morning yoga done; 18:00 Morning yoga not yet"))
        #expect(!o.contextText().contains("CANARY"))

        // Ticking the evening session logs it the way Chronicles does
        let id = try await s.writer.logRoutineSession(r, day: "2026-11-25", time: "18:00", exerciseTopicID: 14)
        let (content, meta) = try #require(server.decrypt(id))
        #expect(content == "<p>Morning yoga · Yoga · 12 min</p>")
        #expect(meta["_routineLink"]?.string == "100|2026-11-25|18:00" && meta["_taxonomyId"]?.int == 14)
        let cf = try #require(meta["_customFields"])
        #expect(cf["duration"]?.string == "12" && cf["performedDate"]?.string == "2026-11-25" && cf["performedTime"]?.string == "18:00")
        #expect(cf["routineId"]?.int == 100 && cf["routineItemsDone"]?.array?.compactMap(\.string) == ["i1", "i2"])
        #expect(ExportParser.amountMinutes("1 hr") == 60 && ExportParser.amountMinutes("90 sec") == 1.5 && ExportParser.amountMinutes("lots") == 0)
    }

    @Test func mediaIsReadWithItsNotes() async throws {
        let server = try planServer()
        try server.put(entry: 110, content: "<p>Piranesi</p>", metadata: ["_taxonomyId": 15, "_customFields": [
            "mediaTitle": "Piranesi", "mediaType": "book", "creator": "Susanna Clarke", "year": "2020", "genre": "Fantasy",
            "rating": 4.5, "shelf": "current", "progress": 60, "notes": "The statues chapter stayed with me.", "tags": ["book club"],
            "cover": ["dataUrl": "data:image/jpeg;base64,AAAA", "source": "openlibrary"]]])
        try server.put(entry: 111, content: "<p>Severance</p>", metadata: ["_taxonomyId": 15, "_customFields": [
            "mediaTitle": "Severance", "mediaType": "tv", "season": "Season 2", "shelf": "want", "rating": 0]])
        let s = try await setup(server)
        let media = s.snapshot.media ?? []
        #expect(media.map(\.title).sorted() == ["Piranesi", "Severance"])
        let snap = s.snapshot
        let out = try await FindMediaTool { snap }.run(["shelf": "current"])
        #expect(out.contains("- Piranesi (Book, by Susanna Clarke, 2020, Fantasy, Reading, 60% through, rated 4.5 of 5, tags: book club)"))
        #expect(out.contains("Notes: The statues chapter stayed with me."))
        #expect(!out.contains("base64") && !out.contains("Severance"))
        #expect(try await FindMediaTool { snap }.run(["query": "statues"]).contains("Piranesi"))
        #expect(try await FindMediaTool { snap }.run(["type": "tv"]).contains("Severance (TV show, Season 2, Want to watch)"))
    }

    // MARK: events

    @Test func eventsMoveAndKeepTheirLength() async throws {
        let server = try planServer()
        let s = try await setup(server)
        let out = try await s.tool("edit_event").run(["event": "dentist", "date": "2026-11-27", "start_time": "14:00", "end_time": "15:00", "explicit": true])
        #expect(out == "Changed \"Dentist\": moved to Fri 27 Nov, starts 14:00, ends 15:00.")
        #expect(fields(server, 60)["startDate"]?.string == "2026-11-27" && fields(server, 60)["startTime"]?.string == "14:00")
        _ = try await s.tool("edit_event").run(["event": "conference", "date": "2026-12-08", "explicit": true])
        #expect(fields(server, 61)["startDate"]?.string == "2026-12-08" && fields(server, 61)["endDate"]?.string == "2026-12-10")
    }

    @Test func repeatingEventsAskAboutTheWholeSeries() async throws {
        let server = try planServer()
        let s = try await setup(server)
        let out = try await s.tool("edit_event").run(["event": "team sync", "start_time": "10:00", "explicit": true])
        #expect(out.hasPrefix("Not done.") && out.contains("repeats"))
        #expect(fields(server, 62)["startTime"]?.string == "09:30")
        _ = try await s.tool("edit_event").run(["event": "team sync", "start_time": "10:00", "whole_series": true, "explicit": true])
        #expect(fields(server, 62)["startTime"]?.string == "10:00")
    }

    // MARK: tags

    @Test func tagRulesMatchChronicles() {
        #expect(EntryTags.clean("  big\n  trip ") == "big trip")
        #expect(EntryTags.clean(String(repeating: "x", count: 60)).count == 40)
        #expect(EntryTags.adding("TRAVEL", to: ["travel"]) == ["travel"])
        #expect(EntryTags.adding("x", to: (1...20).map(String.init)).count == 20)
        #expect(EntryTags.removing("Travel", from: ["travel", "work"]) == ["work"])
    }

    @Test func tagsStayPrivateWhenTheJournalIsntShared() {
        let records = [JournalRecord(id: "1", day: "2026-11-24", topicIDs: ["2"], fingerprint: "f", tags: ["travel"]),
                       JournalRecord(id: "2", day: "2026-11-25", topicIDs: ["6"], fingerprint: "f", tags: ["therapy"])]
        let topics = ["2": "Journal", "6": "Therapy notes"]
        #expect(TaggedEntry.visible(records, mode: .off, neverMention: [], topics: topics).isEmpty)
        let seen = TaggedEntry.visible(records, mode: .countsOnly, neverMention: ["6"], topics: topics)
        #expect(seen == [TaggedEntry(id: "1", day: "2026-11-24", topic: "Journal", tags: ["travel"])])
    }

    @Test func findTagsNeverShowsEntryText() async throws {
        let s = try await setup(try planServer())
        let records = s.journal.map { JournalRecord(id: $0.id, day: $0.day, topicIDs: $0.topicIDs, fingerprint: "x", tags: $0.tags) }
        let visible = TaggedEntry.visible(records, mode: .general, neverMention: [], topics: s.snapshot.topics)
        let tool = FindTagsTool { visible }
        let all = try await tool.run([:])
        #expect(all.contains("Tags in use: ideas (1), Travel (1), work trip (1)"))
        let travel = try await tool.run(["tag": "travel"])
        #expect(travel.contains("Journal, id 21, tags: Travel, work trip"))
        for out in [all, travel] {
            #expect(!out.contains("CANARY") && !out.contains("private words") && !out.contains("landlord"))
        }
    }

    @Test func tagEntryAddsAndRemovesOnlyOnEntriesSmithMaySee() async throws {
        let server = try planServer()
        let s = try await setup(server)
        let out = try await s.tool("tag_entry").run(["entry_id": "21", "add": ["Lisbon"], "remove": ["work trip"], "explicit": true])
        #expect(out == "The Journal entry from Fri 20 Nov is now tagged: Travel, Lisbon.")
        #expect(fields(server, 21)["tags"]?.array?.compactMap(\.string) == ["Travel", "Lisbon"])
        // The journal text is untouched
        #expect(server.decrypt(21)?.0 == "<p>CANARY-TAGGED-JOURNAL-4Z private words</p>")
        // Not on the list Smith may see (here: sharing off), not changed
        let off = try await setup(server, tagged: [])
        #expect(try await off.tool("tag_entry").run(["entry_id": "21", "add": ["x"], "explicit": true]).hasPrefix("No entry with that id"))
        // A task isn't a tagged entry
        #expect(try await s.tool("tag_entry").run(["entry_id": "10", "add": ["x"], "explicit": true]).hasPrefix("No entry with that id"))
    }
}
