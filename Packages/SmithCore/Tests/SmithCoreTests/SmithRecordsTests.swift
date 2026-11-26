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

        // Both changed → Chronicles wins; the person's own entries are never changed or deleted by Smith
        let aOther: SmithRecord = { if case .fact(var f) = a { f.text = "A3"; return .fact(f) }; return a }()
        p = SmithMerge.plan(remote: [.init(entryID: 1, record: aOther, owned: true)], local: [aEdited], base: [a.id: a.fingerprint])
        #expect(p.keep == [aOther] && p.update.isEmpty)
        p = SmithMerge.plan(remote: [.init(entryID: 4, record: a, owned: false)], local: [aEdited], base: [a.id: a.fingerprint])
        #expect(p.keep == [a] && p.update.isEmpty)
        p = SmithMerge.plan(remote: [.init(entryID: 4, record: a, owned: false)], local: [], base: [a.id: a.fingerprint])
        #expect(p.delete.isEmpty && p.keep == [a])
    }
}
