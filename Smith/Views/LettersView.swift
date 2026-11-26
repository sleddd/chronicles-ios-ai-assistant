import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SmithCore

/// Letters: write (or don't), receive a letter and hear it read first, the
/// lines appearing as they're spoken. Every exchange — what you wrote and the
/// letter back — is saved in the Letters box; the heart marks favourites.
struct LettersView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var letter: String?
    @State private var shownLines = 0
    /// Lines revealed so far; they fade in one by one up to here.
    @State private var revealTo = 0
    @State private var writing = false
    /// The voice is loading: the letter appears once its first words are heard.
    @State private var waitingForVoice = false
    @State private var hearing = false
    @State private var error: String?
    @State private var showBox = false
    /// The saved exchange shown now (for the heart).
    @State private var savedID: UUID?

    var body: some View {
        let name = app.store.settings.letterName
        ZStack {
            GlowBackground(warm: true)
            VStack(spacing: 18) {
                HStack {
                    Caps("Letters from \(name)", size: 12, color: Theme.text)
                    Spacer()
                    Button("Letters box") { showBox = true }.buttonStyle(.plain).font(Theme.rounded(12, .medium)).foregroundStyle(Theme.dim)
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(Theme.dim) }.buttonStyle(.plain)
                }
                ScrollView {
                    if let letter, !waitingForVoice {
                        paper(letter)
                    } else if waitingForVoice {
                        loading("\(name) is getting ready to read it to you…")
                    } else if writing {
                        loading("\(name) is writing…")
                    } else {
                        TextField("", text: $message, prompt: Text("Write to \(name)…").foregroundStyle(Theme.faint), axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 18, design: .serif)).lineLimit(4...14)
                            .padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
                if let error { Text(error).font(Theme.rounded(12)).foregroundStyle(Theme.rose) }
                if letter != nil, !waitingForVoice, savedID != nil { Caps("Saved in your Letters box", size: 8.5, color: Theme.faint) }
                if let letter, !waitingForVoice {
                    HStack(spacing: 22) {
                        HearButton(busy: hearing && app.voice.state == .speaking, loading: hearing && app.voice.preparing) {
                            hear(letter)
                        } stop: { app.voice.stopSpeaking() }
                        let fav = savedID.flatMap { id in app.store.letters.first { $0.id == id } }?.isFavorite == true
                        Button { if let id = savedID { app.store.setFavorite(id, !fav) } } label: {
                            Label(fav ? "Favorited" : "Favorite", systemImage: fav ? "heart.fill" : "heart")
                        }.disabled(savedID == nil)
                        CopyButton(text: letter)
                        Button { reset() } label: { Label("Write again", systemImage: "square.and.pencil") }
                    }
                    .buttonStyle(.plain).font(Theme.rounded(14, .medium)).foregroundStyle(Theme.text)
                    if hearing && app.voice.preparing { VoiceLoading(name: name) }
                } else if letter == nil {
                    Button { receive() } label: {
                        Text("Receive a letter")
                            .font(Theme.rounded(16, .medium)).padding(.horizontal, 26).padding(.vertical, 12)
                            .background(LinearGradient(colors: [Theme.rose.opacity(0.7), Theme.amber.opacity(0.6)], startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(writing).opacity(writing ? 0.4 : 1)
                }
            }
            .padding(24)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $showBox) { LettersBox() }
        .onDisappear { app.voice.stopSpeaking() }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private func loading(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(text).font(.system(size: 16, design: .serif)).italic().foregroundStyle(Theme.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
    }

    private func paper(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.prefix(shownLines).enumerated()), id: \.offset) { _, l in
                Text(l.isEmpty ? " " : l).font(.system(size: 18, design: .serif)).italic(l.hasPrefix("Dear") || l.hasPrefix("My "))
                    .transition(.opacity)
            }
        }
        .textSelection(.enabled)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
                .shadow(color: Theme.amber.opacity(0.25), radius: 30)
        )
        // Lines fade in one by one, up to what's been reached in the reading
        .task(id: revealTo) {
            while shownLines < min(revealTo, lines.count) {
                withAnimation(.easeIn(duration: 0.7)) { shownLines += 1 }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    private func receive() {
        writing = true; error = nil
        app.voice.stopSpeaking()
        Task {
            defer { writing = false }
            do {
                let text = try await HenryWriter.write(store: app.store, message: message)
                // Every exchange is kept: what you wrote, and the letter back
                let saved = Letter(yourMessage: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : message, text: text)
                app.store.keep(saved)
                savedID = saved.id
                shownLines = 0; revealTo = 0
                letter = text
                readAloud(text)
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Reads the new letter paragraph by paragraph; each paragraph's lines
    /// appear as its audio starts. Muted: shown at once.
    private func readAloud(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        guard !app.store.settings.muted else { revealTo = lines.count; return }
        waitingForVoice = true
        hearing = true
        var paragraph: [String] = []
        for (i, line) in lines.enumerated() {
            paragraph.append(line)
            let endOfParagraph = i == lines.count - 1 || lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty
            guard endOfParagraph else { continue }
            let said = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph = []
            let upTo = i + 1
            app.voice.speak(said.isEmpty ? " " : said, as: app.henrySpeaker) {
                waitingForVoice = false
                revealTo = max(revealTo, upTo)
            }
        }
        // Lines left after the last spoken paragraph (blank ones) appear at the end
        app.voice.whenDoneSpeaking { waitingForVoice = false; revealTo = lines.count }
    }

    private func hear(_ text: String) {
        hearing = true
        app.voice.preview(app.henrySpeaker, text: text)
    }

    private func reset() {
        app.voice.stopSpeaking()
        letter = nil; message = ""; savedID = nil; hearing = false; waitingForVoice = false
        shownLines = 0; revealTo = 0
    }
}

/// Copies the letter; says "Copied" for a moment.
struct CopyButton: View {
    let text: String
    var compact = false
    @State private var copied = false
    var body: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            let icon = copied ? "checkmark" : "doc.on.doc"
            if compact { Image(systemName: icon) } else { Label(copied ? "Copied" : "Copy", systemImage: icon) }
        }
        .buttonStyle(.plain).help("Copy the letter")
    }
}

/// Shown while the voice is being made, so a wait never looks like nothing happened.
struct VoiceLoading: View {
    let name: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Getting \(name)’s voice ready…").font(Theme.rounded(13, .medium)).foregroundStyle(Theme.amber)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.amber.opacity(0.12), in: Capsule())
        .transition(.opacity)
    }
}

/// "Hear it" that shows when the voice is loading, and becomes Stop while it plays.
struct HearButton: View {
    var busy: Bool
    var loading: Bool
    var compact = false
    let play: () -> Void
    let stop: () -> Void
    var body: some View {
        Button { busy ? stop() : play() } label: {
            if loading {
                HStack(spacing: 6) { ProgressView().controlSize(.small); if !compact { Text("Loading…") } }
            } else if busy {
                if compact { Image(systemName: "stop.circle") } else { Label("Stop", systemImage: "stop.circle") }
            } else {
                if compact { Image(systemName: "speaker.wave.2") } else { Label("Hear it", systemImage: "speaker.wave.2") }
            }
        }
        .buttonStyle(.plain)
        .help(loading ? "Loading the voice…" : busy ? "Stop" : "Hear it")
    }
}

/// Every letter you've sent and received, newest first.
struct LettersBox: View {
    @Environment(AppModel.self) private var app
    @State private var favoritesOnly = false
    @State private var search = ""
    @State private var expanded: Set<UUID> = []
    @State private var confirmDelete: Letter?
    /// The letter being read aloud (for its loading / stop button).
    @State private var hearingID: UUID?

    var body: some View {
        let name = app.store.settings.letterName
        let all = app.store.letters.sorted { $0.date > $1.date }
        let shown = all.filter { l in
            (!favoritesOnly || l.isFavorite) && (search.isEmpty
                || l.text.localizedCaseInsensitiveContains(search) || (l.yourMessage ?? "").localizedCaseInsensitiveContains(search))
        }
        GlassSheet(title: "Letters box") {
            HStack(spacing: 12) {
                TextField("", text: $search, prompt: Text("Search letters").foregroundStyle(Theme.faint)).textFieldStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 8).background(Color.black.opacity(0.5), in: Capsule())
                Picker("", selection: $favoritesOnly) {
                    Text("All \(all.count)").tag(false)
                    Text("♥ \(all.filter(\.isFavorite).count)").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            .padding(.bottom, 10)
            if shown.isEmpty {
                Text(all.isEmpty ? "Letters you send and receive will be here." : "No letters match.")
                    .foregroundStyle(Theme.dim).padding(.top, 8)
            }
            ForEach(shown) { l in
                let open = expanded.contains(l.id)
                GlassCard {
                    HStack {
                        Caps(l.date.formatted(date: .abbreviated, time: .shortened), size: 8.5)
                        Spacer()
                        Button { app.store.setFavorite(l.id, !l.isFavorite) } label: {
                            Image(systemName: l.isFavorite ? "heart.fill" : "heart").foregroundStyle(l.isFavorite ? Theme.rose : Theme.dim)
                        }.buttonStyle(.plain).help(l.isFavorite ? "Unfavorite" : "Favorite")
                        HearButton(busy: hearingID == l.id && app.voice.state == .speaking,
                                   loading: hearingID == l.id && app.voice.preparing, compact: true) {
                            hearingID = l.id
                            app.voice.preview(app.henrySpeaker, text: l.text)
                        } stop: { app.voice.stopSpeaking() }
                        .foregroundStyle(hearingID == l.id && app.voice.state == .speaking ? Theme.amber : Theme.dim)
                        CopyButton(text: l.text, compact: true).foregroundStyle(Theme.dim)
                        Button { confirmDelete = l } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                    }
                    if let m = l.yourMessage {
                        Caps("You wrote", size: 8, color: Theme.faint)
                        Text(m).font(.system(size: 14, design: .serif)).foregroundStyle(Theme.dim).lineSpacing(4)
                            .lineLimit(open ? nil : 3)
                        Caps("\(name) wrote back", size: 8, color: Theme.faint).padding(.top, 4)
                    }
                    if hearingID == l.id && app.voice.preparing { VoiceLoading(name: name) }
                    Text(l.text).font(.system(size: 15, design: .serif)).lineSpacing(5).lineLimit(open ? nil : 5)
                        .textSelection(.enabled)
                    Button(open ? "Show less" : "Read the whole letter") {
                        if open { expanded.remove(l.id) } else { expanded.insert(l.id) }
                    }
                    .buttonStyle(.plain).font(Theme.rounded(12, .medium)).foregroundStyle(Theme.amber)
                }
                .padding(.bottom, 8)
            }
        }
        .alert("Delete this letter?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let l = confirmDelete { app.store.deleteLetter(l.id) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { Text("It’s removed from this device and, after the next sync, from your other one.") }
        .onDisappear { if hearingID != nil { app.voice.stopSpeaking() } }
    }
}
