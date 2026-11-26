import Foundation

/// What one device sends the other (plan, section 12). Never: the API key,
/// the pairing key, an export file, journal text, money amounts, or the
/// conversation in progress — none of those are in these types.
public struct SyncPayload: Codable, Equatable, Sendable {
    public var deviceName: String
    public var snapshot: ChroniclesSnapshot?
    public var journal: [JournalRecord]
    public var aboutYou: AboutYouStore
    public var conversations: [ConversationSummary]
    public var conversationTombstones: [Tombstone]
    public var letters: [Letter]
    public var letterTombstones: [Tombstone]
    /// Settings as one JSON blob with its own timestamp; the newer side wins.
    public var settings: JSONValue
    public var settingsUpdatedAt: Date

    public init(deviceName: String, snapshot: ChroniclesSnapshot?, journal: [JournalRecord], aboutYou: AboutYouStore,
                conversations: [ConversationSummary], conversationTombstones: [Tombstone], letters: [Letter],
                letterTombstones: [Tombstone], settings: JSONValue, settingsUpdatedAt: Date) {
        self.deviceName = deviceName; self.snapshot = snapshot; self.journal = journal; self.aboutYou = aboutYou
        self.conversations = conversations; self.conversationTombstones = conversationTombstones
        self.letters = letters; self.letterTombstones = letterTombstones
        self.settings = settings; self.settingsUpdatedAt = settingsUpdatedAt
    }
}

public struct SyncReceipt: Equatable, Sendable {
    public var chroniclesFrom: Date?
    public var newFacts = 0
    public var newConversations = 0
    public var newLetters = 0

    public var text: String {
        var bits: [String] = []
        if let d = chroniclesFrom {
            let f = DateFormatter(); f.dateFormat = "d MMM"; f.locale = Locale(identifier: "en_GB")
            bits.append("Chronicles data from \(f.string(from: d))")
        }
        if newFacts > 0 { bits.append("\(newFacts) new \(newFacts == 1 ? "fact" : "facts")") }
        if newConversations > 0 { bits.append("\(newConversations) conversation \(newConversations == 1 ? "summary" : "summaries")") }
        if newLetters > 0 { bits.append("\(newLetters) \(newLetters == 1 ? "letter" : "letters")") }
        return bits.isEmpty ? "Synced: already up to date." : "Synced: " + bits.joined(separator: " · ") + "."
    }
}

public enum SyncMerge {
    /// Merges `theirs` into `mine`. Symmetric: both devices end up with the same result.
    public static func merge(_ mine: SyncPayload, _ theirs: SyncPayload) -> (SyncPayload, SyncReceipt) {
        var out = mine
        var receipt = SyncReceipt()

        // Chronicles: the newer export wins as a whole; journal records follow it.
        if let t = theirs.snapshot, (mine.snapshot?.exportedAt ?? .distantPast) < t.exportedAt {
            out.snapshot = t
            out.journal = theirs.journal
            receipt.chroniclesFrom = t.exportedAt
        }

        // About You.
        var a = mine.aboutYou
        let tombs = Set(mine.aboutYou.tombstones.map(\.id)).union(theirs.aboutYou.tombstones.map(\.id))
        a.tombstones = unionTombstones(mine.aboutYou.tombstones, theirs.aboutYou.tombstones)
        var byID = Dictionary(mine.aboutYou.facts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for f in theirs.aboutYou.facts {
            if let m = byID[f.id] { byID[f.id] = winner(m, f) }
            else { byID[f.id] = f; receipt.newFacts += 1 }
        }
        a.facts = byID.values.filter { !tombs.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        receipt.newFacts = a.facts.filter { f in !mine.aboutYou.facts.contains { $0.id == f.id } }.count
        var markers = Set(mine.aboutYou.dontLearn.map(\.marker))
        a.dontLearn = mine.aboutYou.dontLearn + theirs.aboutYou.dontLearn.filter { markers.insert($0.marker).inserted }
        out.aboutYou = a

        // Conversation summaries and letters: latest change wins, deletions stick.
        let (convs, newConvs, convTombs) = mergeRecords(mine.conversations, theirs.conversations,
                                                        mine.conversationTombstones, theirs.conversationTombstones,
                                                        id: \.id, updated: \.updatedAt)
        out.conversations = convs.sorted { ($0.day, $0.updatedAt) < ($1.day, $1.updatedAt) }
        out.conversationTombstones = convTombs
        receipt.newConversations = newConvs

        let (letters, newLetters, letterTombs) = mergeRecords(mine.letters, theirs.letters, mine.letterTombstones,
                                                              theirs.letterTombstones, id: \.id, updated: \.updatedAt)
        out.letters = letters.sorted { $0.date < $1.date }
        out.letterTombstones = letterTombs
        receipt.newLetters = newLetters

        if theirs.settingsUpdatedAt > mine.settingsUpdatedAt {
            out.settings = theirs.settings
            out.settingsUpdatedAt = theirs.settingsUpdatedAt
        }
        return (out, receipt)
    }

    /// The person's own edits beat Smith's suggestions; otherwise the latest change wins.
    static func winner(_ a: Fact, _ b: Fact) -> Fact {
        let rank = { (f: Fact) in f.source == .editedByYou || f.source == .addedByYou ? 1 : 0 }
        if rank(a) != rank(b) { return rank(a) > rank(b) ? a : b }
        var w = a.updatedAt >= b.updatedAt ? a : b
        w.lastSeen = max(a.lastSeen, b.lastSeen)
        w.confirmed = a.confirmed || b.confirmed
        return w
    }

    static func unionTombstones(_ a: [Tombstone], _ b: [Tombstone]) -> [Tombstone] {
        var seen = Set<UUID>()
        return (a + b).filter { seen.insert($0.id).inserted }
    }

    static func mergeRecords<T>(_ mine: [T], _ theirs: [T], _ myTombs: [Tombstone], _ theirTombs: [Tombstone],
                                id: KeyPath<T, UUID>, updated: KeyPath<T, Date>) -> ([T], Int, [Tombstone]) {
        let tombs = unionTombstones(myTombs, theirTombs)
        let dead = Set(tombs.map(\.id))
        var byID = Dictionary(mine.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { a, _ in a })
        var added = 0
        for r in theirs {
            let k = r[keyPath: id]
            if let m = byID[k] {
                if r[keyPath: updated] > m[keyPath: updated] { byID[k] = r }
            } else if !dead.contains(k) {
                byID[k] = r; added += 1
            }
        }
        return (byID.values.filter { !dead.contains($0[keyPath: id]) }, added, tombs)
    }
}
