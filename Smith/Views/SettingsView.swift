import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import SmithCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var apiKey = Keychain.apiKey ?? ""
    @State private var exportingBackup: SmithDataDocument?
    @State private var pairCode = ""
    @State private var confirmErase = false
    @State private var newBanned = ""
    @State private var confirmChroniclesReset = false
    @State private var newSample = ""
    @State private var elevenKey = ""
    @State private var elevenVoices: [ElevenLabs.Voice] = []
    @State private var elevenError: String?
    @State private var elevenLoading = false
    @State private var hasElevenKey = ElevenLabs.apiKey != nil
    @State private var elevenStatus: String?
    @State private var cityQuery = ""
    @State private var cityStatus: String?

    var body: some View {
        @Bindable var store = app.store
        let s = store.settings
        GlassSheet(title: "Settings") {
            Group {
                SectionLabel("Claude")
                GlassCard {
                    Toggle("Use the AI key from Chronicles", isOn: Binding(get: { s.useChroniclesAIKey }, set: { v in
                        store.updateLocalSettings { $0.useChroniclesAIKey = v }; app.applyVoiceSettings(); app.brain.refreshHeadline() }))
                    Caps(APIKeys.usingChronicles
                         ? "Using your Anthropic key from Chronicles (In-App AI). It stays in memory only while Smith is unlocked."
                         : "Used when Smith is unlocked and Chronicles' In-App AI uses Anthropic. Otherwise the key below is used.",
                         size: 8, color: Theme.faint)
                    SecureField("", text: $apiKey, prompt: Text(APIKeys.usingChronicles ? "Fallback API key (optional)" : "Anthropic API key").foregroundStyle(Theme.faint)).textFieldStyle(.plain)
                        .onSubmit { Keychain.apiKey = apiKey; app.brain.refreshHeadline() }
                    Button("Save key") { Keychain.apiKey = apiKey; app.brain.refreshHeadline() }.buttonStyle(.plain).foregroundStyle(Theme.violet)
                    Caps("\(Keychain.storageDescription). Never synced.", size: 8, color: Theme.faint)
                    Picker("Model", selection: binding(\.model)) { ForEach(ClaudeModel.allCases, id: \.self) { Text($0.label).tag($0) } }
                }

                SectionLabel("Smith")
                GlassCard {
                    TextField("Name", text: binding(\.name)).textFieldStyle(.plain)
                    voicePicker("Voice", selection: Binding(get: { s.smithVoiceID }, set: { v in store.updateLocalSettings { $0.smithVoiceID = v }; app.applyVoiceSettings() }),
                                sample: "Good morning. Here's what's on today.")
                    HStack { Text("Speaking speed"); Slider(value: Binding(get: { Double(s.speechRate) }, set: { v in store.updateLocalSettings { $0.speechRate = Float(v) }; app.applyVoiceSettings() })) }
                    Picker("When I pause, wait", selection: Binding(get: { s.pauseWait }, set: { v in store.updateSettings { $0.pauseWait = v }; app.applyVoiceSettings() })) {
                        Text("2 seconds").tag(2.0); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0); Text("Until I tap").tag(0.0)
                    }
                    Caps("Tap the orb anytime to say you're done.", size: 8, color: Theme.faint)
                    Toggle("Mute Smith (text only)", isOn: Binding(get: { s.muted }, set: { v in store.updateSettings { $0.muted = v }; if v { app.voice.stopSpeaking() } }))
                    Toggle("Speak replies to typed messages", isOn: binding(\.speakTypedReplies))
                    Toggle("Mention a goal in the morning briefing", isOn: binding(\.goalMentionInBriefing))
                    Toggle("Temperatures in °F", isOn: Binding(get: { s.fahrenheit }, set: { v in store.updateSettings { $0.fahrenheit = v }; app.applyVoiceSettings() }))
                    Caps("Voices: download Enhanced or Premium voices in System Settings → Accessibility → Spoken Content.", size: 8, color: Theme.faint)
                }

                SectionLabel("Words Smith never uses")
                GlassCard { bannedCard }

                SectionLabel("Weather")
                GlassCard { weatherCard }

                SectionLabel("ElevenLabs voices")
                GlassCard { elevenCard }
            }
            Group {
                SectionLabel("Chronicles")
                GlassCard { chroniclesCard }

                SectionLabel(app.chronicles.state == .notSetUp ? "Chronicles data" : "Backup: import an export")
                GlassCard {
                    if let snap = store.snapshot {
                        Text("Data as of \(snap.exportedAt.formatted(date: .abbreviated, time: .shortened))").font(Theme.rounded(14))
                    } else { Text("Nothing imported yet.").foregroundStyle(Theme.dim) }
                    Button("Import Chronicles export…") { app.sheet = nil; NotificationCenter.default.post(name: .smithImport, object: nil) }
                        .buttonStyle(.plain).foregroundStyle(Theme.violet)
                    Caps("In Chronicles: Settings → Data → Export All, then import the file here or share it to Smith.", size: 8, color: Theme.faint)
                }

                SectionLabel("Privacy")
                GlassCard {
                    Text("What Smith may see is set in Chronicles: Settings → In-App AI. Topics and features you keep from AI there, and entries marked Hide from AI, never reach Smith — live or from an export.")
                        .font(Theme.rounded(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    let hidden = app.chronicles.hiddenTopicIDs.compactMap { store.snapshot?.topics[String($0)] }.sorted()
                    if app.chronicles.isUnlocked {
                        Text(hidden.isEmpty ? "No topics are kept from AI." : "Kept from AI: " + hidden.joined(separator: ", "))
                            .font(Theme.rounded(13, .medium))
                    }
                    Caps("Journal entries are summarized on this device; the text is never sent. Bill amounts are never kept.", size: 8, color: Theme.faint)
                }
            }
            Group {
                SectionLabel("Memory and concerns")
                GlassCard {
                    Toggle("Remember conversations as summaries", isOn: binding(\.memoryEnabled))
                    Text("Smith may mention a concern at most once a week:").font(Theme.rounded(13)).foregroundStyle(Theme.dim)
                    ForEach(Concern.Area.allCases, id: \.self) { area in
                        Toggle(area.label, isOn: Binding(get: { !s.concerns.disabledAreas.contains(area) },
                            set: { on in store.updateSettings { if on { $0.concerns.disabledAreas.remove(area) } else { $0.concerns.disabledAreas.insert(area) } } }))
                    }
                    Caps("Safety warnings can't be turned off.", size: 8, color: Theme.faint)
                }

                SectionLabel("Updates")
                GlassCard {
                    Picker("Tell me when data is behind", selection: binding(\.freshness.threshold)) {
                        ForEach(Freshness.Threshold.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Export reminders", isOn: binding(\.freshness.exportReminders))
                    Toggle("Sync reminders", isOn: binding(\.freshness.syncReminders))
                    Toggle("iPad install reminders", isOn: binding(\.freshness.installReminders))
                    if let exp = InstallInfo.expiration { Caps("This install expires \(exp.formatted(date: .abbreviated, time: .shortened))", size: 8, color: Theme.faint) }
                }
            }
            henry
            syncSection
            heySmith
            #if os(macOS)
            macSection
            #endif
            Group {
                SectionLabel("Erase")
                GlassCard {
                    Button("Remove Chronicles data from this device") { confirmChroniclesReset = true }
                        .buttonStyle(.plain).foregroundStyle(Theme.rose)
                    Caps("Signs out and deletes the Chronicles data Smith keeps here. What Smith knows about you, conversation summaries and letters stay.", size: 8, color: Theme.faint)
                    Button("Erase everything Smith stores on this device") { confirmErase = true }.buttonStyle(.plain).foregroundStyle(Theme.rose)
                        .padding(.top, 6)
                }
            }
        }
        .fileExporter(isPresented: Binding(get: { exportingBackup != nil }, set: { if !$0 { exportingBackup = nil } }),
                      document: exportingBackup, contentType: .smithData, defaultFilename: "Smith backup") { _ in exportingBackup = nil }
        .alert("Remove Chronicles data?", isPresented: $confirmChroniclesReset) {
            Button("Remove", role: .destructive) { app.chronicles.removeChroniclesData(); app.brain.refreshHeadline() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Smith signs out of Chronicles and deletes your tasks, events, goals, habits, bill dates and journal summaries from this device. What Smith knows about you, conversation summaries, letters and settings stay. Connect or import again to bring Chronicles back.")
        }
        .alert("Erase everything?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) {
                // Signed out first, so nothing is synced back onto the device just erased
                app.chronicles.disconnect()
                app.startOver()
                store.eraseAll()
                app.brain.refreshHeadline()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deletes Smith's data on this device: Chronicles data, journal summaries, what Smith knows about you, conversation summaries, letters and settings.") }
    }

    @ViewBuilder private var bannedCard: some View {
        let custom = app.store.settings.customBannedPhrases
        Text("Add any word or phrase you never want to hear from Smith, in chat or in letters. It's added to the built-in list (things like \"I'm proud of you\" and \"haha\").")
            .font(Theme.rounded(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        if !custom.isEmpty {
            FlowChips(items: custom) { phrase in
                app.store.updateSettings { $0.customBannedPhrases.removeAll { $0 == phrase } }
            }
        }
        HStack(spacing: 12) {
            TextField("", text: $newBanned, prompt: Text("Add a word or phrase").foregroundStyle(Theme.faint))
                .textFieldStyle(.plain).focusEffectDisabled().onSubmit(addBanned)
                .padding(.horizontal, 14).frame(height: 36)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button("Add", action: addBanned).buttonStyle(.plain).foregroundStyle(Theme.teal)
                .disabled(newBanned.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addBanned() {
        let p = newBanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        app.store.updateSettings { s in
            if !s.customBannedPhrases.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) { s.customBannedPhrases.append(p) }
        }
        newBanned = ""
    }

    @ViewBuilder private var weatherCard: some View {
        let s = app.store.settings
        Picker("Weather for", selection: Binding(get: { s.weatherSource }, set: { v in
            app.store.updateLocalSettings { $0.weatherSource = v }
            Task { await app.weather.refresh(fahrenheit: s.fahrenheit, force: true) }
        })) {
            ForEach(WeatherSource.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        switch s.weatherSource {
        case .chronicles:
            Text(s.chroniclesHome.map { "Home: \($0.name)" } ?? "No home city in Chronicles yet (Dashboard → World clocks: the first place is home). Using this device’s location meanwhile.")
                .font(Theme.rounded(12)).foregroundStyle(Theme.dim)
        case .city:
            HStack {
                TextField("", text: $cityQuery, prompt: Text(s.weatherCity?.name ?? "City, e.g. Portland, OR").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).onSubmit(findCity)
                Button("Find", action: findCity).buttonStyle(.plain).foregroundStyle(Theme.violet)
            }
            if let c = cityStatus { Text(c).font(Theme.rounded(12)).foregroundStyle(Theme.dim) }
        case .device:
            Text("Uses this \(isMac ? "Mac" : "iPad")’s approximate location (you’ll be asked once).").font(Theme.rounded(12)).foregroundStyle(Theme.dim)
        }
        if let r = app.weather.report {
            Text("\(app.weather.placeName ?? ""): \(r.line)").font(Theme.rounded(12)).foregroundStyle(Theme.teal)
        } else if let p = app.weather.problem {
            Text(p).font(Theme.rounded(12)).foregroundStyle(Theme.rose)
        }
        Caps("Only the place’s coordinates go to Open-Meteo, the free weather service Chronicles uses.", size: 8, color: Theme.faint)
    }

    private func findCity() {
        let q = cityQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        cityStatus = "Looking…"
        Task {
            do {
                let place = try await OpenMeteo.findPlace(q)
                app.store.updateLocalSettings { $0.weatherCity = place; $0.weatherSource = .city }
                cityQuery = ""
                cityStatus = "Weather for \(place.name)."
                await app.weather.refresh(fahrenheit: app.store.settings.fahrenheit, force: true)
            } catch {
                cityStatus = "Couldn’t find “\(q)”. Try adding the state or country."
            }
        }
    }

    @ViewBuilder private var elevenCard: some View {
        @Bindable var store = app.store
        let s = store.settings
        Toggle("Use ElevenLabs voices", isOn: Binding(get: { s.useElevenLabs }, set: { v in
            store.updateSettings { $0.useElevenLabs = v }; app.applyVoiceSettings()
            if v && elevenVoices.isEmpty { loadElevenVoices() }
        }))
        HStack {
            SecureField("", text: $elevenKey, prompt: Text(hasElevenKey ? "Key saved ✓ — paste a new one to replace it" : "ElevenLabs API key").foregroundStyle(Theme.faint))
                .textFieldStyle(.plain)
                .onSubmit(saveElevenKey)
            Button("Save", action: saveElevenKey).buttonStyle(.plain).foregroundStyle(Theme.violet)
                .disabled(elevenKey.trimmingCharacters(in: .whitespaces).isEmpty)
            if hasElevenKey {
                Button("Remove") {
                    ElevenLabs.apiKey = nil; hasElevenKey = false; elevenVoices = []; elevenStatus = "Key removed."
                    store.updateSettings { $0.useElevenLabs = false }; app.applyVoiceSettings()
                }.buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
        }
        if elevenLoading {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking your key and loading your voices…").font(Theme.rounded(12)) }
        } else if let st = elevenStatus {
            Text(st).font(Theme.rounded(12)).foregroundStyle(Theme.teal)
        }
        if hasElevenKey && !elevenVoices.isEmpty {
            elevenPicker("\(s.name)’s voice", selection: Binding(get: { s.elevenSmithVoice }, set: { v in
                store.updateSettings { $0.elevenSmithVoice = v }; app.applyVoiceSettings() }),
                sample: "Good morning. Here’s what’s on today.", model: s.elevenModel)
            elevenPicker("Letters voice", selection: Binding(get: { s.elevenHenryVoice }, set: { v in
                store.updateSettings { $0.elevenHenryVoice = v }; app.applyVoiceSettings() }),
                sample: "My love, I’ve been thinking about you all day.", model: .v4)
            Picker("Model", selection: Binding(get: { s.elevenModel }, set: { v in store.updateSettings { $0.elevenModel = v }; app.applyVoiceSettings() })) {
                ForEach(ElevenLabs.Model.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } else if hasElevenKey && !elevenLoading {
            Button("Load my voices") { loadElevenVoices() }.buttonStyle(.plain).foregroundStyle(Theme.violet)
        }
        if let e = elevenError ?? app.voice.lastVoiceError { Text(e).font(Theme.rounded(12)).foregroundStyle(Theme.rose) }
        Caps("What \(s.name) says aloud (and a letter when you press Hear it) is sent to ElevenLabs to become speech. If it can’t be reached, the Apple voice speaks instead. The key is \(Keychain.storageDescription.lowercased()).", size: 8, color: Theme.faint)
            .onAppear { if hasElevenKey && elevenVoices.isEmpty { loadElevenVoices(announce: false) } }
    }

    private func elevenPicker(_ title: String, selection: Binding<String?>, sample: String, model: ElevenLabs.Model) -> some View {
        HStack {
            Picker(title, selection: selection) {
                Text("Apple voice").tag(String?.none)
                ForEach(elevenVoices) { v in Text(v.detail.isEmpty ? v.name : "\(v.name) · \(v.detail)").tag(Optional(v.id)) }
            }
            Button {
                if let id = selection.wrappedValue { app.voice.preview(.eleven(voice: id, model: model), text: sample) }
            } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).disabled(selection.wrappedValue == nil)
        }
    }

    private func saveElevenKey() {
        let key = elevenKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        ElevenLabs.apiKey = key
        elevenKey = ""
        hasElevenKey = ElevenLabs.apiKey != nil
        guard hasElevenKey else { elevenError = "That key couldn’t be saved on this device."; return }
        loadElevenVoices(announce: true)
    }

    /// Checks the key by loading the voices. After a new key: switch ElevenLabs on,
    /// give Smith and Henry a voice if they have none, and say hello in Smith's new voice.
    private func loadElevenVoices(announce: Bool = false) {
        guard let key = ElevenLabs.apiKey else { return }
        elevenLoading = true; elevenError = nil; elevenStatus = nil
        Task {
            do {
                let voices = try await ElevenLabs.voices(key: key)
                elevenVoices = voices
                if announce, let first = voices.first {
                    let store = app.store
                    store.updateSettings { s in
                        s.useElevenLabs = true
                        if s.elevenSmithVoice == nil || !voices.contains(where: { $0.id == s.elevenSmithVoice }) { s.elevenSmithVoice = first.id }
                        if s.elevenHenryVoice == nil || !voices.contains(where: { $0.id == s.elevenHenryVoice }) {
                            s.elevenHenryVoice = (voices.dropFirst().first ?? first).id
                        }
                    }
                    app.applyVoiceSettings()
                    let name = voices.first { $0.id == store.settings.elevenSmithVoice }?.name ?? first.name
                    elevenStatus = "Key saved. \(voices.count) voices loaded — \(store.settings.name) now speaks as \(name). Pick another below."
                    app.voice.preview(app.smithSpeaker, text: "Hello. This is my new voice. Pick another in Settings if you’d like.")
                } else {
                    elevenStatus = "\(voices.count) voices loaded."
                }
            } catch {
                elevenError = error.localizedDescription
            }
            elevenLoading = false
        }
    }

    @ViewBuilder private var chroniclesCard: some View {
        let c = app.chronicles
        let s = app.store.settings
        if c.state == .notSetUp {
            Text("Connect \(s.name) to your Chronicles account: your Chronicles password unlocks it, it reads your day live, and it can log meals, doses, habits, notes, tasks and bill payments for you.")
                .font(Theme.rounded(13)).foregroundStyle(Theme.dim)
            Button("Connect to Chronicles") { app.sheet = nil; c.beginSetup() }.buttonStyle(.plain).foregroundStyle(Theme.violet)
        } else {
            Text(s.chroniclesEmail ?? "").font(Theme.rounded(14))
            Text(c.isUnlocked ? "Unlocked\(c.lastSync.map { " · synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "")" : "Locked")
                .font(Theme.rounded(12)).foregroundStyle(c.isUnlocked ? Theme.teal : Theme.dim)
            if let e = c.lastError { Text(e).font(Theme.rounded(12)).foregroundStyle(Theme.rose) }
            if c.isUnlocked {
                HStack(spacing: 18) {
                    Button(c.syncing ? "Syncing…" : "Sync now") { Task { await c.refresh() } }.disabled(c.syncing)
                    Button("Lock and sign out") { app.sheet = nil; c.lock() }
                }.buttonStyle(.plain).foregroundStyle(Theme.violet)
            }
            if ChroniclesConnection.quickUnlockAvailable {
                Toggle("Unlock with \(ChroniclesConnection.biometryName)", isOn: Binding(get: { s.quickUnlock }, set: { c.setQuickUnlock($0) }))
                Caps("Locking then keeps your Chronicles session and seals it to this device’s Secure Enclave, so \(ChroniclesConnection.biometryName) can reopen it until it ends (2 hours idle, 7 days at most, or revoked in Chronicles). Off: locking ends the session and only your password unlocks.", size: 8, color: Theme.faint)
            }
            Picker("Lock after", selection: binding(\.autoLockMinutes)) {
                Text("5 minutes idle").tag(5); Text("15 minutes idle").tag(15); Text("30 minutes idle").tag(30)
                Text("2 hours idle").tag(120); Text("Only when I lock or quit").tag(0)
            }
            Button("Disconnect this device") { c.disconnect() }.buttonStyle(.plain).foregroundStyle(Theme.dim)
        }
        TextField("Server", text: Binding(get: { s.chroniclesServer ?? ChroniclesConnection.defaultServer },
                                          set: { v in app.store.updateLocalSettings { $0.chroniclesServer = v == ChroniclesConnection.defaultServer ? nil : v } }))
            .textFieldStyle(.plain).font(Theme.rounded(12)).foregroundStyle(Theme.dim)
        Caps("Your password is never stored. The key stays in memory only while unlocked. What you keep from AI in Chronicles (Settings → In-App AI) is never sent here.", size: 8, color: Theme.faint)
    }

    private func binding<T>(_ path: WritableKeyPath<SmithSettings, T>) -> Binding<T> {
        Binding(get: { app.store.settings[keyPath: path] }, set: { v in app.store.updateSettings { $0[keyPath: path] = v } })
    }

    private func voicePicker(_ title: String, selection: Binding<String?>, sample: String) -> some View {
        HStack {
            Picker(title, selection: selection) {
                Text("Best available").tag(String?.none)
                ForEach(VoiceIO.choosableVoices, id: \.identifier) { v in Text(v.name.contains("(") ? v.name : "\(v.name) (\(v.quality.label))").tag(Optional(v.identifier)) }
            }
            Button { app.voice.preview(.apple(selection.wrappedValue), text: sample) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var henry: some View {
        @Bindable var store = app.store
        let h = store.settings.henry
        SectionLabel("Letters")
        GlassCard {
            Text("Signed by").font(Theme.rounded(13, .medium))
            TextField("", text: binding(\.henry.name), prompt: Text(store.settings.name).foregroundStyle(Theme.faint)).textFieldStyle(.plain)
                .padding(8).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            Text("Leave blank to have \(store.settings.name) write them, or give any name you like.").font(Theme.rounded(11)).foregroundStyle(Theme.dim)
            Text("Who they are").font(Theme.rounded(13, .medium))
            TextField("", text: binding(\.henry.description), prompt: Text("Their voice, how they speak to you, your history together, pet names, what they admire in you, what they'd never say…").foregroundStyle(Theme.faint), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...12).padding(8).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack { Text("Playful").font(Theme.rounded(12)); Slider(value: binding(\.henry.romance)); Text("Romantic").font(Theme.rounded(12)) }
            HStack { Text("Plain").font(Theme.rounded(12)); Slider(value: binding(\.henry.poetry)); Text("Poetic").font(Theme.rounded(12)) }
            Picker("Length", selection: binding(\.henry.length)) {
                Text("A note").tag(HenryPersona.Length.note); Text("A letter").tag(HenryPersona.Length.letter); Text("A long letter").tag(HenryPersona.Length.longLetter)
            }.pickerStyle(.segmented)
            Text("Sample letters").font(Theme.rounded(13, .medium))
            ForEach(Array(h.samples.enumerated()), id: \.offset) { i, sample in
                HStack(alignment: .top) {
                    Text(sample).font(.system(size: 12, design: .serif)).lineLimit(3)
                    Spacer()
                    Button { store.updateSettings { $0.henry.samples.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            HStack {
                TextField("", text: $newSample, prompt: Text("Paste a sample letter").foregroundStyle(Theme.faint), axis: .vertical).textFieldStyle(.plain)
                Button("Add") { guard !newSample.isEmpty else { return }; store.updateSettings { $0.henry.samples.append(newSample) }; newSample = "" }.buttonStyle(.plain).foregroundStyle(Theme.violet)
            }
            Toggle("Draw on my day (goals and the general journal summary only)", isOn: binding(\.henry.drawOnMyDay))
            Toggle(h.name.isEmpty ? "Use what \(store.settings.name) knows about me" : "Let \(store.settings.letterName) use what \(store.settings.name) knows about me", isOn: Binding(get: { store.aboutYou.shareWithHenry }, set: { store.aboutYou.shareWithHenry = $0 }))
            voicePicker("Letters voice", selection: Binding(get: { store.settings.henryVoiceID }, set: { v in store.updateLocalSettings { $0.henryVoiceID = v } }),
                        sample: "My love, I've been thinking about you all day.")
        }
    }

    @ViewBuilder private var syncSection: some View {
        SectionLabel("Your devices")
        GlassCard {
            Text("Memories, letters and conversation summaries are kept in Chronicles, sealed with your Chronicles key, so every device you sign in on has the same ones.")
                .font(Theme.rounded(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            Text("In Chronicles they're the topics \(SmithTopics.all.map { "“\($0)”" }.joined(separator: ", ")). You can read and edit them there too.")
                .font(Theme.rounded(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            if let p = app.chronicles.cloud.lastProblem {
                Text("Last sync problem: \(p)").font(Theme.rounded(12)).foregroundStyle(Theme.rose)
            }
            Button(app.chronicles.syncing ? "Syncing…" : "Sync now") { Task { await app.chronicles.refresh() } }
                .buttonStyle(.plain).foregroundStyle(Theme.violet).disabled(app.chronicles.syncing)
        }
    }

    @ViewBuilder private var heySmith: some View {
        SectionLabel("\"Hey Smith\"")
        GlassCard {
            Text("Use Vocal Shortcuts so \"Hey Smith\" works even when Smith is closed:").font(Theme.rounded(13))
            Text("1. Open Accessibility → Vocal Shortcuts.\n2. Add Action → choose the shortcut \"Talk to Smith\".\n3. Type \"Hey Smith\" and say it three times.")
                .font(Theme.rounded(13)).foregroundStyle(Theme.dim)
            Button("Open Accessibility settings") { openVocalShortcuts() }.buttonStyle(.plain).foregroundStyle(Theme.violet)
            Caps("You can also say \"Hey Siri, ask Smith …\" in one go.", size: 8, color: Theme.faint)
        }
    }

    #if os(macOS)
    @ViewBuilder private var macSection: some View {
        SectionLabel("Mac")
        GlassCard {
            Toggle("Start at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.set($0) }))
            Toggle("Greet me on the first wake of the day", isOn: binding(\.greetOnWake))
            Toggle("Listen for \"Hey Smith\" while in the menu bar", isOn: Binding(get: { app.store.settings.macWakeWord }, set: { on in
                app.store.updateLocalSettings { $0.macWakeWord = on }
                if on { WakeWordListener.shared.start() } else { WakeWordListener.shared.stop() }
            }))
            Caps("Listening happens on this Mac; nothing is sent until you say \"Hey Smith\". The microphone light stays on while it's enabled.", size: 8, color: Theme.faint)
            Caps("Shortcut: ⌥Space opens Smith from anywhere.", size: 8, color: Theme.faint)
        }
    }
    #endif

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private func openVocalShortcuts() {
        #if os(macOS)
        if let u = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension") { NSWorkspace.shared.open(u) }
        #else
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        #endif
    }
}

nonisolated extension UTType {
    static let smithData = UTType(exportedAs: "com.fastandcurious.smith.smithdata")
}

nonisolated struct SmithDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.smithData] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Phrases as removable chips that wrap onto new lines.
struct FlowChips: View {
    let items: [String]
    let remove: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 6) {
                    Text(item).font(Theme.rounded(13)).foregroundStyle(Theme.text)
                    Button { remove(item) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Remove")
                }
                .padding(.horizontal, 12).frame(height: 30)
                .background(Color.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.1)))
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
