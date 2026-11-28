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
    /// Smith's changes from the last two minutes, newest last, whether or not their pill
    /// is still showing: "undo that" in the chat still works after a new answer clears the pills.
    @ObservationIgnored private var recentChanges: [Undoable] = []
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
                           account: { [unowned self] in self.isUnlocked ? self.store.settings.chroniclesEmail : nil },
                           takenTopicIDs: { [unowned self] in await self.sync?.knownTopicIDs() ?? [] })
    }

    /// Called whenever Smith locks, so whatever is under way elsewhere (a reply, speech) stops too.
    @ObservationIgnored var onLock: (() -> Void)?
    /// The writer for the session as it is right now (nil once locked).
    private var liveWriter: ChroniclesWriter? {
        if let session, let client { ChroniclesWriter(client: client, session: session) } else { nil }
    }
    /// Wellness check-ins made this session that the sync hasn't brought back yet, by day.
    @ObservationIgnored private var newWellness: [String: Int] = [:]

    /// The store was loaded after launch (it couldn't be read then): the account may be known after all.
    func storeLoaded() {
        if state == .notSetUp, store.settings.chroniclesEmail != nil { state = .locked }
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
        let sameAccount = store.settings.chroniclesPrivacyAccount == s.email
        sync = ChroniclesLiveSync(client: c, session: s, rememberedPrivacy: sameAccount ? store.settings.chroniclesPrivacy : nil,
                                  aiConfigRev: sameAccount ? store.settings.chroniclesAIConfigRev : 0)
        // What Smith saved for this account opens now, and only now
        store.openVault(s.vaultKey)
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
        newWellness = [:]; failedRefreshes = 0
        onLock?()
        cloud.signedOut()
        store.closeVault()
        undoables = []; recentChanges = []
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

    /// Called by the refresh loop while Smith is in front, when it comes forward
    /// or goes to the background, and before anything Siri asks is answered.
    func checkAutoLock(now: Date = Date()) {
        guard state == .unlocked else { return }
        let minutes = store.settings.autoLockMinutes
        guard minutes > 0 else { return }
        if now.timeIntervalSince(lastActivity) > Double(minutes) * 60 { lock() }
    }

    // MARK: quick unlock (Face ID / Touch ID, within one Chronicles session)

    private static let quickUnlockFile = "quick-unlock.se"
    static var hasQuickUnlock: Bool { SecureEnclaveVault.exists(quickUnlockFile) }
    static var quickUnlockAvailable: Bool { SecureEnclaveVault.isAvailable && SecureEnclaveVault.hasBiometry }

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
        let file = Self.quickUnlockFile
        // The fingerprint or face is asked for here, where a cancel is plainly a cancel
        // (the Secure Enclave reports every failure alike). Cancelled or not recognised:
        // the copy is kept, to try again. Only a copy that then won't open is forgotten.
        let context = LAContext()
        context.localizedFallbackTitle = ""
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock \(name)")) == true else {
            state = .locked
            return
        }
        let attempt = await Task.detached { () -> Result<Data?, Error> in
            Result { try SecureEnclaveVault.load(name: file, lock: .presence, reason: "Unlock \(name)", context: context) }
        }.value
        let opened: Data?
        switch attempt {
        case .success(let d): opened = d
        case .failure:
            opened = nil
            // A new fingerprint was enrolled, or the copy was sealed under the older rule
            Self.forgetQuickUnlock()
            lastError = "Unlock with your password this once; \(Self.biometryName) will work again after that."
        }
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
            // Changes made in Chronicles (or on the other device) arrive on their own:
            // every 20 seconds one light "anything new?" request, and a sync only when
            // there is. Doses, bills and settings aren't in that feed, so every 5 minutes anyway.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                self.checkAutoLock()
                guard self.state == .unlocked, !self.syncing, let sync = self.sync else { continue }
                // After a failure (offline, the day's limit): 1 minute, then 2, 4, up to 10
                if self.failedRefreshes > 0,
                   Date().timeIntervalSince(self.lastAttempt) < min(600, 30 * pow(2, Double(min(self.failedRefreshes, 6)))) { continue }
                let every: TimeInterval = self.rekeying ? 2 * 60 : 5 * 60
                var due = Date().timeIntervalSince(self.lastSync ?? .distantPast) > every
                if !due && !self.rekeying { due = await sync.hasChanges() }
                if due { await self.refresh() }
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

    @ObservationIgnored private var refreshAgain = false

    func refresh() async {
        guard let sync else { return }
        if syncing { refreshAgain = true; return }
        defer {
            if refreshAgain { refreshAgain = false; Task { await self.refresh() } }
        }
        syncing = true
        lastAttempt = Date()
        defer { syncing = false }
        do {
            let r = try await sync.refresh()
            // Locked (or signed in afresh) while this was under way: nothing from it is kept.
            // Otherwise the account's Anthropic key would be put back in memory after the lock.
            guard self.sync === sync, state == .unlocked else { return }
            hiddenTopicIDs = r.hiddenTopicIDs
            if let p = r.sealedPrivacy, p != store.settings.chroniclesPrivacy || store.settings.chroniclesPrivacyAccount != store.settings.chroniclesEmail {
                store.updateLocalSettings { $0.chroniclesPrivacy = p; $0.chroniclesPrivacyAccount = $0.chroniclesEmail }
            }
            if r.aiConfigRev != store.settings.chroniclesAIConfigRev {
                store.updateLocalSettings { $0.chroniclesAIConfigRev = r.aiConfigRev }
            }
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
            failedRefreshes = 0
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
            failedRefreshes += 1
        }
    }

    /// Failed syncs in a row: each makes the loop wait longer before it tries again.
    @ObservationIgnored private var failedRefreshes = 0
    @ObservationIgnored private var lastAttempt = Date.distantPast

    // MARK: actions

    /// `chips`: show an Undo pill in the chat for each change (not for the Today page's checkboxes).
    func actionContext(estimate: @escaping @Sendable (String, String?, String?) async -> [String: Double]?, chips: Bool = true) -> ChroniclesActionContext {
        let session = self.session, client = self.client, sync = self.sync
        let store = self.store
        let hidden = hiddenTopicIDs
        _ = (session, client)
        var ctx = ChroniclesActionContext(
            // Asked afresh each time: after a lock there is no writer, even for a reply already under way
            writer: { [weak self] in await MainActor.run { self?.liveWriter } },
            snapshot: { await MainActor.run { store.snapshot } },
            topicID: { names in await sync?.topicID(named: names) },
            hiddenTopicIDs: { hidden },
            estimateNutrients: estimate,
            didWrite: { [weak self] result in
                await MainActor.run {
                    guard let self else { return }
                    if chips, let undo = result.undo {
                        let item = Undoable(summary: result.summary, action: undo, expires: Date().addingTimeInterval(115))
                        self.undoables.append(item)
                        self.recentChanges.append(item)
                    }
                    Task { await self.refresh() }
                }
            })
        ctx.medication = { id in await sync?.medication(id) }
        ctx.hasDoseLink = { key in await sync?.hasDoseLink(key) ?? false }
        ctx.wellnessEntryID = { [weak self] day in
            if let id = await sync?.wellnessEntryID(day: day) { return id }
            return await MainActor.run { self?.newWellness[day] }
        }
        ctx.noteWellnessEntry = { [weak self] day, id in await MainActor.run { self?.newWellness[day] = id } }
        ctx.taggedEntries = { await MainActor.run { store.taggedEntries } }
        ctx.recentChanges = { [weak self] in
            await MainActor.run { self?.liveRecentChanges().reversed().map(\.summary) ?? [] }
        }
        ctx.undoChange = { [weak self] index in
            await self?.undoRecent(index) ?? "Smith is locked; unlock first."
        }
        return ctx
    }

    // MARK: the Today page's checkboxes

    /// Ticks a task done, or back to to-do. False when it couldn't be saved.
    func setTask(_ id: String, done: Bool) async -> Bool {
        guard let writer = liveWriter, let n = Int(id) else { return false }
        return await save { try await writer.setTaskStatus(id: n, status: done ? "done" : "todo") }
    }

    /// Ticks a priority off or back on: found in the fresh read by its id (else its
    /// words), so a list reordered in Chronicles since can't tick a different one.
    func setPriority(_ item: PriorityList.Item, done: Bool) async -> Bool {
        await changePriorities { items in
            guard let i = items.firstIndex(where: { $0.same(item) }) else { return nil }
            var list = items; list[i].done = done; return list
        }
    }

    /// Adds a priority at the end of the list (a new list when there isn't one).
    func addPriority(_ text: String) async -> Bool {
        let words = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, let writer = liveWriter else { return false }
        guard let entry = store.snapshot?.priorities?.entryID.flatMap(Int.init) else {
            guard let topic = await sync?.topicID(named: ["Priorities"]) else {
                lastError = "There's no Priorities topic in Chronicles yet."; return false
            }
            return await save {
                let shape = ChroniclesShapes.newPriorities([.init(text: words, done: false, id: UUID().uuidString.lowercased())],
                                                           day: Day.key(), topicID: topic)
                _ = try await writer.createEntry(content: shape.content, metadata: shape.metadata)
            }
        }
        let item = PriorityList.Item(text: words, done: false, id: UUID().uuidString.lowercased())
        return await save { try await writer.updatePriorities(entryID: entry) { $0 + [item] } }
    }

    /// A scheduled dose ticked taken (with its Meals row, as Chronicles adds one), or back to not taken.
    func setDose(medicationID: String, time: String, taken: Bool) async -> Bool {
        guard let writer = liveWriter, let medID = Int(medicationID) else { return false }
        let today = Day.key()
        if taken {
            // What "Smith, I took it" does, but by the medication's id: a name could match
            // another medication, or need a "which one?"
            let tool = LogDoseTool(actionContext(estimate: { _, _, _ in nil }, chips: false))
            return await save { try await tool.markTaken(medicationID: medicationID, time: time) }
        }
        let link = MedNutrients.linkKey(medicationID: medID, date: today, time: time)
        let meal = await sync?.doseLinkEntryID(link)
        return await save {
            _ = try await writer.logDose(medicationID: medID, scheduledTime: time, date: today, status: "pending", takenAt: nil)
            // The Meals row the tick added goes too (if Chronicles lets the app remove it)
            if let meal { _ = try? await writer.deleteEntry(id: meal) }
        }
    }

    /// One more check-in on a habit today, or one fewer.
    func setHabit(_ id: String, add: Bool) async -> Bool {
        guard let writer = liveWriter, let n = Int(id) else { return false }
        let today = Day.key()
        return await save {
            if add { _ = try await writer.checkHabit(habitID: n, day: today) } else { try await writer.undo(.uncheckHabit(habitID: n, day: today)) }
        }
    }

    /// A routine session ticked done (an Exercise entry, as Chronicles logs it), or unticked (that entry removed).
    func setExercise(_ slot: DayOverview.ExerciseSlot, done: Bool) async -> Bool {
        guard let writer = liveWriter else { return false }
        if !done {
            guard let id = slot.sessionID.flatMap(Int.init) else { return true }
            return await save {
                // Only a bare session for this slot goes: one they've written notes or
                // details on (perhaps logged in Chronicles itself) stays
                let e = try await writer.readEntry(id: id)
                guard e.metadata["_aiHidden"]?.bool != true, e.metadata["_routineLink"]?.string == slot.key else {
                    throw ChroniclesError.notFound("That session can’t be removed from here. You can remove it in Chronicles.")
                }
                let cf = e.metadata["_customFields"]
                let theirs = ["notes", "distance", "calories"].contains {
                    !(cf?[$0]?.string ?? cf?[$0]?.double.map { String($0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !theirs else {
                    throw ChroniclesError.notFound("That session has your notes on it, so Smith left it. You can remove it in Chronicles.")
                }
                _ = try await writer.deleteEntry(id: id)
            }
        }
        guard let topic = await sync?.topicID(named: ["Exercise"]) else {
            lastError = "There's no Exercise topic in Chronicles yet."; return false
        }
        guard !hiddenTopicIDs.contains(topic) else {
            lastError = "Exercise is kept from AI in Chronicles, so Smith can't log it."; return false
        }
        return await save { _ = try await writer.logRoutineSession(slot.routine, day: Day.key(), time: slot.time, exerciseTopicID: topic) }
    }

    /// Adds a win (a new Wins entry for today when there isn't one).
    func addWin(_ text: String) async -> Bool {
        let words = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, let writer = liveWriter else { return false }
        let item = WinsList.Item(text: words)
        guard let entry = store.snapshot?.wins.flatMap({ Int($0.entryID) }) else {
            guard let topic = await sync?.topicID(named: ["Wins"]) else {
                lastError = "There's no Wins topic in Chronicles yet."; return false
            }
            return await save {
                let shape = ChroniclesShapes.newWins([item], day: Day.key(), topicID: topic)
                _ = try await writer.createEntry(content: shape.content, metadata: shape.metadata)
            }
        }
        return await save { try await writer.updateWins(entryID: entry) { $0 + [item] } }
    }

    /// Ticks an item on one shopping list got, or back to still to get, by its id.
    func setShoppingItem(_ id: String, onList listID: String, got: Bool) async -> Bool {
        guard let writer = liveWriter, let entry = Int(listID) else { return false }
        return await save {
            let changed = try await writer.updateShopping(entryID: entry) { items in
                guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
                var list = items; list[i].checked = got; return list
            }
            if !changed { throw ChroniclesError.notFound("That item isn’t on the list any more.") }
        }
    }

    /// Adds an item to one shopping list (category "other", as Chronicles' quick add does).
    func addShoppingItem(_ name: String, toList listID: String) async -> Bool {
        let words = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, let writer = liveWriter, let entry = Int(listID) else { return false }
        let item = ShoppingList.Item(name: words)
        return await save { try await writer.updateShopping(entryID: entry) { $0 + [item] } }
    }

    private func changePriorities(_ change: @escaping @Sendable ([PriorityList.Item]) -> [PriorityList.Item]?) async -> Bool {
        guard let writer = liveWriter, let entry = store.snapshot?.priorities?.entryID.flatMap(Int.init) else { return false }
        return await save {
            if !(try await writer.updatePriorities(entryID: entry, change)) {
                throw ChroniclesError.notFound("That priority isn’t on the list any more.")
            }
        }
    }

    /// Saves, then brings Smith's picture of the day up to date.
    private func save(_ write: () async throws -> Void) async -> Bool {
        do {
            try await write()
            await refresh()
            return true
        } catch ChroniclesError.keyChanged {
            Self.forgetQuickUnlock(); lock(); lastError = ChroniclesError.keyChanged.errorDescription
        } catch {
            lastError = "That didn’t save: \(error.localizedDescription)"
        }
        return false
    }

    func undo(_ item: Undoable) async {
        if let problem = await perform(item) { lastError = problem.shown }
    }

    /// Undoes one change; nil when it worked, else what went wrong: in words for the
    /// screen, and for the model without the server's own text (ChroniclesError.forModel).
    private func perform(_ item: Undoable) async -> (shown: String, forModel: String)? {
        undoables.removeAll { $0.id == item.id }
        recentChanges.removeAll { $0.id == item.id }
        guard let session, let client, item.expires > Date() else {
            let m = "That can’t be undone any more. You can change it in Chronicles."
            return (m, m)
        }
        do {
            try await ChroniclesWriter(client: client, session: session).undo(item.action)
            await refresh()
            return nil
        } catch ChroniclesError.keyChanged {
            Self.forgetQuickUnlock(); lock()
            return (ChroniclesError.keyChanged.errorDescription ?? "", ChroniclesError.keyChanged.forModel)
        } catch let e as ChroniclesError {
            return ("Undo didn’t work: \(e.localizedDescription)", "Undo didn't work: \(e.forModel)")
        } catch {
            return ("Undo didn’t work: \(error.localizedDescription)", "Undo didn't work; it can be changed in Chronicles.")
        }
    }

    private func liveRecentChanges(now: Date = Date()) -> [Undoable] {
        recentChanges.removeAll { $0.expires <= now }
        return recentChanges
    }

    /// Smith's undo_change: `index` counts back from the newest change (0 = the last one).
    private func undoRecent(_ index: Int) async -> String {
        let live = liveRecentChanges()
        guard !live.isEmpty else { return "Nothing Smith changed in the last two minutes; older changes are made in Chronicles." }
        guard live.indices.contains(live.count - 1 - index) else { return "There's no such change to undo." }
        let item = live[live.count - 1 - index]
        if let problem = await perform(item) { return problem.forModel }
        return "Undid: \(item.summary)"
    }

    /// A new answer has started: the last one's Undo pills leave the screen.
    func clearUndoChips() { undoables = [] }

    func dropExpiredUndos(now: Date = Date()) {
        undoables.removeAll { $0.expires <= now }
    }
}
