import Foundation

/// An entry's own tags (Chronicles' utils/entryTags.ts): custom tags on text
/// entries — the journal and topics of their own, never tasks or the other
/// built-in kinds. Kept in the entry's encrypted fields as `tags`, a list of names.
public enum EntryTags {
    public static let maxLength = 40
    public static let perEntry = 20

    /// A tag as typed, made tidy: one line, single spaces, no control characters, at most 40 characters.
    public static func clean(_ raw: String) -> String {
        let oneLine = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(oneLine.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maxLength))
    }

    public static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The tags in an entry's fields: names only, each once, in the order given, at most 20.
    public static func of(_ fields: JSONValue?) -> [String] {
        var out: [String] = []
        for t in fields?["tags"]?.array ?? [] {
            guard let s = t.string else { continue }
            let tag = clean(s)
            if !tag.isEmpty, !out.contains(where: { same($0, tag) }) { out.append(tag) }
            if out.count >= perEntry { break }
        }
        return out
    }

    /// `tags` with `tag` added at the end (unchanged when it's blank, already there, or the list is full).
    public static func adding(_ tag: String, to tags: [String]) -> [String] {
        let t = clean(tag)
        guard !t.isEmpty, !tags.contains(where: { same($0, t) }), tags.count < perEntry else { return tags }
        return tags + [t]
    }

    public static func removing(_ tag: String, from tags: [String]) -> [String] { tags.filter { !same($0, tag) } }
}

/// A tagged text entry as Smith may show it: when it was written, its topic and its tags. Never its text.
public struct TaggedEntry: Equatable, Sendable {
    public var id: String
    public var day: String
    public var topic: String
    public var tags: [String]

    /// The tagged entries Smith may talk about. Nothing while the journal is kept from
    /// Smith (sharing off); never an entry in a "never mention" topic.
    public static func visible(_ records: [JournalRecord], mode: JournalShareMode, neverMention: Set<String>,
                               topics: [String: String]) -> [TaggedEntry] {
        guard mode != .off else { return [] }
        return records.compactMap { r in
            guard neverMention.isDisjoint(with: r.topicIDs) else { return nil }
            let topic = r.topicIDs.first.flatMap { topics[$0] } ?? "Journal"
            return TaggedEntry(id: r.id, day: r.day, topic: topic, tags: r.tags ?? [])
        }.sorted { ($0.day, $0.id) > ($1.day, $1.id) }
    }

    /// Every tag in use, most used first, then A–Z (Chronicles' tagsInUse).
    public static func inUse(_ entries: [TaggedEntry]) -> [(tag: String, count: Int)] {
        var count: [String: (name: String, n: Int)] = [:]
        for e in entries {
            for t in e.tags {
                let k = t.lowercased()
                count[k] = (count[k]?.name ?? t, (count[k]?.n ?? 0) + 1)
            }
        }
        return count.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name.localizedCompare($1.name) == .orderedAscending }
            .map { ($0.name, $0.n) }
    }
}
