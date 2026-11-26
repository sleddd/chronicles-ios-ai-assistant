import Foundation
import Testing
@testable import SmithCore

@Suite struct SmithRecordsTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func fact(_ text: String, id: UUID = UUID()) -> SmithRecord {
        .fact(Fact(id: id, text: text, category: .people, source: .saidInChat, confirmed: true, at: now))
    }

    @Test func recordsRoundTripThroughAnEntry() throws {
        let records: [SmithRecord] = [
            fact("Maya is her sister"),
            .dontLearn(DontLearn(marker: "likes: coffee after", at: now)),
            .letter(Letter(date: now, yourMessage: "Rough day.", text: "My dear,\n\nI thought of you.\n\nHenry", favorite: true)),
            .conversation(ConversationSummary(day: "2026-11-25", text: "Talked about the new glasses.", at: now)),
        ]
        for r in records {
            let e = r.entry(topicID: 42)
            #expect(e.metadata["_taxonomyId"]?.int == 42)
            let back = try #require(SmithRecord.from(content: e.content, metadata: e.metadata, topic: r.topic, entryID: 9, updatedAt: now))
            #expect(back.id == r.id)
            #expect(back.fingerprint == r.fingerprint)
        }
    }

    @Test func entriesThePersonWroteAreReadByTopic() throws {
        let meta: JSONValue = ["_taxonomyId": 7, "_customFields": [:]]
        let r = try #require(SmithRecord.from(content: "<p>Prefers mornings</p>", metadata: meta, topic: SmithTopics.memories, entryID: 55, updatedAt: now))
        guard case .fact(let f) = r else { Issue.record("not a fact"); return }
        #expect(f.text == "Prefers mornings")
        #expect(r.id == UUID.fromEntry(55))   // stable across syncs
        #expect(SmithTopics.which("  smith MEMORIES ") == SmithTopics.memories)
        #expect(ExportParser.kind(of: "Letters") == "smith")   // never read as journal
    }

    @Test func mergeFollowsWhereTheChangeHappened() {
        let a = fact("A"), b = fact("B")
        let aEdited: SmithRecord = { if case .fact(var f) = a { f.text = "A2"; return .fact(f) }; return a }()
        let base = [a.id: a.fingerprint, b.id: b.fingerprint]

        // Edited here → update Chronicles
        var p = SmithMerge.plan(remote: [.init(entryID: 1, record: a, owned: true)], local: [aEdited], base: [a.id: a.fingerprint])
        #expect(p.update.map(\.entryID) == [1] && p.keep == [aEdited])

        // Edited in Chronicles → take it
        p = SmithMerge.plan(remote: [.init(entryID: 1, record: aEdited, owned: true)], local: [a], base: [a.id: a.fingerprint])
        #expect(p.update.isEmpty && p.keep == [aEdited])

        // Deleted here → delete the entry; deleted elsewhere → gone here
        p = SmithMerge.plan(remote: [.init(entryID: 1, record: a, owned: true), .init(entryID: 2, record: b, owned: true)], local: [b], base: base)
        #expect(p.delete == [1] && p.keep == [b])
        p = SmithMerge.plan(remote: [.init(entryID: 2, record: b, owned: true)], local: [a, b], base: base)
        #expect(p.keep == [b] && p.create.isEmpty)

        // New here → create; new elsewhere → add here
        let c = fact("C")
        p = SmithMerge.plan(remote: [.init(entryID: 2, record: b, owned: true)], local: [b, c], base: [b.id: b.fingerprint])
        #expect(p.create == [c] && p.keep == [b, c])
        p = SmithMerge.plan(remote: [.init(entryID: 3, record: c, owned: true)], local: [], base: [:])
        #expect(p.keep == [c] && p.create.isEmpty)

        // Both changed → Chronicles wins. The person's own entries follow the same rules:
        // what they edit or delete in Smith is sent, not put back
        let aOther: SmithRecord = { if case .fact(var f) = a { f.text = "A3"; return .fact(f) }; return a }()
        p = SmithMerge.plan(remote: [.init(entryID: 1, record: aOther, owned: true)], local: [aEdited], base: [a.id: a.fingerprint])
        #expect(p.keep == [aOther] && p.update.isEmpty)
        p = SmithMerge.plan(remote: [.init(entryID: 4, record: a, owned: false)], local: [aEdited], base: [a.id: a.fingerprint])
        #expect(p.keep == [aEdited] && p.update.map(\.entryID) == [4])
        p = SmithMerge.plan(remote: [.init(entryID: 4, record: a, owned: false)], local: [], base: [a.id: a.fingerprint])
        #expect(p.delete == [4] && p.keep.isEmpty)
        // Never agreed on (first sight of it): Chronicles' copy is taken, nothing is sent
        p = SmithMerge.plan(remote: [.init(entryID: 4, record: a, owned: false)], local: [aEdited], base: [:])
        #expect(p.keep == [a] && p.update.isEmpty && p.delete.isEmpty)
        // The topic of Smith's own is "Smith letters"; a plain "Letters" topic is the person's
        #expect(SmithTopics.which("Letters") == nil && SmithTopics.which("smith letters") == SmithTopics.letters)
    }
}

@Suite struct WellnessTests {
    @Test func theCardsNumbersAreReadButNeverItsNotes() throws {
        var root = try JSONSerialization.jsonObject(with: Fixture.exportData) as! [String: Any]
        var entries = root["entries"] as! [[String: Any]]
        for i in entries.indices where "\(entries[i]["id"]!)" == "901" {
            entries[i]["metadata"] = ["_widgetType": "wellness-checkin",
                                      "_customFields": ["date": Fixture.today, "moodScore": 4, "sleepHours": 7.5, "waterGlasses": 3,
                                                        "stress": 2, "eating": "just_right", "notes": "CANARY-WELLNESS-6RR"]]
        }
        root["entries"] = entries
        let r = try ExportParser.parse(try JSONSerialization.data(withJSONObject: root), now: Fixture.now)
        let w = try #require(r.snapshot.wellness.first { $0.date == Fixture.today })
        #expect(w.entryID == "901" && w.mood == 4 && w.water == 3)
        #expect(w.line.contains("mood Good") && w.line.contains("slept 7.5h") && w.line.contains("water 3 of 8") && w.line.contains("stress Low"))
        let saved = String(data: try JSONEncoder().encode(r.snapshot), encoding: .utf8)!
        #expect(!saved.contains("CANARY-WELLNESS-6RR"))
        #expect(!r.journal.contains { $0.text.contains("CANARY-WELLNESS-6RR") })
    }
}
