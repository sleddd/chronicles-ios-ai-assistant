import Foundation
import Observation
import CryptoKit
import LocalAuthentication
import SmithCore

/// Smith as a Chronicles app. Your Chronicles password unlocks it; the session
/// token and the master key live only in memory while it's unlocked, and
/// locking (the button, auto-lock, quitting) wipes them and ends the session.
@MainActor @Observable
final class ChroniclesConnection {
    enum State: Equatable {
        /// Never set up: Smith runs from an Export All import, if any.
        case notSetUp
        case locked
        case unlocking
        case needsCode
        case unlocked
    }

    struct Undoable: Identifiable, Equatable {
        let id = UUID()
        let summary: String
        let action: UndoAction
        let expires: Date
    }

    private(set) var state: State
    private(set) var lastError: String?
    private(set) var lastSync: Date?
    private(set) var syncing = false
    private(set) var hiddenTopicIDs: Set<Int> = []
    private(set) var undoables: [Undoable] = []
    /// Chronicles is moving the journal to a new key; sync waits and tries again.
    private(set) var rekeying = false

    private let store: SmithStore
    private var session: ChroniclesSession?
    private var sync: ChroniclesLiveSync?
    private var client: ChroniclesClient?
    private var pending: (token: String, email: String, password: String)?
    private var refreshTask: Task<Void, Never>?
    private var lastActivity = Date()

    static let defaultServer = "https://mydailychronicles.com"

    /// Memories, letters and summaries, kept in Chronicles so every device has the same.
    @ObservationIgnored private(set) var cloud: SmithCloud!

    init(store: SmithStore) {
        self.store = store
        state = store.settings.chroniclesEmail == nil ? .notSetUp : .locked
        cloud = SmithCloud(store: store,
                           writer: { [unowned self] in
                               if let session = self.session, let client = self.client { ChroniclesWriter(client: client, session: session) } else { nil }
                           },
                           account: { [unowned self] in self.isUnlocked ? self.store.settings.chroniclesEmail : nil })
    }

    var isUnlocked: Bool { state == .unlocked }
    /// Smith only works connected to Chronicles: until it's signed in and unlocked,
    /// only the connect / unlock screen shows.
    var isLocked: Bool { state != .unlocked }

    private func makeClient() throws -> ChroniclesClient {
        guard let url = URL(string: store.settings.chroniclesServer ?? Self.defaultServer), url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            throw ChroniclesError.badURL
        }
        return ChroniclesClient(transport: URLSessionChroniclesTransport(baseURL: url))
    }

    // MARK: unlock / lock

    func unlock(email: String, password: String) async {
        lastError = nil
        state = .unlocking
        do {
            let c = try makeClient()
            switch try await c.signIn(email: email, password: password) {
            case .unlocked(let s): await opened(s, client: c)
            case .needsCode(let token):
                client = c
                pending = (token, email, password)
                state = .needsCode
            }
        } catch {
            lastError = error.localizedDescription
            state = store.settings.chroniclesEmail == nil ? .notSetUp : .locked
        }
    }

    func submitCode(_ code: String) async {
        guard let p = pending, let c = client else { return }
        lastError = nil
        state = .unlocking
        do {
            let s = try await c.finishTwoFactor(pendingToken: p.token, code: code, email: p.email, password: p.password)
            pending = nil
            await opened(s, client: c)
        } catch {
            lastError = error.localizedDescription
            state = .needsCode
        }
    }

    func cancelCode() {
        pending = nil
        state = .locked
    }

    private func opened(_ s: ChroniclesSession, client c: ChroniclesClient) async {
        session = s
        client = c
        sync = ChroniclesLiveSync(client: c, session: s)
        store.updateLocalSettings { $0.chroniclesEmail = s.email }
        state = .unlocked
        if store.settings.quickUnlock { saveQuickUnlock(s) }
        noteActivity()
        await refresh()
        startRefreshLoop()
    }

    /// Wipes the key and token from memory. Without quick unlock, the session
    /// ends on the server too; with it, the session stays so Face ID / Touch ID
    /// can open it again (until it idles out, expires or is revoked).
    func lock() {
        refreshTask?.cancel(); refreshTask = nil
        let keepForQuickUnlock = store.settings.quickUnlock && Self.hasQuickUnlock
        if !keepForQuickUnlock {
            if let s = session, let c = client { Task { await c.signOut(s) } }
            Self.forgetQuickUnlock()
        }
        session = nil; sync = nil; pending = nil
        cloud.signedOut()
        undoables = []
        APIKeys.setChroniclesKey(nil)
        if state != .notSetUp { state = .locked }
    }

    /// Ends the Chronicles session completely (even with Face ID unlock on) and
    /// goes back to the password screen. The account email is remembered.
    func signOut() {
        Self.forgetQuickUnlock()
        lock()
    }

    /// Show the sign-in screen to connect for the first time.
    func beginSetup() {
        lastError = nil
        state = .locked
    }

    /// Forget the account on this device (back to Export All imports).
    func disconnect() {
        if let s = session, let c = client { Task { await c.signOut(s) } }
        Self.forgetQuickUnlock()
        lock()
        store.updateLocalSettings { $0.chroniclesEmail = nil }
        state = .notSetUp
    }

    /// A fresh start with Chronicles: signs out, forgets the account on this
    /// device and deletes the Chronicles data Smith kept. Memory and letters stay.
    func removeChroniclesData() {
        disconnect()
        store.clearChroniclesData()
        hiddenTopicIDs = []
        lastSync = nil
        lastError = nil
    }

    #if DEBUG
    /// Screenshots only: shows the app as if signed in (no session, nothing syncs).
    func debugShowAsUnlocked() { state = .unlocked }
    #endif

    func noteActivity() { lastActivity = Date() }

    /// Called every minute or so, and when the app goes to the background.
    func checkAutoLock(now: Date = Date()) {
        guard state == .unlocked else { return }
        let minutes = store.settings.autoLockMinutes
        guard minutes > 0 else { return }
        if now.timeIntervalSince(lastActivity) > Double(minutes) * 60 { lock() }
    }

    // MARK: quick unlock (Face ID / Touch ID, within one Chronicles session)

    private static let quickUnlockFile = "quick-unlock.se"
    static var hasQuickUnlock: Bool { SecureEnclaveVault.exists(quickUnlockFile) }
    static var quickUnlockAvailable: Bool { SecureEnclaveVault.isAvailable }

    /// "Touch ID", "Face ID", "Optic ID" or "your passcode".
    static var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your passcode"
        }
    }

    /// Seals the session token and key to the Secure Enclave (presence lock). Nothing else keeps them.
    private func saveQuickUnlock(_ s: ChroniclesSession) {
        let payload: JSONValue = ["email": .string(s.email), "token": .string(s.token), "key": .string(s.keyData.base64EncodedString())]
        guard let data = try? payload.encoded() else { return }
        try? SecureEnclaveVault.store(data, name: Self.quickUnlockFile, lock: .presence)
    }

    static func forgetQuickUnlock() {
        try? SecureEnclaveVault.store(nil, name: quickUnlockFile, lock: .presence)
    }

    /// Turn quick unlock on or off from Settings.
    func setQuickUnlock(_ on: Bool) {
        store.updateLocalSettings { $0.quickUnlock = on }
        if on, let s = session { saveQuickUnlock(s) } else if !on { Self.forgetQuickUnlock() }
    }

    /// Face ID / Touch ID opens the sealed copy; the session is checked with Chronicles before use.
    func quickUnlock() async {
        guard Self.hasQuickUnlock, state == .locked else { return }
        lastError = nil
        state = .unlocking
        let name = store.settings.name
        // The system prompt blocks until answered: off the main thread
        let opened = await Task.detached { () -> Data? in
            try? SecureEnclaveVault.load(name: "quick-unlock.se", lock: .presence, reason: "Unlock \(name)")
        }.value
        guard let data = opened, let v = try? JSONValue.parse(data), let email = v["email"]?.string, let token = v["token"]?.string,
              let keyText = v["key"]?.string, let keyData = Data(base64Encoded: keyText) else {
            state = .locked
            return
        }
        do {
            let c = try makeClient()
            let s = ChroniclesSession(email: email, token: token, keys: [SymmetricKey(data: keyData)])
            guard await s.isAlive(c) else {
                Self.forgetQuickUnlock()
                lastError = "That session has ended. Unlock with your password."
                state = .locked
                return
            }
            await self.opened(s, client: c)
        } catch {
            lastError = error.localizedDescription
            state = .locked
        }
    }

    // MARK: sync

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                self.checkAutoLock()
                let every: TimeInterval = self.rekeying ? 2 * 60 : 15 * 60
                if self.state == .unlocked, Date().timeIntervalSince(self.lastSync ?? .distantPast) > every { await self.refresh() }
            }
        }
    }

    /// Pulls what changed. Journal entries are summarized on the device as they
    /// arrive and their text dropped (the same path as Export All).
    // MARK: AI standing (shared with Chronicles: consent, the refusal ladder, the anonymized id)

    func aiStatus() async throws -> AIChatStatus {
        guard let s = session, let c = client else { throw ChroniclesError.locked }
        return try await c.aiStatus(s)
    }

    func confirmAIConsent() async throws -> AIChatStatus {
        guard let s = session, let c = client else { throw ChroniclesError.locked }
        return try await c.confirmAIConsent(s)
    }

    func reportAIRefusal() async throws -> AIChatStatus {
        guard let s = session, let c = client else { throw ChroniclesError.locked }
        return try await c.reportAIRefusal(s)
    }

    func refresh() async {
        guard let sync, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let r = try await sync.refresh()
            hiddenTopicIDs = r.hiddenTopicIDs
            // The account's own Anthropic key (Chronicles → In-App AI), in memory while unlocked
            APIKeys.setChroniclesKey(r.anthropicKey)
            // Chronicles' home city, for the weather (kept, so it still works while locked)
            if let home = r.homePlace, home != store.settings.chroniclesHome {
                store.updateLocalSettings { $0.chroniclesHome = home }
            }
            let existing = Dictionary(store.journal.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let updated = await JournalVaultBuilder.records(for: r.journal, existing: existing,
                                                            neverMention: store.settings.neverMentionTopics,
                                                            summarizer: OnDeviceJournalSummarizer())
            var merged = r.isFullLoad ? [:] : existing
            for rec in updated { merged[rec.id] = rec }
            for id in r.removedJournalIDs { merged[id] = nil }
            store.replaceChronicles(r.snapshot, journal: merged.values.sorted { $0.day < $1.day })
            // Memories, letters and summaries: the same on every device
            await cloud.synced(remote: r.smithRecords, topics: r.smithTopicIDs)
            lastSync = Date()
            lastError = nil
            rekeying = false
        } catch ChroniclesError.rekeying(let m) {
            // Chronicles is moving to a new key: keep what Smith has, try again in a while.
            // When it's done, the key in memory won't open the journal (caught below)
            rekeying = true
            lastError = m
        } catch ChroniclesError.keyChanged {
            // A re-key finished: the old key in memory (and any quick-unlock copy) is useless now
            rekeying = false
            Self.forgetQuickUnlock()
            lock()
            lastError = ChroniclesError.keyChanged.errorDescription
        } catch ChroniclesError.locked {
            // The session ended (revoked in Chronicles, idle, or the app switched off there)
            lastError = "Chronicles ended this session. Unlock again."
            Self.forgetQuickUnlock()
            lock()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: actions

    func actionContext(estimate: @escaping @Sendable (String, String?, String?) async -> [String: Double]?) -> ChroniclesActionContext {
        let session = self.session, client = self.client, sync = self.sync
        let store = self.store
        let hidden = hiddenTopicIDs
        var ctx = ChroniclesActionContext(
            writer: { if let session, let client { ChroniclesWriter(client: client, session: session) } else { nil } },
            snapshot: { await MainActor.run { store.snapshot } },
            topicID: { names in await sync?.topicID(named: names) },
            hiddenTopicIDs: { hidden },
            estimateNutrients: estimate,
            didWrite: { [weak self] result in
                await MainActor.run {
                    guard let self else { return }
                    if let undo = result.undo {
                        self.undoables.append(Undoable(summary: result.summary, action: undo, expires: Date().addingTimeInterval(115)))
                    }
                    Task { await self.refresh() }
                }
            })
        ctx.medication = { id in await sync?.medication(id) }
        ctx.hasDoseLink = { key in await sync?.hasDoseLink(key) ?? false }
        return ctx
    }

    func undo(_ item: Undoable) async {
        undoables.removeAll { $0.id == item.id }
        guard let session, let client, item.expires > Date() else {
            lastError = "That can’t be undone any more. You can change it in Chronicles."
            return
        }
        do {
            try await ChroniclesWriter(client: client, session: session).undo(item.action)
            await refresh()
        } catch ChroniclesError.keyChanged {
            Self.forgetQuickUnlock(); lock(); lastError = ChroniclesError.keyChanged.errorDescription
        } catch {
            lastError = "Undo didn’t work: \(error.localizedDescription)"
        }
    }

    func dropExpiredUndos(now: Date = Date()) {
        undoables.removeAll { $0.expires <= now }
    }
}
