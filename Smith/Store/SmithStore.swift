import Foundation
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
    var aboutYou = AboutYouStore() { didSet { save(aboutYou, "about-you.smith") } }
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

    init() {
        snapshot = EncryptedFile.read(ChroniclesSnapshot.self, "chronicles.smith")
        journal = EncryptedFile.read([JournalRecord].self, "journal-vault.smith") ?? []
        aboutYou = EncryptedFile.read(AboutYouStore.self, "about-you.smith", defaults: AboutYouStore()) ?? AboutYouStore()
        let convs = EncryptedFile.read(Records<ConversationSummary>.self, "conversations.smith")
        conversations = convs?.items ?? []; conversationTombstones = convs?.tombstones ?? []
        let lets = EncryptedFile.read(Records<Letter>.self, "letters.smith")
        letters = lets?.items ?? []; letterTombstones = lets?.tombstones ?? []
        settings = EncryptedFile.read(SmithSettings.self, "settings.smith", defaults: SmithSettings()) ?? SmithSettings()
        lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date
        aboutYou.fade()
    }

    struct Records<T: Codable>: Codable { var items: [T]; var tombstones: [Tombstone] }

    private func save<T: Encodable>(_ value: T, _ name: String) { EncryptedFile.write(value, name) }

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

    private func saveLetters() { save(Records(items: letters, tombstones: letterTombstones), "letters.smith") }

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
        for f in ["chronicles.smith", "journal-vault.smith", "about-you.smith", "conversations.smith", "letters.smith", "settings.smith"] {
            EncryptedFile.delete(f)
        }
        snapshot = nil; journal = []; aboutYou = AboutYouStore(); conversations = []; letters = []
        conversationTombstones = []; letterTombstones = []; settings = SmithSettings()
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
