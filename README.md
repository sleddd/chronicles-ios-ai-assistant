# Smith

A personal assistant for Mac and iPad that knows your day from Chronicles. You talk to it, and it answers in text and with an Apple voice. This app is for personal use only. It's side-loaded from Xcode and signed with a free Apple ID (a Personal Team).

The full design is in [docs/PLAN.md](docs/PLAN.md).

## Layout

- `Packages/SmithCore/`: everything that doesn't need a screen.
  - export parser
  - journal and finance privacy filters
  - day overview, concerns and freshness nudges
  - persona prompt and banned-phrase guard
  - Claude client (raw HTTPS with streaming)
  - About You memory
  - sync merge rules
- `Smith/`: the SwiftUI app for macOS and iPadOS: storage, voice, screens, Siri intents, Mac menu bar and sync.
- `project.yml`: the Xcode project definition. Run `xcodegen generate` after you add or remove files.

## Connect to Chronicles (live, no exports)

Smith works like a Chronicles app. Your **Chronicles password unlocks it**:
- **Signing in:** Smith signs in with an *assistant session*. It unlocks your Chronicles key on the device and keeps both the key and the session **in memory only**.
- **Locking:** **Lock** (or auto-lock, or quitting) wipes both.

**Setup:**
1. On the Chronicles server, set `ASSISTANT_CLIENT_EMAILS` to your email. This is the Chronicles branch `smith-assistant`.
2. In Chronicles, open Settings → In-App AI and turn on **Chronicles AI app (Mac and iPad)**.
3. In Smith, open Settings → Chronicles, choose **Connect to Chronicles**, and sign in.

**What Smith can do:**
- **Reading:** your day, tasks, goals, habits, doses and bill dates, synced live.
- **Writing:** it can log meals (with Chronicles' own nutrient estimate), tick doses, check off habits, save notes, add tasks and mark them done, and mark bills paid.
- **Explicit or inferred:**
  - If you tell Smith directly ("Smith, log meal: …"), he does it and offers **Undo** for 2 minutes.
  - If he's only inferring it, he asks first.

**What the Chronicles server enforces:**
- Smith can't delete anything, except undoing what it just created.
- It never receives anything you keep from AI in Chronicles: hidden entries, hidden topics, and the doses, habits or bills features.

**More about unlocking and keys:**
- **Face ID / Touch ID (optional):** reopens the same Chronicles session with a copy sealed to this device's Secure Enclave. When the session ends, the copy is deleted.
- **AI key:** Smith uses your Anthropic key from Chronicles (Settings → In-App AI), held in memory while unlocked. A key saved in Smith is only a fallback.
- **Smith's own secrets** (storage key, sync key, fallback API key) are sealed to the Secure Enclave.
- **ElevenLabs voices (optional):** add your ElevenLabs key in Settings → ElevenLabs voices, then pick voices for Smith and Henry.
  - Smith's spoken replies (and a letter when you press Hear it) go to ElevenLabs to become speech.
  - Each piece is sent with the text just before it, so the tone carries on.
  - If ElevenLabs can't be reached, the Apple voice speaks.

The Export All import stays as a backup.

## Run it

1. Run `brew install xcodegen` (once), then `xcodegen generate`, then open `Smith.xcodeproj`.
2. **Mac:**
   - Choose the *Smith* scheme and *My Mac*, then press Run.
   - ⌥Space opens the floating panel from anywhere.
   - The menu bar orb has Talk, Briefing and Sync.
3. **iPad:**
   - Plug in the iPad, choose it as the destination, and press Run.
   - The first time, open Settings → General → VPN & Device Management on the iPad and trust your developer profile.
   - The install lasts **7 days**. Run from Xcode again to refresh it. Your data stays.
4. In Smith → Settings:
   - Paste your **Anthropic API key**. It's kept in this device's Keychain only.
   - **Import** a Chronicles export: in Chronicles, Settings → Data → Export All. Then use Import, drag the file onto the Mac window, or Share → Smith on the iPad.
   - **Pair**: on the iPad, open Settings → Sync → Pair with my Mac. On the Mac, open Settings → Sync and type the code.
5. "Hey Smith": in Accessibility → Vocal Shortcuts, link the phrase to the *Talk to Smith* shortcut. On the Mac, an optional in-app listener is in Settings → Mac.

## Tests

```sh
cd Packages/SmithCore && swift test
```

The privacy tests use a sample export with planted markers in:
- journal entries
- notes
- finance
- wellness check-ins
- saved chats

They run the briefing, chat with tools, conversation wrap-up and a Henry letter through a recording transport. They check that none of the markers, and no run of 4 words from any journal entry, appear in any request. They also check the saved snapshot, the journal vault and the sync payload.

## Where data lives

Everything is stored on the device. Nothing is hosted.

- **Storage:** encrypted files in the app's private folder. They're sealed with AES-GCM under a Keychain key that is only on this device, and they're excluded from backups.
- **Journal entries:** summarized on the device by Apple's Foundation Models, then the text is discarded.
- **Finance:** only bill names, due dates, frequency and paid status are kept.
- **Chats:** kept as summaries only.
