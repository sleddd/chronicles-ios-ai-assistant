import Foundation
import SmithCore

/// Imports a Chronicles Export All file into Smith's database (plan, section 1).
/// The whole import happens in memory first and is saved in one go, so a bad
/// file changes nothing.
@MainActor
enum Importer {
    struct Receipt: Equatable {
        var added = 0, updated = 0, removed = 0, newJournal = 0
        var exportedAt: Date

        var text: String {
            var bits = ["+\(added) added", "\(updated) updated", "\(removed) removed"]
            if newJournal > 0 { bits.append("\(newJournal) new journal \(newJournal == 1 ? "entry" : "entries") summarized") }
            return bits.joined(separator: " · ")
        }
    }

    enum ImportError: LocalizedError {
        case older(Date)
        var errorDescription: String? {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            if case .older(let d) = self { return "This export (\(f.string(from: d))) is older than the data Smith already has." }
            return nil
        }
    }

    /// Reads and imports a file the person picked or shared.
    static func importFile(_ url: URL, into store: SmithStore, allowOlder: Bool = false) async throws -> Receipt {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try await importData(data, into: store, allowOlder: allowOlder)
    }

    static func importData(_ data: Data, into store: SmithStore, allowOlder: Bool = false) async throws -> Receipt {
        var parsed = try ExportParser.parse(data)
        if let current = store.snapshot?.exportedAt, parsed.snapshot.exportedAt < current, !allowOlder {
            throw ImportError.older(parsed.snapshot.exportedAt)
        }
        let existing = Dictionary(store.journal.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let records = await JournalVaultBuilder.records(for: parsed.journal, existing: existing,
                                                        neverMention: store.settings.neverMentionTopics,
                                                        summarizer: OnDeviceJournalSummarizer())
        // Drop the entry text now that it's been summarized.
        parsed.journal = []

        var receipt = Receipt(exportedAt: parsed.snapshot.exportedAt)
        let old = store.snapshot
        func diff<T: Identifiable & Equatable>(_ a: [T]?, _ b: [T]) where T.ID == String {
            let before = Dictionary((a ?? []).map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            let after = Set(b.map(\.id))
            for item in b {
                if let o = before[item.id] { if o != item { receipt.updated += 1 } } else { receipt.added += 1 }
            }
            receipt.removed += before.keys.filter { !after.contains($0) }.count
        }
        let s = parsed.snapshot
        diff(old?.tasks, s.tasks); diff(old?.goals, s.goals); diff(old?.milestones, s.milestones)
        diff(old?.calendar, s.calendar); diff(old?.habits, s.habits); diff(old?.medications, s.medications)
        diff(old?.bills, s.bills)
        receipt.newJournal = records.filter { existing[$0.id] == nil }.count

        store.replaceChronicles(s, journal: records)
        return receipt
    }

    /// The newest Chronicles export in the watched folder, if it's newer than what Smith has.
    static func checkWatchedFolder(_ store: SmithStore) async -> Receipt? {
        guard let bookmark = store.settings.watchedFolderBookmark else { return nil }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale) else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent.hasPrefix("chronicles-export") } ?? []
        let newest = files.max {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        guard let newest, let data = try? Data(contentsOf: newest),
              let peek = try? ExportParser.parse(data),
              peek.snapshot.exportedAt > (store.snapshot?.exportedAt ?? .distantPast) else { return nil }
        return try? await importData(data, into: store)
    }

    static func bookmark(for folder: URL) -> Data? {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
}
