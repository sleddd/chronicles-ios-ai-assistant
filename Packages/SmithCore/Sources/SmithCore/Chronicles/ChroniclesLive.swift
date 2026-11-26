import Foundation
import CryptoKit

// Smith as a Chronicles app: sign in with the Chronicles password, read and
// write through the public API with an assistant session, encrypting and
// decrypting on the device. The master key and the session token live only in
// memory (`ChroniclesSession`); nothing here writes either to disk.

// MARK: - Transport

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: JSONValue
    public init(status: Int, body: JSONValue) { self.status = status; self.body = body }
}

/// One HTTP call. The real one uses URLSession; tests use a fake Chronicles.
public protocol ChroniclesTransport: Sendable {
    func send(method: String, path: String, body: JSONValue?, token: String?) async throws -> HTTPResponse
}

public struct URLSessionChroniclesTransport: ChroniclesTransport {
    public let baseURL: URL
    let session: URLSession
    public init(baseURL: URL, session: URLSession = .shared) { self.baseURL = baseURL; self.session = session }

    public func send(method: String, path: String, body: JSONValue?, token: String?) async throws -> HTTPResponse {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw ChroniclesError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Smith/1.0", forHTTPHeaderField: "user-agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body { req.httpBody = try body.encoded(sortedKeys: false) }
        // Never keep or send cookies: an assistant session is a Bearer token only
        req.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.isEmpty ? JSONValue.null : ((try? JSONValue.parse(data)) ?? .string(String(data: data, encoding: .utf8) ?? ""))
        if status == 429, let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after"),
           let secs = Double(retry), secs <= 5 {
            try await Task.sleep(for: .seconds(secs))
            return try await send(method: method, path: path, body: body, token: token)
        }
        return HTTPResponse(status: status, body: json)
    }
}

public enum ChroniclesError: LocalizedError, Equatable {
    case badURL
    case signInFailed(String)
    case locked
    case refused(String)
    case server(Int, String)
    case notFound(String)
    case missingTopic(String)
    /// 429: the day's entries are used up, or Chronicles' list of changes the app made is full.
    case limit(String)
    /// 409: Chronicles is moving the journal to a new key; try again once it's done.
    case rekeying(String)
    /// The journal is under a new key now: the key in memory no longer opens it.
    case keyChanged

    public var errorDescription: String? {
        switch self {
        case .badURL: "The Chronicles address in Settings isn’t valid."
        case .signInFailed(let m): m
        case .locked: "Smith is locked. Unlock with your Chronicles password."
        case .refused(let m): m
        case .server(let s, let m): "Chronicles answered \(s): \(m)"
        case .notFound(let m): m
        case .missingTopic(let t): "Your Chronicles has no \(t) topic yet. Open Chronicles once to create it."
        case .limit(let m): m
        case .rekeying(let m): m
        case .keyChanged: "Chronicles moved your journal to a new key. Unlock with your password to carry on."
        }
    }
}

// MARK: - Session (memory only)

/// An unlocked connection: the assistant session token and the master key. Memory only.
public struct ChroniclesSession: Sendable {
    public let email: String
    public let token: String
    let keys: [SymmetricKey]
    public init(email: String, token: String, keys: [SymmetricKey]) { self.email = email; self.token = token; self.keys = keys }
    var key: SymmetricKey { keys[0] }
    /// The raw key, only to seal it to the Secure Enclave for a quick unlock.
    public var keyData: Data { keys[0].withUnsafeBytes { Data($0) } }

    /// Is this session still good? (Revoked, idle, expired, or the app switched off in Chronicles → false.)
    public func isAlive(_ client: ChroniclesClient) async -> Bool {
        (try? await client.call("GET", "/api/auth/me", nil, self)) != nil
    }
}

public enum SignInResult: Sendable {
    case unlocked(ChroniclesSession)
    /// Two-factor: ask for the code, then call `finishTwoFactor`.
    case needsCode(pendingToken: String)
}

public struct ChroniclesClient: Sendable {
    public let transport: ChroniclesTransport
    public init(transport: ChroniclesTransport) { self.transport = transport }

    // MARK: sign-in

    public func signIn(email: String, password: String) async throws -> SignInResult {
        let secret = try ChroniclesCrypto.authSecret(password: password, email: email)
        var r = try await transport.send(method: "POST", path: "/api/auth/login",
                                         body: ["email": .string(email), "authSecret": .string(secret), "client": "smith"], token: nil)
        // Older accounts: the sign-in secret was made from the password as typed
        if r.status == 401, let legacy = ChroniclesCrypto.legacyPasswordForm(password) {
            let old = try ChroniclesCrypto.authSecret(password: legacy, email: email, asTyped: true)
            r = try await transport.send(method: "POST", path: "/api/auth/login",
                                         body: ["email": .string(email), "authSecret": .string(old), "client": "smith"], token: nil)
        }
        if r.status == 200, r.body["requires2FA"]?.bool == true, let pending = r.body["pendingToken"]?.string {
            return .needsCode(pendingToken: pending)
        }
        return .unlocked(try session(from: r, email: email, password: password))
    }

    public func finishTwoFactor(pendingToken: String, code: String, email: String, password: String) async throws -> ChroniclesSession {
        let r = try await transport.send(method: "POST", path: "/api/auth/login/2fa",
                                         body: ["pendingToken": .string(pendingToken), "code": .string(code), "client": "smith"], token: nil)
        return try session(from: r, email: email, password: password)
    }

    func session(from r: HTTPResponse, email: String, password: String) throws -> ChroniclesSession {
        guard r.status == 200 else {
            let msg = r.body["error"]?.string ?? "Sign-in failed."
            throw ChroniclesError.signInFailed(r.status == 401 ? "That email or password didn’t work." : msg)
        }
        guard let token = r.body["token"]?.string, let enc = r.body["encryption"],
              let salt = enc["kekSalt"]?.string, let wrapped = enc["encryptedMasterKey"]?.string,
              let iv = enc["kekWrapIv"]?.string, let iterations = enc["kekIterations"]?.int else {
            throw ChroniclesError.signInFailed("Chronicles didn’t send what Smith needs. Is the Chronicles AI app switched on?")
        }
        let mk = try ChroniclesCrypto.unwrapMasterKey(password: password, salt: salt, iv: iv, wrapped: wrapped, iterations: iterations)
        return ChroniclesSession(email: email, token: token, keys: [mk])
    }

    public func signOut(_ s: ChroniclesSession) async {
        _ = try? await transport.send(method: "POST", path: "/api/auth/logout", body: [:], token: s.token)
    }

    // MARK: calls

    @discardableResult
    func call(_ method: String, _ path: String, _ body: JSONValue? = nil, _ s: ChroniclesSession, allow: Set<Int> = [200, 201]) async throws -> HTTPResponse {
        let r = try await transport.send(method: method, path: path, body: body, token: s.token)
        if r.status == 401 { throw ChroniclesError.locked }
        if r.status == 403 { throw ChroniclesError.refused(r.body["error"]?.string ?? "Not allowed.") }
        // Not worth retrying soon: the day's limit, or the change list needs clearing in Chronicles
        if r.status == 429 { throw ChroniclesError.limit(r.body["error"]?.string ?? "Chronicles asked the app to slow down.") }
        // Moving to a new key: everything waits until it's done
        if r.status == 409, let m = r.body["error"]?.string, m.localizedCaseInsensitiveContains("new key") { throw ChroniclesError.rekeying(m) }
        if r.status == 404, !allow.contains(404) { throw ChroniclesError.notFound(r.body["error"]?.string ?? "Not found.") }
        guard allow.contains(r.status) else { throw ChroniclesError.server(r.status, r.body["error"]?.string ?? "") }
        return r
    }
}

// MARK: - Reading

/// A decrypted entry, held in memory while unlocked.
public struct LiveEntry: Sendable, Equatable {
    public var id: Int
    public var content: String
    public var metadata: JSONValue
    public var createdAt: String
    public var updatedAt: String
}

extension ChroniclesClient {
    func decryptEntry(_ row: JSONValue, _ s: ChroniclesSession) -> LiveEntry? {
        guard let id = row["id"]?.int, let ce = row["contentEncrypted"]?.string, let ci = row["contentIv"]?.string,
              let me = row["metadataEncrypted"]?.string, let mi = row["metadataIv"]?.string else { return nil }
        let post = EncryptedPost(contentEncrypted: ce, contentIv: ci, metadataEncrypted: me, metadataIv: mi)
        guard let (content, metadata) = try? ChroniclesCrypto.decryptPost(post, id: id, keys: s.keys) else { return nil }
        return LiveEntry(id: id, content: content, metadata: metadata,
                         createdAt: metadata["_createdAt"]?.string ?? row["createdAt"]?.string ?? "",
                         updatedAt: row["updatedAt"]?.string ?? "")
    }

    /// Rows that should open but don't mean the key changed (a re-key finished):
    /// never let them silently drop out of Smith's picture of the day.
    func openAll(_ rows: [JSONValue], _ s: ChroniclesSession) throws -> [LiveEntry] {
        var out: [LiveEntry] = []
        var failed = 0
        for row in rows {
            if let e = decryptEntry(row, s) { out.append(e) } else if row["contentEncrypted"]?.string != nil { failed += 1 }
        }
        if failed > 0, failed * 4 >= rows.count || out.isEmpty { throw ChroniclesError.keyChanged }
        return out
    }

    public func allEntries(_ s: ChroniclesSession) async throws -> (entries: [LiveEntry], cursor: String?) {
        let cursor = try await call("GET", "/api/entries/cursor", nil, s).body["cursor"]?.string
        var out: [LiveEntry] = []
        var offset = 0
        while true {
            let r = try await call("GET", "/api/entries?v=2&limit=2000&offset=\(offset)", nil, s)
            let rows = r.body["entries"]?.array ?? []
            out += try openAll(rows, s)
            offset += rows.count
            if r.body["more"]?.bool != true || rows.isEmpty { break }
        }
        return (out, cursor)
    }

    public enum Changes: Sendable { case reset, changed(entries: [LiveEntry], deleted: [Int], cursor: String) }

    public func changes(since cursor: String, _ s: ChroniclesSession) async throws -> Changes {
        let r = try await call("GET", "/api/entries/changes?since=\(cursor)", nil, s)
        if r.body["reset"]?.bool == true { return .reset }
        return .changed(entries: try openAll(r.body["entries"]?.array ?? [], s),
                        deleted: (r.body["deleted"]?.array ?? []).compactMap(\.int),
                        cursor: r.body["cursor"]?.string ?? cursor)
    }

    /// One entry, or nil when it's gone or hidden from AI (the server answers 404 for both).
    public func entry(id: Int, _ s: ChroniclesSession) async throws -> LiveEntry? {
        let r = try await call("GET", "/api/entries/\(id)", nil, s, allow: [200, 404])
        return r.status == 200 ? decryptEntry(r.body, s) : nil
    }

    public func visibleIDs(_ s: ChroniclesSession) async throws -> Set<Int> {
        Set((try await call("GET", "/api/entries/visible-ids", nil, s).body["ids"]?.array ?? []).compactMap(\.int))
    }

    public func topics(_ s: ChroniclesSession) async throws -> [(id: Int, name: String)] {
        let rows = try await call("GET", "/api/topics", nil, s).body.array ?? []
        // Sealed topics that no longer open: the key changed
        let sealed = rows.filter { $0["payload"]?.string != nil }
        let opened = sealed.filter { row in
            guard let id = row["id"]?.int, let p = row["payload"]?.string, let iv = row["iv"]?.string else { return false }
            return (try? ChroniclesCrypto.openRecord(kind: ChroniclesCrypto.RecordKind.topic, id: ChroniclesCrypto.topicRecordID(id), payload: p, iv: iv, keys: s.keys)) != nil
        }
        if !sealed.isEmpty && opened.isEmpty { throw ChroniclesError.keyChanged }
        return rows.compactMap { row in
            guard let id = row["id"]?.int else { return nil }
            if let p = row["payload"]?.string, let iv = row["iv"]?.string,
               let rec = try? ChroniclesCrypto.openRecord(kind: ChroniclesCrypto.RecordKind.topic, id: ChroniclesCrypto.topicRecordID(id), payload: p, iv: iv, keys: s.keys) {
                return (id, rec["name"]?.string ?? "")
            }
            return row["name"]?.string.map { (id, $0) }
        }
    }

    /// The settings an assistant session can read, opened. Sealed ones are decrypted; plain ones passed through.
    public func settings(_ s: ChroniclesSession) async throws -> [String: JSONValue] {
        let rows = try await call("GET", "/api/settings", nil, s).body.array ?? []
        var out: [String: JSONValue] = [:]
        for row in rows {
            guard let key = row["key"]?.string, let value = row["value"] else { continue }
            if value["ciphertext"] != nil, value["iv"] != nil {
                if let opened = try? ChroniclesCrypto.openSetting(key: key, sealed: value, keys: s.keys) { out[key] = opened }
            } else if key != Self.sealedPrivacyKey {
                // The sealed "Don't share with AI" choices are never taken readable:
                // a readable value there would be the server's own, passed off as
                // the copy only the account's key can write
                out[key] = value
            }
        }
        return out
    }

    /// The "Don't share with AI" choices, sealed with the account's key (what Smith believes).
    static let sealedPrivacyKey = "aiPrivacySealed"
    /// The server's readable copy of them (it can only add to what is hidden).
    static let readablePrivacyKey = "aiPrivacy"


    /// Dose records (last ~60 days are kept later), or [] when doses are kept from AI.
    public func doses(_ s: ChroniclesSession) async throws -> [JSONValue] {
        let r: HTTPResponse
        do { r = try await call("GET", "/api/doses/all", nil, s) } catch ChroniclesError.refused { return [] }
        return (r.body["records"]?.array ?? []).compactMap { row in
            guard let id = row["id"]?.string, let date = row["date"]?.string, let p = row["payload"]?.string, let iv = row["iv"]?.string,
                  let rid = try? ChroniclesCrypto.doseRecordID(uuid: id, date: date),
                  var rec = try? ChroniclesCrypto.openRecord(kind: ChroniclesCrypto.RecordKind.dose, id: rid, payload: p, iv: iv, keys: s.keys).object
            else { return nil }
            rec["id"] = .string(id); rec["date"] = .string(date)
            return .object(rec)
        }
    }

    /// Bills (decrypted, with their ids), or [] when bills are kept from AI.
    public func bills(_ s: ChroniclesSession) async throws -> [JSONValue] {
        var out: [JSONValue] = []
        var offset = 0
        while true {
            let r: HTTPResponse
            do { r = try await call("GET", "/api/finance/bills?v=2&offset=\(offset)", nil, s) } catch ChroniclesError.refused { return [] }
            let rows = r.body["records"]?.array ?? []
            for row in rows {
                guard let id = row["id"]?.string, let p = row["payload"]?.string, let iv = row["iv"]?.string,
                      var rec = try? ChroniclesCrypto.openRecord(kind: "bills", id: id, payload: p, iv: iv, keys: s.keys).object else { continue }
                rec["id"] = .string(id)
                out.append(.object(rec))
            }
            offset += rows.count
            if r.body["more"]?.bool != true || rows.isEmpty { break }
        }
        return out
    }
}

/// A place from Chronicles' dashboard (Open-Meteo geocoding, like Chronicles).
public struct HomePlace: Codable, Equatable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var timezone: String?
    public init(name: String, latitude: Double, longitude: Double, timezone: String?) {
        self.name = name; self.latitude = latitude; self.longitude = longitude; self.timezone = timezone
    }
    init?(_ v: JSONValue?) {
        guard let v, let name = v["name"]?.string, let lat = v["latitude"]?.double, let lon = v["longitude"]?.double,
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        self.init(name: name, latitude: lat, longitude: lon, timezone: v["timezone"]?.string)
    }
}

// MARK: - Live sync

/// Keeps Smith's snapshot current from the live account while unlocked.
/// Plan data stays in memory; journal entries are summarized as they arrive
/// and their text is dropped (the same privacy path as Export All).
public actor ChroniclesLiveSync {
    public let client: ChroniclesClient
    var session: ChroniclesSession
    var entries: [Int: LiveEntry] = [:]
    var cursor: String?
    var topicNames: [Int: String] = [:]

    public init(client: ChroniclesClient, session: ChroniclesSession) { self.client = client; self.session = session }

    public struct Result: Sendable {
        public var snapshot: ChroniclesSnapshot
        /// Journal entries new or changed since the last refresh (memory only: summarize, then let go).
        public var journal: [TransientJournalEntry]
        /// Journal entry ids that no longer exist or are now hidden from AI.
        public var removedJournalIDs: Set<String>
        /// Everything was loaded: journal records not in `journal` are gone.
        public var isFullLoad: Bool
        /// Topics the account keeps from AI (Settings → In-App AI).
        public var hiddenTopicIDs: Set<Int>
        /// The account's own Anthropic key (Chronicles' In-App AI), when it uses
        /// Anthropic and has AI on. Memory only; nothing else from that setting is kept.
        public var anthropicKey: String?
        /// The dashboard's first place (Chronicles' home city), for the weather.
        public var homePlace: HomePlace?
        /// Smith's own records (memories, letters, summaries) as they are in Chronicles.
        public var smithRecords: [RemoteSmithRecord] = []
        /// Smith's topics that exist, by name.
        public var smithTopicIDs: [String: Int] = [:]
    }

    var journalIDs: Set<Int> = []

    /// Past this many entries shared with AI again at once, everything is loaded afresh instead of one by one.
    static let refetchLimit = 40

    /// What the account keeps from AI, read from an entry once it is decrypted:
    /// its own "Hide from AI" switch, or a topic on the "Don't share with AI"
    /// list. The server already leaves these out; this is Smith's own check, so
    /// an entry the server sent by mistake still never reaches the snapshot,
    /// the summaries or the model.
    static func keptFromAI(_ e: LiveEntry, hiddenTopics: Set<Int>) -> Bool {
        if e.metadata["_aiHidden"]?.bool == true { return true }
        guard let topic = e.metadata["_taxonomyId"]?.int ?? e.metadata["_taxonomyId"]?.string.flatMap(Int.init) else { return false }
        return hiddenTopics.contains(topic)
    }

    /// The topics and features the account keeps from AI, from both stored copies.
    /// The sealed copy (only the account's key writes it) is what Smith believes;
    /// the server's readable copy can only add to it. So a server that trimmed its
    /// own copy still can't have Smith hold, or send to a model, what was hidden.
    static func keptFromAI(_ settings: [String: JSONValue]) -> (topics: Set<Int>, features: Set<String>) {
        var topics = Set<Int>(), features = Set<String>()
        for key in [ChroniclesClient.sealedPrivacyKey, ChroniclesClient.readablePrivacyKey] {
            topics.formUnion((settings[key]?["hiddenTopicIds"]?.array ?? []).compactMap(\.int))
            features.formUnion((settings[key]?["hiddenFeatures"]?.array ?? []).compactMap(\.string))
        }
        return (topics, features)
    }

    /// First load or after a reset: everything. Later: just what changed.
    public func refresh(now: Date = Date()) async throws -> Result {
        let topics = try await client.topics(session)
        topicNames = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0.name) })
        // First, so every entry taken below is checked against the account's choices
        var settings = try await client.settings(session)
        let kept = Self.keptFromAI(settings)
        let hiddenTopics = kept.topics
        // A feature kept from AI: its records are never asked for or held, whatever the server would send
        if kept.features.contains("habits") { settings["habitLog"] = nil }
        if kept.features.contains("vision") { settings["goalCategories"] = nil }
        var changedJournal: [LiveEntry] = []
        var removed = Set<Int>()

        func isJournal(_ e: LiveEntry) -> Bool {
            let w = e.metadata["_widgetType"]?.string
            if w == "saved-chat" || w == "wellness-checkin" { return false }
            let t = e.metadata["_taxonomyId"]?.int
            return ExportParser.kind(of: t.flatMap { topicNames[$0] }) == nil
        }
        func take(_ e: LiveEntry) {
            // Kept from AI: never held, whatever the server sent
            if Self.keptFromAI(e, hiddenTopics: hiddenTopics) {
                entries[e.id] = nil
                if journalIDs.remove(e.id) != nil { removed.insert(e.id) }
                return
            }
            if isJournal(e) {
                journalIDs.insert(e.id)
                entries[e.id] = nil
                changedJournal.append(e)
            } else {
                journalIDs.remove(e.id)
                entries[e.id] = e
            }
        }

        var full = cursor == nil
        if let c = cursor {
            switch try await client.changes(since: c, session) {
            case .reset: full = true
            case .changed(let changed, let deleted, let next):
                changed.forEach(take)
                for id in deleted { entries[id] = nil; if journalIDs.remove(id) != nil { removed.insert(id) } }
                cursor = next
                // Hidden from AI since: drop it (the change feed doesn't say so)
                let visible = try await client.visibleIDs(session)
                for id in Set(entries.keys).subtracting(visible) { entries[id] = nil }
                for id in journalIDs.subtracting(visible) { journalIDs.remove(id); removed.insert(id) }
                // Shared with AI again since: the entry itself didn't change, so the
                // change feed never sends it. Whatever is visible and not held is fetched
                let missing = visible.subtracting(entries.keys).subtracting(journalIDs)
                if missing.count > Self.refetchLimit {
                    full = true
                } else {
                    for id in missing.sorted() {
                        if let e = try await client.entry(id: id, session) { take(e) }
                    }
                }
            }
        }
        // A topic put on the list since: what is held from it goes (the server's
        // list says so too; this doesn't wait for it)
        for (id, e) in entries where Self.keptFromAI(e, hiddenTopics: hiddenTopics) { entries[id] = nil }
        if full {
            let (all, c) = try await client.allEntries(session)
            let before = journalIDs
            entries = [:]; journalIDs = []
            all.forEach(take)
            removed = before.subtracting(journalIDs)
            cursor = c
        }

        let doses = kept.features.contains("doses") ? [] : try await client.doses(session)
        let bills = kept.features.contains("bills") ? [] : try await client.bills(session)

        // The same document shape as Export All, so the same privacy filters apply
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entryJSON: [JSONValue] = (Array(entries.values) + changedJournal).map { e in
            ["id": .number(Double(e.id)), "content": .string(e.content), "metadata": e.metadata,
             "createdAt": .string(e.createdAt), "updatedAt": .string(e.updatedAt)]
        }
        let doc: JSONValue = [
            "app": "chronicles", "kind": "full-export", "version": 1,
            "exportedAt": .string(iso.string(from: now)),
            "entries": .array(entryJSON),
            "topics": .array(topics.map { ["id": .number(Double($0.id)), "name": .string($0.name)] }),
            "medicationDoseLogs": .array(doses.map { d in
                ["id": d["id"] ?? .null, "date": d["date"] ?? .null, "medicationPostId": d["medicationPostId"] ?? .null,
                 "scheduledTime": d["scheduledTime"] ?? .null, "status": d["status"] ?? .null, "asNeeded": d["asNeeded"] ?? false]
            }),
            "settings": .object(settings),
            "finance": ["bills": .array(bills)],
        ]
        let parsed = try ExportParser.parse(try doc.encoded(sortedKeys: false), now: now)
        var result = Result(snapshot: parsed.snapshot, journal: parsed.journal, removedJournalIDs: Set(removed.map(String.init)),
                            isFullLoad: full, hiddenTopicIDs: hiddenTopics, anthropicKey: Self.anthropicKey(settings["aiConfig"]),
                            homePlace: HomePlace(settings["dashboardConfig"]?["places"]?.array?.first))
        // Smith's own topics and what's in them (newest first)
        for (id, name) in topicNames { if let t = SmithTopics.which(name) { result.smithTopicIDs[t] = id } }
        let smithTopic = Dictionary(uniqueKeysWithValues: result.smithTopicIDs.map { ($0.value, $0.key) })
        result.smithRecords = entries.values.compactMap { e -> (Date, RemoteSmithRecord)? in
            guard let t = e.metadata["_taxonomyId"]?.int, let topic = smithTopic[t] else { return nil }
            let updated = SmithRecord.date(.string(e.updatedAt)) ?? SmithRecord.date(.string(e.createdAt)) ?? .distantPast
            guard let rec = SmithRecord.from(content: e.content, metadata: e.metadata, topic: topic, entryID: e.id, updatedAt: updated) else { return nil }
            let owned = e.metadata["_customFields"]?["smithKind"]?.string != nil
            return (updated, RemoteSmithRecord(entryID: e.id, record: rec, owned: owned))
        }.sorted { $0.0 > $1.0 }.map(\.1)
        return result
    }

    /// Only the Anthropic key, and only when AI is on there; other providers aren't used by Smith.
    static func anthropicKey(_ cfg: JSONValue?) -> String? {
        // A rollback-guarded setting: an object carries `_rev` alongside its fields
        guard let cfg, cfg["enabled"]?.bool == true, (cfg["provider"]?.string ?? "anthropic") == "anthropic",
              let key = cfg["apiKey"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// The decrypted entry, for writes (always fetched fresh).
    public func entry(_ id: Int) -> LiveEntry? { entries[id] }
    public func topicID(named names: [String]) -> Int? {
        let wanted = Set(names.map { $0.lowercased() })
        return topicNames.first { wanted.contains($0.value.trimmingCharacters(in: .whitespaces).lowercased()) }?.key
    }
    public func currentSession() -> ChroniclesSession { session }

    /// A medication's name and fields, for its per-dose nutrients.
    public func medication(_ id: Int) -> (name: String, fields: JSONValue)? {
        guard let e = entries[id] else { return nil }
        let cf = e.metadata["_customFields"] ?? [:]
        let name = cf["medicationName"]?.string ?? ExportParser.plainText(fromHTML: e.content).split(separator: "\n").first.map(String.init) ?? "Medication"
        return (name.isEmpty ? "Medication" : name, cf)
    }

    /// Whether a Meals row is already linked to this taken dose.
    public func hasDoseLink(_ key: String) -> Bool {
        entries.values.contains { $0.metadata["_doseLink"]?.string == key }
    }
}
