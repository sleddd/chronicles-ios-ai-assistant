import Foundation
import CryptoKit
import Observation
import SmithCore

/// All of Smith's data on this device. Nothing is hosted: each part is an
/// encrypted file in the app's private folder (see `EncryptedFile`).
///
/// - `snapshot`: what Smith keeps from Chronicles (no journal text, no money amounts)
/// - `journal`: the journal vault — summaries per entry, never entry text
/// - `aboutYou`, `conversations`, `letters`: Smith's own data, never touched by imports
@MainActor @Observable
final class SmithStore {
    private(set) var snapshot: ChroniclesSnapshot?
    private(set) var journal: [JournalRecord] = []
    var aboutYou = AboutYouStore() { didSet { save(aboutYou, "about-you.smith"); smithDataChanged() } }
    private(set) var conversations: [ConversationSummary] = []
    private(set) var conversationTombstones: [Tombstone] = []
    private(set) var letters: [Letter] = []
    private(set) var letterTombstones: [Tombstone] = []
    var settings = SmithSettings() {
        didSet {
            guard settings != oldValue else { return }
            save(settings, "settings.smith")
        }
    }
    /// When this device last synced, and whether the other device has newer data.
    var lastSync: Date? { didSet { UserDefaults.standard.set(lastSync, forKey: "lastSync") } }
    var peerHasNewer = false

    /// False while the storage key can't be read (see `Keychain.storageKey`): what is
    /// in memory is then just defaults, and saving it would write over the real files.
    private(set) var loaded = false
    /// Memories, letters or summaries are on the disk but couldn't be opened. Smith's
    /// copy in Chronicles must then be taken as it is, never "tidied" to match an empty device.
    private(set) var smithRecordsUnreadable = false
    /// After a late load, for the parts that read the settings when they were made.
    var onLoaded: (() -> Void)?
    /// After "Erase everything": the agreement with Chronicles goes too.
    var onErased: (() -> Void)?

    init() { load() }

    /// Chronicles' copy of the memories, letters and summaries is now this device's:
    /// the files that couldn't be opened are written afresh, and ordinary syncing resumes.
    func smithRecordsRecovered() {
        guard smithRecordsUnreadable, loaded else { return }
        smithRecordsUnreadable = false
        save(aboutYou, "about-you.smith")
        save(Records(items: conversations, tombstones: conversationTombstones), "conversations.smith")
        save(Records(items: letters, tombstones: letterTombstones), "letters.smith")
    }

    /// Called when the app comes forward: loads what couldn't be read at launch.
    func loadIfNeeded() {
        guard !loaded, EncryptedFile.isAvailable else { return }
        load()
        onLoaded?()
    }

    private func load() {
        guard EncryptedFile.isAvailable else { return }
        // Loading is not a change: nothing is saved back (`loaded` is still false, so
        // `save` does nothing) or sent to Chronicles from here
        applyingFromChronicles = true
        defer { applyingFromChronicles = false; loaded = true }
        settings = EncryptedFile.read(SmithSettings.self, "settings.smith", defaults: SmithSettings()) ?? SmithSettings()
        lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date
        // Everything personal waits for Smith to be unlocked (`openVault`)
    }

    /// Smith was unlocked: the personal files can be opened now. They are sealed under
    /// a key made from the Chronicles master key, which exists only while unlocked.
    func openVault(_ key: SymmetricKey) {
        EncryptedFile.setVaultKey(key)
        let wasLoaded = loaded
        loaded = false   // loading is not a change: nothing is saved back from here
        applyingFromChronicles = true
        defer { applyingFromChronicles = false; loaded = wasLoaded; resealLegacyFiles() }
        let about = EncryptedFile.read(AboutYouStore.self, "about-you.smith", defaults: AboutYouStore())
        smithRecordsUnreadable = (about == nil && EncryptedFile.exists("about-you.smith"))
            || (EncryptedFile.exists("conversations.smith") && EncryptedFile.raw("conversations.smith") == nil)
            || (EncryptedFile.exists("letters.smith") && EncryptedFile.raw("letters.smith") == nil)
        snapshot = EncryptedFile.read(ChroniclesSnapshot.self, "chronicles.smith")
        journal = EncryptedFile.read([JournalRecord].self, "journal-vault.smith") ?? []
        aboutYou = about ?? AboutYouStore()
        let convs = EncryptedFile.read(Records<ConversationSummary>.self, "conversations.smith")
        conversations = convs?.items ?? []; conversationTombstones = convs?.tombstones ?? []
        let lets = EncryptedFile.read(Records<Letter>.self, "letters.smith")
        letters = lets?.items ?? []; letterTombstones = lets?.tombstones ?? []
        aboutYou.fade()
    }

    /// Files from before the vault key were sealed under the device key: once read,
    /// they are saved again under the vault key, so the device key no longer opens them.
    private func resealLegacyFiles() {
        let legacy = EncryptedFile.takeLegacyReads()
        guard loaded, !legacy.isEmpty else { return }
        if legacy.contains("chronicles.smith"), let snapshot { save(snapshot, "chronicles.smith") }
        if legacy.contains("journal-vault.smith") { save(journal, "journal-vault.smith") }
        if legacy.contains("about-you.smith") { save(aboutYou, "about-you.smith") }
        if legacy.contains("conversations.smith") { save(Records(items: conversations, tombstones: conversationTombstones), "conversations.smith") }
        if legacy.contains("letters.smith") { save(Records(items: letters, tombstones: letterTombstones), "letters.smith") }
    }

    /// Smith locked: the key goes, and so does everything personal held in memory.
    func closeVault() {
        // The key first, so clearing the values below can't write empty files over the real ones
        EncryptedFile.setVaultKey(nil)
        applyingFromChronicles = true
        defer { applyingFromChronicles = false }
        snapshot = nil; journal = []
        aboutYou = AboutYouStore()
        conversations = []; conversationTombstones = []
        letters = []; letterTombstones = []
        smithRecordsUnreadable = false
    }

    struct Records<T: Codable>: Codable { var items: [T]; var tombstones: [Tombstone] }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard loaded else { return }
        EncryptedFile.write(value, name)
    }

    // MARK: settings

    func updateSettings(_ change: (inout SmithSettings) -> Void) {
        var s = settings
        change(&s)
        s.updatedAt = Date()
        settings = s
    }

    /// Device-only changes that shouldn't win a sync (voices, bookmarks, greeting day).
    func updateLocalSettings(_ change: (inout SmithSettings) -> Void) {
        var s = settings
        change(&s)
        settings = s
    }

    // MARK: Chronicles data

    func replaceChronicles(_ snap: ChroniclesSnapshot, journal records: [JournalRecord]) {
        snapshot = snap
        journal = records
        save(snap, "chronicles.smith")
        save(records, "journal-vault.smith")
    }

    var journalDigestText: String? {
        let today = Day.key()
        return JournalDigest.make(from: journal, today: today, neverMention: settings.neverMentionTopics)
            .text(today: today, mode: settings.journalMode)
    }

    /// Tagged journal and topic entries Smith may see: none while journal sharing is
    /// off, never one in a "never mention" topic. Day, topic and tags only.
    var taggedEntries: [TaggedEntry] {
        TaggedEntry.visible(journal, mode: settings.journalMode, neverMention: settings.neverMentionTopics,
                            topics: snapshot?.topics ?? [:])
    }

    // MARK: conversations

    func addConversation(_ summary: ConversationSummary) {
        conversations.append(summary)
        saveConversations()
    }

    func editConversation(_ id: UUID, text: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].text = text
        conversations[i].updatedAt = Date()
        saveConversations()
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        conversationTombstones.append(Tombstone(id: id, deletedAt: Date()))
        saveConversations()
    }

    func clearConversations() {
        conversationTombstones += conversations.map { Tombstone(id: $0.id, deletedAt: Date()) }
        conversations = []
        saveConversations()
    }

    private func saveConversations() {
        save(Records(items: conversations, tombstones: conversationTombstones), "conversations.smith")
        smithDataChanged()
    }

    // MARK: letters

    func keep(_ letter: Letter) {
        letters.append(letter)
        saveLetters()
    }

    /// Heart a letter, or un-heart it.
    func setFavorite(_ id: UUID, _ on: Bool) {
        guard let i = letters.firstIndex(where: { $0.id == id }) else { return }
        letters[i].favorite = on
        letters[i].updatedAt = Date()
        saveLetters()
    }

    func deleteLetter(_ id: UUID) {
        letters.removeAll { $0.id == id }
        letterTombstones.append(Tombstone(id: id, deletedAt: Date()))
        saveLetters()
    }

    private func saveLetters() {
        save(Records(items: letters, tombstones: letterTombstones), "letters.smith")
        smithDataChanged()
    }

    // MARK: Smith's records in Chronicles

    /// Called when memories, letters or summaries change here (to send them to Chronicles).
    var onSmithDataChanged: (() -> Void)?
    private var applyingFromChronicles = false
    private func smithDataChanged() { if !applyingFromChronicles { onSmithDataChanged?() } }

    /// Everything that lives in Chronicles, as records.
    var smithRecords: [SmithRecord] {
        aboutYou.facts.map(SmithRecord.fact) + aboutYou.dontLearn.map(SmithRecord.dontLearn)
            + letters.map(SmithRecord.letter) + conversations.map(SmithRecord.conversation)
    }

    /// What Chronicles holds, now this device's copy (kept for when it's locked or offline).
    func applySmithRecords(_ records: [SmithRecord]) {
        applyingFromChronicles = true
        defer { applyingFromChronicles = false }
        var about = aboutYou
        about.facts = records.compactMap { if case .fact(let f) = $0 { f } else { nil } }
        about.dontLearn = records.compactMap { if case .dontLearn(let d) = $0 { d } else { nil } }
        if about != aboutYou { aboutYou = about }
        let newLetters = records.compactMap { if case .letter(let l) = $0 { l } else { nil } }.sorted { $0.date < $1.date }
        if newLetters != letters { letters = newLetters; saveLetters() }
        let newConversations = records.compactMap { if case .conversation(let c) = $0 { c } else { nil } }.sorted { $0.day < $1.day }
        if newConversations != conversations { conversations = newConversations; saveConversations() }
    }

    // MARK: sync

    var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "iPad"
        #endif
    }

    func syncPayload() -> SyncPayload {
        let settingsJSON = (try? JSONEncoder().encode(settings)).flatMap { try? JSONValue.parse($0) } ?? [:]
        return SyncPayload(deviceName: deviceName, snapshot: snapshot, journal: journal, aboutYou: aboutYou,
                           conversations: conversations, conversationTombstones: conversationTombstones,
                           letters: letters, letterTombstones: letterTombstones,
                           settings: settingsJSON, settingsUpdatedAt: settings.updatedAt)
    }

    func apply(_ merged: SyncPayload) {
        if let s = merged.snapshot, s != snapshot { replaceChronicles(s, journal: merged.journal) }
        aboutYou = merged.aboutYou
        conversations = merged.conversations; conversationTombstones = merged.conversationTombstones
        saveConversations()
        letters = merged.letters; letterTombstones = merged.letterTombstones
        saveLetters()
        if merged.settingsUpdatedAt > settings.updatedAt,
           let data = try? merged.settings.encoded(), var incoming = Tolerant.decode(SmithSettings.self, from: data, defaults: SmithSettings()) {
            // Keep what belongs to this device.
            incoming.smithVoiceID = settings.smithVoiceID
            incoming.henryVoiceID = settings.henryVoiceID
            incoming.macWakeWord = settings.macWakeWord
            incoming.lastGreetingDay = settings.lastGreetingDay
            incoming.chroniclesEmail = settings.chroniclesEmail
            incoming.chroniclesServer = settings.chroniclesServer
            settings = incoming
        }
        lastSync = Date()
        peerHasNewer = false
    }

    /// A one-way backup file (Export Smith Data), sealed with the pairing key,
    /// so only your paired devices can open it.
    func exportBackup() throws -> Data {
        guard let key = Keychain.syncKey else { throw SyncError.notPaired }
        let plain = try JSONEncoder().encode(syncPayload())
        return try AESGCMBox.seal(plain, key: key)
    }

    func importBackup(_ data: Data) throws -> SyncReceipt {
        guard let key = Keychain.syncKey else { throw SyncError.notPaired }
        let plain = try AESGCMBox.open(data, key: key)
        let theirs = try JSONDecoder().decode(SyncPayload.self, from: plain)
        let (merged, receipt) = SyncMerge.merge(syncPayload(), theirs)
        apply(merged)
        return receipt
    }

    /// Deletes only the Chronicles data kept here (the day's picture and the
    /// journal summaries). Memory, conversation summaries, letters and settings stay.
    func clearChroniclesData() {
        EncryptedFile.delete("chronicles.smith")
        EncryptedFile.delete("journal-vault.smith")
        snapshot = nil; journal = []
        lastSync = nil
        updateLocalSettings { $0.chroniclesHome = nil }
    }

    /// Wipes everything Smith stores on this device.
    func eraseAll() {
        // Erasing this device is not deleting from Chronicles: nothing here counts as a change to send
        applyingFromChronicles = true
        defer { applyingFromChronicles = false }
        snapshot = nil; journal = []; aboutYou = AboutYouStore(); conversations = []; letters = []
        conversationTombstones = []; letterTombstones = []; settings = SmithSettings()
        // Last, so the saves the lines above trigger don't put files back
        for f in ["chronicles.smith", "journal-vault.smith", "about-you.smith", "conversations.smith", "letters.smith",
                  "settings.smith", "smith-cloud.smith"] {
            EncryptedFile.delete(f)
        }
        smithRecordsUnreadable = false
        // A fresh key, made at the next save. Also the way out when the old one won't open.
        Keychain.resetStorageKey()
        EncryptedFile.setVaultKey(nil)
        loaded = true
        onErased?()
    }
}

enum SyncError: LocalizedError {
    case notPaired, badCode, connection(String)
    var errorDescription: String? {
        switch self {
        case .notPaired: "Pair your Mac and iPad first (Settings → Sync)."
        case .badCode: "That code didn't match. Try again."
        case .connection(let m): m
        }
    }
}

/// AES-GCM for the `.smithdata` backup file.
enum AESGCMBox {
    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw SyncError.connection("Couldn't seal the file.") }
        return Data("SMITH1".utf8) + combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.starts(with: Data("SMITH1".utf8)) else { throw SyncError.connection("That isn't a Smith data file.") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(6)), using: key)
    }
}
