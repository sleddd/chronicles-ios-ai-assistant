import Foundation

// Smith's own data lives in Chronicles as ordinary entries, end-to-end
// encrypted like everything else, in three topics Smith creates:
// "Smith memories" (what Smith knows, and the "don't learn" markers),
// "Smith letters", and "Smith conversations" (summaries). Every device reads and
// writes the same entries, so the Mac and the iPad always agree.
// Entries Smith made carry `smithKind` and `smithId`; ones the person adds in
// Chronicles themselves are read too (they're the person's to edit there).

public enum SmithTopics {
    public static let memories = "Smith memories"
    public static let letters = "Smith letters"
    /// What the letters topic was first called. Too ordinary a name: a "Letters" topic
    /// of the person's own would have been read as Smith's. Only entries Smith itself
    /// made there (they carry `smithKind`) are still read, and they are moved across.
    public static let legacyLetters = "Letters"

    public static func isLegacyLetters(_ name: String?) -> Bool {
        name?.trimmingCharacters(in: .whitespaces).lowercased() == legacyLetters.lowercased()
    }
    public static let conversations = "Smith conversations"
    public static let all = [memories, letters, conversations]

    /// Which of Smith's topics this is, if any.
    public static func which(_ name: String?) -> String? {
        guard let n = name?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        return all.first { $0.lowercased() == n }
    }
}

/// One of Smith's records, as kept on the device.
public enum SmithRecord: Equatable, Sendable {
    case fact(Fact)
    case dontLearn(DontLearn)
    case letter(Letter)
    case conversation(ConversationSummary)

    public var id: UUID {
        switch self {
        case .fact(let f): f.id
        case .dontLearn(let d): d.id
        case .letter(let l): l.id
        case .conversation(let c): c.id
        }
    }

    public var topic: String {
        switch self {
        case .fact, .dontLearn: SmithTopics.memories
        case .letter: SmithTopics.letters
        case .conversation: SmithTopics.conversations
        }
    }

    var kind: String {
        switch self {
        case .fact: "fact"; case .dontLearn: "dontLearn"; case .letter: "letter"; case .conversation: "conversation"
        }
    }

    /// The text that makes up the entry's content (what Chronicles shows).
    var text: String {
        switch self {
        case .fact(let f): f.text
        case .dontLearn(let d): d.marker
        case .letter(let l): l.text
        case .conversation(let c): c.text
        }
    }

    /// A stable fingerprint of everything stored, to tell what changed since the last sync.
    public var fingerprint: String {
        var fields = entryFields().mapValues { $0 }
        fields["text"] = .string(text)
        return (try? JSONValue.object(fields).encoded(sortedKeys: true)).flatMap { String(data: $0, encoding: .utf8) } ?? text
    }

    static var iso: ISO8601DateFormatter {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }
    static func date(_ v: JSONValue?) -> Date? {
        guard let s = v?.string else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Everything but the text, kept in the entry's custom fields.
    func entryFields() -> [String: JSONValue] {
        var cf: [String: JSONValue] = ["smithKind": .string(kind), "smithId": .string(id.uuidString)]
        switch self {
        case .fact(let f):
            cf["category"] = .string(f.category.rawValue)
            cf["source"] = .string(f.source.rawValue)
            cf["confirmed"] = .bool(f.confirmed)
            cf["createdAt"] = .string(Self.iso.string(from: f.createdAt))
            cf["lastSeen"] = .string(Self.iso.string(from: f.lastSeen))
        case .dontLearn(let d):
            cf["createdAt"] = .string(Self.iso.string(from: d.createdAt))
        case .letter(let l):
            cf["date"] = .string(Self.iso.string(from: l.date))
            if let m = l.yourMessage { cf["yourMessage"] = .string(m) }
            cf["favorite"] = .bool(l.isFavorite)
        case .conversation(let c):
            cf["day"] = .string(c.day)
        }
        return cf
    }

    /// The entry's content and metadata for Chronicles.
    public func entry(topicID: Int) -> (content: String, metadata: JSONValue) {
        let html = text.components(separatedBy: "\n\n")
            .map { "<p>" + ChroniclesShapes.escape($0).replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
            .joined()
        return (html, ["_taxonomyId": .number(Double(topicID)), "_customFields": .object(entryFields())])
    }

    /// HTML back to text, paragraphs kept apart by a blank line (a letter keeps its shape).
    static func text(fromHTML html: String) -> String {
        var t = html
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</(p|div|h[1-6]|li)>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads an entry from one of Smith's topics. Entries the person added in
    /// Chronicles (no smithKind) are read as a memory, letter or summary by topic.
    public static func from(content: String, metadata: JSONValue, topic: String, entryID: Int, updatedAt: Date) -> SmithRecord? {
        let cf = metadata["_customFields"] ?? [:]
        let text = Self.text(fromHTML: content)
        guard !text.isEmpty else { return nil }
        let id = cf["smithId"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID.fromEntry(entryID)
        let created = date(cf["createdAt"]) ?? updatedAt
        switch cf["smithKind"]?.string ?? (topic == SmithTopics.letters ? "letter" : topic == SmithTopics.conversations ? "conversation" : "fact") {
        case "dontLearn":
            return .dontLearn(DontLearn(id: id, marker: text, at: created))
        case "letter":
            var l = Letter(id: id, date: date(cf["date"]) ?? created, yourMessage: cf["yourMessage"]?.string, text: text,
                           favorite: cf["favorite"]?.bool ?? false)
            l.updatedAt = updatedAt
            return .letter(l)
        case "conversation":
            let day = cf["day"]?.string ?? String(Self.iso.string(from: created).prefix(10))
            return .conversation(ConversationSummary(id: id, day: day, text: text, at: updatedAt))
        default:
            var f = Fact(id: id, text: text, category: cf["category"]?.string.flatMap(Fact.Category.init(rawValue:)) ?? .aboutYou,
                         source: cf["source"]?.string.flatMap(Fact.Source.init(rawValue:)) ?? .addedByYou,
                         confirmed: cf["confirmed"]?.bool ?? true, at: created)
            f.updatedAt = updatedAt
            f.lastSeen = date(cf["lastSeen"]) ?? updatedAt
            return .fact(f)
        }
    }
}

extension UUID {
    /// A stable id for an entry the person added in Chronicles.
    static func fromEntry(_ id: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x53; bytes[1] = 0x4d  // "SM"
        withUnsafeBytes(of: Int64(id).bigEndian) { for (i, b) in $0.enumerated() { bytes[8 + i] = b } }
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// A record as it is in Chronicles.
public struct RemoteSmithRecord: Equatable, Sendable {
    public var entryID: Int
    public var record: SmithRecord
    /// Made by Smith (so Smith may edit or delete it); otherwise the person's own.
    public var owned: Bool
    /// One of Smith's letters still in the old "Letters" topic, to be moved to "Smith letters".
    public var misplaced = false
    public init(entryID: Int, record: SmithRecord, owned: Bool, misplaced: Bool = false) {
        self.entryID = entryID; self.record = record; self.owned = owned; self.misplaced = misplaced
    }
}

/// Works out, from what's in Chronicles, what's on this device, and what both
/// agreed on at the last sync, what to keep and what to send.
public enum SmithMerge {
    public struct Plan: Equatable, Sendable {
        /// The records this device should now hold.
        public var keep: [SmithRecord] = []
        /// New here: create in Chronicles.
        public var create: [SmithRecord] = []
        /// Changed here: update the entry.
        public var update: [(entryID: Int, record: SmithRecord)] = []
        /// Deleted here: delete the entry.
        public var delete: [Int] = []

        public static func == (a: Plan, b: Plan) -> Bool {
            a.keep == b.keep && a.create == b.create && a.delete == b.delete
                && a.update.map(\.entryID) == b.update.map(\.entryID) && a.update.map(\.record) == b.update.map(\.record)
        }
    }

    /// `base`: each record's fingerprint at the last sync. Chronicles wins a
    /// conflict (both changed), so nothing is ever lost silently on its side.
    /// Entries the person wrote in Chronicles themselves are treated the same as
    /// Smith's: what they change or delete in Smith is sent, not quietly put back.
    public static func plan(remote: [RemoteSmithRecord], local: [SmithRecord], base: [UUID: String]) -> Plan {
        var plan = Plan()
        let r = Dictionary(remote.map { ($0.record.id, $0) }, uniquingKeysWith: { a, _ in a })
        let l = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Keep a stable order: Chronicles' order, then what's only here
        let ids = remote.map(\.record.id) + local.map(\.id).filter { r[$0] == nil }
        var seen = Set<UUID>()
        for id in ids where seen.insert(id).inserted {
            let rem = r[id], loc = l[id], was = base[id]
            switch (rem, loc) {
            case (let rem?, let loc?):
                if loc.fingerprint == rem.record.fingerprint || loc.fingerprint == was || was == nil {
                    plan.keep.append(rem.record)                  // same, only Chronicles changed, or never agreed on
                } else if rem.record.fingerprint == was {
                    plan.keep.append(loc); plan.update.append((rem.entryID, loc))   // only this device changed
                } else {
                    plan.keep.append(rem.record)                  // both changed: Chronicles wins
                }
            case (let rem?, nil):
                if was != nil {
                    plan.delete.append(rem.entryID)               // deleted here
                } else {
                    plan.keep.append(rem.record)                  // new from elsewhere
                }
            case (nil, let loc?):
                if was == nil { plan.keep.append(loc); plan.create.append(loc) }   // new here
                // else: deleted elsewhere, so it goes here too
            case (nil, nil):
                break
            }
        }
        return plan
    }
}
