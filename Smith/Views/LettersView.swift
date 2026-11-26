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
    /// The saved exchange shown now (for the heart).
    @State private var savedID: UUID?
    /// What they wrote showed signs of risk: help is shown with the letter.
    @State private var risk: RiskResult?

    var compact = false

    var body: some View {
        let name = app.store.settings.letterName
        Group {
            if app.lettersBoxOpen {
                LettersBox { app.lettersBoxOpen = false }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text("LETTERS FROM \(name.uppercased())").font(Theme.rounded(13, .semibold)).tracking(2.4).foregroundStyle(Theme.text)
                        Spacer()
                        Button { app.lettersBoxOpen = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "tray").foregroundStyle(Theme.teal)
                                Text("Letters box").foregroundStyle(Theme.text)
                            }
                            .font(Theme.rounded(15)).padding(.horizontal, 18).frame(height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.13)))
                        }
                        .buttonStyle(.plain)
                    }
                    ScrollView {
                        VStack(spacing: 14) {
                            if let risk, letter != nil, !waitingForVoice {
                                ResourcesCard(kind: risk.kind, urgent: risk.rating == .urgent)
                            }
                            if let letter, !waitingForVoice {
                                paper(letter)
                            } else if waitingForVoice {
                                loading("\(name) is getting ready to read it to you…")
                            } else if writing {
                                loading("\(name) is writing…")
                            } else {
                                TextField("", text: $message, prompt: Text("Write to \(name)…").foregroundStyle(Theme.faint), axis: .vertical)
                                    .textFieldStyle(.plain).font(.system(size: 15, design: .serif)).lineSpacing(4).lineLimit(5...16)
                                    .focusEffectDisabled()
                                    .padding(.horizontal, 40).padding(.vertical, 30)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .smithCard()
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    if let error { Text(error).font(Theme.rounded(13)).foregroundStyle(Theme.rose) }
                    VStack(spacing: 12) {
                        if let letter, !waitingForVoice {
                            if savedID != nil { Caps("Saved in your Letters box", size: 9, color: Theme.faint) }
                            HStack(spacing: 26) {
                                HearButton(busy: hearing && app.voice.state == .speaking, loading: hearing && app.voice.preparing) {
                                    hear(letter)
                                } stop: { app.voice.stopSpeaking() }
                                let fav = savedID.flatMap { id in app.store.letters.first { $0.id == id } }?.isFavorite == true
                                Button { if let id = savedID { app.store.setFavorite(id, !fav) } } label: {
                                    Label(fav ? "Favorited" : "Favorite", systemImage: fav ? "heart.fill" : "heart")
                                        .foregroundStyle(fav ? Theme.magenta : Theme.text)
                                }.disabled(savedID == nil)
                                CopyButton(text: letter)
                                Button { reset() } label: { Label("Write again", systemImage: "square.and.pencil") }
                            }
                            .buttonStyle(.plain).font(Theme.rounded(15, .medium)).foregroundStyle(Theme.text)
                            if hearing && app.voice.preparing { VoiceLoading(name: name) }
                        } else if letter == nil {
                            Button { receive() } label: {
                                Text("Receive a letter")
                                    .font(Theme.rounded(18, .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 36).frame(height: 54)
                                    .background(LinearGradient(colors: [Theme.violet, Theme.magenta], startPoint: .leading, endPoint: .trailing), in: Capsule())
                                    .shadow(color: Theme.magenta.opacity(0.35), radius: 18, y: 6)
                            }
                            .buttonStyle(.plain).disabled(writing).opacity(writing ? 0.45 : 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .onDisappear { app.voice.stopSpeaking() }
    }

    private func loading(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(text).font(.system(size: 16, design: .serif)).italic().foregroundStyle(Theme.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
        .smithCard()
    }

    private func paper(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.prefix(shownLines).enumerated()), id: \.offset) { _, l in
                Text(l.isEmpty ? " " : l).font(.system(size: 15, design: .serif)).lineSpacing(5)
                    .transition(.opacity)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 40).padding(.vertical, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .smithCard()
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
                let written = try await HenryWriter.write(store: app.store, message: message)
                let text = written.text
                risk = written.risk.isRisk ? written.risk : nil
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
        letter = nil; message = ""; savedID = nil; hearing = false; waitingForVoice = false; risk = nil
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
    var onClose: () -> Void = {}
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
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("LETTERS BOX").font(Theme.rounded(13, .semibold)).tracking(2.4).foregroundStyle(Theme.text)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.soft)
                        .frame(width: 44, height: 44).overlay(Circle().stroke(.white.opacity(0.13)))
                }
                .buttonStyle(.plain).help("Back to letters")
            }
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                    TextField("", text: $search, prompt: Text("Search letters").foregroundStyle(Theme.faint))
                        .textFieldStyle(.plain).focusEffectDisabled()
                }
                .font(Theme.rounded(14))
                .padding(.horizontal, 16).frame(height: 40)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.09)))
                // All / favourites
                HStack(spacing: 4) {
                    filterPill(Text("All \(all.count)"), on: !favoritesOnly) { favoritesOnly = false }
                    filterPill(Text("\(Image(systemName: "heart.fill")) \(all.filter(\.isFavorite).count)"), on: favoritesOnly) { favoritesOnly = true }
                }
                .padding(4)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.09)))
            }
            ScrollView {
                VStack(spacing: 18) {
                    if shown.isEmpty {
                        Text(all.isEmpty ? "Letters you send and receive will be here." : "No letters match.")
                            .font(Theme.rounded(15)).foregroundStyle(Theme.dim).padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(shown) { l in card(l, name: name) }
                }
            }
            .scrollIndicators(.hidden)
        }
        .alert("Delete this letter?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let l = confirmDelete { app.store.deleteLetter(l.id) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { Text("It’s removed from this device and, after the next sync, from your other one.") }
        .onDisappear { if hearingID != nil { app.voice.stopSpeaking() } }
    }

    private func filterPill(_ label: Text, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label.font(Theme.rounded(13, .medium)).foregroundStyle(on ? Theme.teal : Theme.soft)
                .padding(.horizontal, 12).frame(height: 32)
                .background(on ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The letter's paragraphs (split at blank lines).
    private func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func card(_ l: Letter, name: String) -> some View {
        let open = expanded.contains(l.id)
        let paras = paragraphs(l.text)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Text(l.date.formatted(date: .abbreviated, time: .shortened).uppercased())
                    .font(Theme.rounded(11, .medium)).tracking(1.6).foregroundStyle(Theme.dim)
                Spacer()
                Button { app.store.setFavorite(l.id, !l.isFavorite) } label: {
                    Image(systemName: l.isFavorite ? "heart.fill" : "heart").foregroundStyle(l.isFavorite ? Theme.magenta : Theme.soft)
                }.buttonStyle(.plain).help(l.isFavorite ? "Unfavorite" : "Favorite")
                HearButton(busy: hearingID == l.id && app.voice.state == .speaking,
                           loading: hearingID == l.id && app.voice.preparing, compact: true) {
                    hearingID = l.id
                    app.voice.preview(app.henrySpeaker, text: l.text)
                } stop: { app.voice.stopSpeaking() }
                .foregroundStyle(hearingID == l.id && app.voice.state == .speaking ? Theme.teal : Theme.soft)
                CopyButton(text: l.text, compact: true).foregroundStyle(Theme.soft)
                Button { confirmDelete = l } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.soft)
                    .help("Delete")
            }
            .font(.system(size: 14))
            if let m = l.yourMessage {
                Caps("You wrote", size: 9, color: Theme.faint)
                Text(m).font(.system(size: 14, design: .serif)).foregroundStyle(Theme.dim).lineSpacing(4)
                    .lineLimit(open ? nil : 3)
                Caps("\(name) wrote back", size: 9, color: Theme.faint).padding(.top, 2)
            }
            if hearingID == l.id && app.voice.preparing { VoiceLoading(name: name) }
            // Closed: the greeting and the start of the letter; open: all of it
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array((open ? paras : Array(paras.prefix(2))).enumerated()), id: \.offset) { i, p in
                    Text(p).font(.system(size: 15, design: .serif)).lineSpacing(5)
                        .lineLimit(open || i == 0 ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            if paras.count > 1 || l.text.count > 200 {
                Button(open ? "Show less" : "Read the whole letter") {
                    withAnimation(.easeInOut(duration: 0.25)) { if open { expanded.remove(l.id) } else { expanded.insert(l.id) } }
                }
                .buttonStyle(.plain).font(Theme.rounded(13, .semibold)).foregroundStyle(Theme.teal)
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .smithCard()
    }
}
