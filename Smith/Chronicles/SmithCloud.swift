import Foundation
import Observation
import SmithCore

/// Keeps Smith's memories, letters and conversation summaries in Chronicles,
/// so every device has the same ones. They're ordinary Chronicles entries in
/// Smith's three topics, sealed with the account's key like the journal.
///
/// After every Chronicles sync, and a moment after anything changes here, it
/// compares Chronicles, this device and what both agreed on last time
/// (SmithMerge), then sends this device's changes and takes the rest.
@MainActor @Observable
final class SmithCloud {
    /// What both sides agreed on at the last sync, per account. Kept on the device, encrypted.
    private struct State: Codable {
        var account: String?
        var base: [UUID: String] = [:]
        var remote: [UUID: Int] = [:]
    }
    private static let file = "smith-cloud.smith"
    private var state: State
    /// Chronicles' copy as last seen (entry ids, who made each), for changes made between syncs.
    private var lastRemote: [RemoteSmithRecord] = []
    private var topicIDs: [String: Int] = [:]
    private var running = false
    private var again = false
    private var pending: Task<Void, Never>?

    private(set) var lastProblem: String?

    private let store: SmithStore
    private let writer: () -> ChroniclesWriter?
    private let account: () -> String?
    private let takenTopicIDs: () async -> Set<Int>
    /// Raised by an erase or a sign-out, so a sync that was mid-way doesn't put anything back.
    private var epoch = 0

    init(store: SmithStore, writer: @escaping () -> ChroniclesWriter?, account: @escaping () -> String?,
         takenTopicIDs: @escaping () async -> Set<Int> = { [] }) {
        self.store = store; self.writer = writer; self.account = account; self.takenTopicIDs = takenTopicIDs
        state = EncryptedFile.read(State.self, Self.file) ?? State()
        // Read at the first sync after each unlock (its file opens only while unlocked)
        stateLoaded = false
        store.onSmithDataChanged = { [weak self] in self?.changedHere() }
        store.onErased = { [weak self] in self?.erased() }
    }

    /// A change here: send it shortly (a few quick edits go together).
    private func changedHere() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.reconcile(remote: self.lastRemote, topics: self.topicIDs)
        }
    }

    /// After a Chronicles sync: what Chronicles has now.
    func synced(remote: [RemoteSmithRecord], topics: [String: Int]) async {
        await reconcile(remote: remote, topics: topics)
    }

    private var stateLoaded = false

    /// "Erase everything on this device": forget what was agreed with Chronicles.
    /// Kept, it would read the now-empty device as "everything was deleted here"
    /// and delete every memory and letter from Chronicles at the next sign-in.
    private func erased() {
        pending?.cancel(); pending = nil
        epoch += 1
        state = State(); lastRemote = []; topicIDs = [:]
    }

    func signedOut() {
        lastRemote = []; topicIDs = [:]
        state = State(); stateLoaded = false
        epoch += 1
        pending?.cancel(); pending = nil
    }

    private func reconcile(remote: [RemoteSmithRecord], topics: [String: Int]) async {
        guard let writer = writer(), let account = account() else { return }
        if running { again = true; return }
        running = true
        defer { running = false }

        // Nothing is compared, sent or deleted until this device's own copy is really loaded
        guard store.loaded else { return }
        if !stateLoaded {
            state = EncryptedFile.read(State.self, Self.file) ?? State()
            stateLoaded = true
        }
        let epoch = self.epoch
        // Another account on this device: start its agreement afresh. The memories and
        // letters here belong to the account before, and are not sent to this one.
        if state.account != account {
            if state.account != nil { store.applySmithRecords([]) }
            state = State(account: account)
        }
        // This device's records couldn't be opened: "missing here" must not be read as
        // "deleted here". With no agreement, Chronicles' copy is simply taken.
        if store.smithRecordsUnreadable { state.base = [:] }
        topicIDs = topics
        lastRemote = remote

        let plan = SmithMerge.plan(remote: remote, local: store.smithRecords, base: state.base)
        var entryOf = Dictionary(remote.map { ($0.record.id, $0.entryID) }, uniquingKeysWith: { a, _ in a })
        var base = Dictionary(remote.map { ($0.record.id, $0.record.fingerprint) }, uniquingKeysWith: { a, _ in a })
        var problem: String?
        var keep = plan.keep
        // Changes that didn't reach Chronicles: its copy is still the old one
        var unsent = Set<UUID>()
        let remoteByEntry = Dictionary(remote.map { ($0.entryID, $0) }, uniquingKeysWith: { a, _ in a })
        // Chronicles wouldn't take a change to one of the person's own entries: its copy
        // comes back here (so the two agree and it isn't tried for ever), and they're told
        func putBack(_ r: RemoteSmithRecord) {
            if let i = keep.firstIndex(where: { $0.id == r.record.id }) { keep[i] = r.record } else { keep.append(r.record) }
            problem = "One you wrote in Chronicles can only be changed there, so it’s back as it was."
        }

        // A topic is made the first time something needs to go in it
        func topicID(for record: SmithRecord) async -> Int? {
            if let id = topicIDs[record.topic] { return id }
            do {
                let id = try await writer.createTopic(named: record.topic, taken: await takenTopicIDs().union(topicIDs.values))
                topicIDs[record.topic] = id
                return id
            } catch { problem = error.localizedDescription; return nil }
        }

        for rec in plan.create {
            guard let topic = await topicID(for: rec) else { continue }
            do {
                entryOf[rec.id] = try await writer.createSmithRecord(rec, topicID: topic)
                base[rec.id] = rec.fingerprint
            } catch { problem = error.localizedDescription }   // stays "new here": tried again next time
        }
        for (entryID, rec) in plan.update {
            guard let topic = await topicID(for: rec) else { continue }
            let theirs = remoteByEntry[entryID]?.owned == false
            do {
                try await writer.updateSmithRecord(entryID: entryID, rec, topicID: topic, theirs: theirs)
                base[rec.id] = rec.fingerprint
            } catch ChroniclesError.refused where theirs {
                if let r = remoteByEntry[entryID] { putBack(r) }
            } catch { problem = error.localizedDescription; unsent.insert(rec.id) }   // base unchanged: tried again next time
        }
        let deleted = Set(plan.delete)
        for entryID in plan.delete {
            do {
                try await writer.deleteSmithRecord(entryID: entryID)
            } catch ChroniclesError.notFound {
                // already gone
            } catch ChroniclesError.refused where remoteByEntry[entryID]?.owned == false {
                if let r = remoteByEntry[entryID] { putBack(r) }
                continue
            } catch {
                problem = error.localizedDescription
                continue
            }
            if let id = remote.first(where: { $0.entryID == entryID })?.record.id { base[id] = nil; entryOf[id] = nil }
        }
        // A delete that didn't go through stays agreed-on, so it's tried again
        for r in remote where deleted.contains(r.entryID) && entryOf[r.record.id] != nil {
            base[r.record.id] = state.base[r.record.id] ?? r.record.fingerprint
        }

        // Smith's letters still in the old "Letters" topic move to "Smith letters" (once each)
        let touched = Set(plan.update.map(\.entryID)).union(deleted)
        for r in remote where r.misplaced && r.owned && !touched.contains(r.entryID) {
            guard let topic = await topicID(for: r.record) else { break }
            do { try await writer.updateSmithRecord(entryID: r.entryID, r.record, topicID: topic) }
            catch { problem = error.localizedDescription }   // still read where it is; tried again next time
        }

        // Erased or signed out while this was under way: nothing from it is applied
        guard epoch == self.epoch else { return }
        store.applySmithRecords(keep)
        state.base = base.filter { entryOf[$0.key] != nil }
        state.remote = entryOf
        EncryptedFile.write(state, Self.file)

        // Chronicles as it now is, for the next change made here
        // (Where a change or a delete didn't go through, Chronicles still has what it had:
        // recording this device's version as "agreed" would revert the change next time)
        let remoteByID = Dictionary(remote.map { ($0.record.id, $0) }, uniquingKeysWith: { a, _ in a })
        lastRemote = keep.compactMap { rec in
            if unsent.contains(rec.id), let old = remoteByID[rec.id] { return old }
            return entryOf[rec.id].map { RemoteSmithRecord(entryID: $0, record: rec, owned: remoteByID[rec.id]?.owned ?? true) }
        } + remote.filter { r in deleted.contains(r.entryID) && entryOf[r.record.id] != nil && !keep.contains { $0.id == r.record.id } }
        lastProblem = problem
        // Everything agreed with Chronicles: files that couldn't be opened are whole again
        if problem == nil { store.smithRecordsRecovered() }

        if again {
            again = false
            await reconcile(remote: lastRemote, topics: topicIDs)
        }
    }
}
