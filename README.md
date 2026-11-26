# Smith
Smith is a voice-first personal assistant for Mac and iPad. It knows your day from Chronicles: tasks, priorities, events, habits, doses and bill dates. You can talk to it or type, and it answers in text and out loud, warmly, like a friend who knows your schedule. It can also act in Chronicles for you: log a meal, tick a dose, check off a habit, save a note, add or finish a task, help reorganize your daily agenda, or mark a bill paid.

> [!WARNING]
> **Smith is under active development and is not ready for beta.** Expect missing pieces, breaking changes and data you may have to re-import. Don't rely on it for anything important yet.
>
> **Because Smith is still under development, the security of your data while using it can't be guaranteed. Please use it with caution.**

> [!IMPORTANT]
> **Smith is an extension of [Chronicles](https://github.com/sleddd/chronicles) and only works paired with it.** It has no data of its own and can't run on its own. Your Chronicles account must also be on the server's assistant allowlist (`ASSISTANT_CLIENT_EMAILS`). Until it is, the Chronicles setting that turns Smith on doesn't appear, and Smith can't sign in.

## Contents

- [Requirements](#requirements)
- [Setup](#setup)
- [Build and run](#build-and-run)
- [Features](#features)
- [Privacy and data](#privacy-and-data)
- [Safety](#safety)
- [Project layout](#project-layout)
- [Tests](#tests)
- [Status](#status)

## Requirements

- **A Chronicles server** running a version with assistant sessions, and an account on it.
- **Allowlisting:** your account's email must be in `ASSISTANT_CLIENT_EMAILS` on that server.
- **An Anthropic API key**, saved in Chronicles (Settings → In-App AI). Smith uses that key and doesn't need its own. It currently will only integrate with Claude.
- **Xcode 26** on macOS 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- **macOS 26 or iPadOS 26** to run it.
- **Optional:** an [ElevenLabs](https://elevenlabs.io) API key for more natural voices. Without one, Smith uses Apple's voices.

## Setup

1. **On the Chronicles server:** add your email to `ASSISTANT_CLIENT_EMAILS` and restart the server.
2. **In Chronicles:** open Settings → In-App AI and turn on **Chronicles AI app (Mac and iPad)**. This switch only appears for allowlisted accounts. Choose there what AI may see. Smith follows those choices; it has no privacy settings of its own.
3. **In Smith:** press **Connect to Chronicles** at the top of the home screen and sign in with your Chronicles email and password (and your 2FA code if you use one).
4. **The first time,** Smith asks you to confirm you're 18 or older. If your Chronicles account already confirmed this for In-App AI, Smith uses that confirmation.

## Build and run

```sh
brew install xcodegen     # once
xcodegen generate         # after adding or removing files
open Smith.xcodeproj
```

Set your own development team in `project.yml` (`DEVELOPMENT_TEAM`) before building.

**Mac:**
- Choose the *Smith* scheme and *My Mac*, then press Run.
- ⌥Space opens a floating panel from anywhere.
- The menu bar icon has Talk, Morning briefing, Lock and Quit.

**iPad:**
- Connect the iPad, choose it as the destination, and press Run.
- The first time, trust your developer profile on the iPad: Settings → General → VPN & Device Management.
- With a free Apple ID, the install lasts 7 days. Run it from Xcode again to renew it; your data stays.

**"Hey Smith":** link the phrase to the *Talk to Smith* shortcut in Settings → Accessibility → Vocal Shortcuts. On the Mac there's also an optional built-in listener in Smith's Settings → Mac.

## Features

- **Voice and text:**
  - Tap the orb to talk, or hold it for a back-and-forth conversation.
  - You can also type. There's no limit on how long you dictate.
  - Replies are spoken, and the text appears like subtitles as the audio plays.
- **Your day at a glance:** the next event, open and overdue tasks, priorities, and the date, time and weather.
- **Acting in Chronicles:**
  - When you ask directly ("log my breakfast: oatmeal"), Smith does it and offers **Undo** for 2 minutes.
  - When Smith is only guessing that you'd want something logged, it asks first.
- **Memory:**
  - Smith notes what matters (how an appointment went, people in your life, what you like).
  - You can view, edit and delete everything in **Me**, pause learning, or tell it never to learn something.
- **Voices:** Apple's voices by default. With an ElevenLabs key, Smith can use ElevenLabs voices, and on its v4 models the voice performs emotes like *laughs*.
- **Mac and iPad sync:** the two devices sync Smith's own data directly over your local network. Nothing goes through a server.

## Privacy and data

- **Nothing is hosted.** Smith keeps its data in encrypted files on the device, sealed with a key held by the device's Secure Enclave.
- **Signing in:**
  - Your Chronicles password is never stored.
  - The Chronicles key and session exist only in memory while Smith is unlocked.
  - Locking, auto-lock and quitting wipe both.
- **Chronicles decides what Smith sees.** Entries marked *Hide from AI*, topics on the *Don't share with AI* list, and switched-off features (doses, habits, bills, vision) never reach Smith. This holds for the live connection and for imported exports.
- **Journal text never goes to the AI.** Entries are summarized on the device by Apple's Foundation Models, and only a general summary (counts, overall tone, broad themes) is ever sent.
- **Finance:** only bill names, due dates and paid status are kept. Amounts never are.
- **Chats** are kept as short summaries only, never as transcripts.
- **What leaves the device:**
  - What you say to Smith goes to Anthropic's API to be answered.
  - With ElevenLabs on, Smith's spoken replies go to ElevenLabs to become speech.
  - The weather lookup sends coordinates rounded to about 1 km to Open-Meteo.
- **What Chronicles enforces on Smith's session:** a short list of allowed requests. Smith can add records and tick things done. It can delete only what it created in the last 2 minutes, and nothing else.

## Safety

Smith follows Anthropic's requirements for apps built on its API, and shares its guardrails with Chronicles:

- **Anonymized user ID:** every request to Claude carries an anonymous ID, the same one Chronicles uses for your account. It never contains a name or email.
- **Declined requests:**
  - When Claude declines a request for safety reasons, the time is recorded (never the content) and counted with Chronicles' count for your account.
  - 5 in a day shows a warning, 10 in a day pauses AI for 24 hours, and 20 in 30 days turns it off until a Chronicles administrator lifts it.
- **Crisis support:**
  - What you say, and Smith's replies, are screened for signs of suicide, self-harm or eating-disorder risk, first on the device and then by a short check through Claude.
  - When there's a sign, Smith shows free helplines (988, Crisis Text Line, the National Alliance for Eating Disorders, findahelpline.com) and follows stricter rules for the rest of the conversation.
  - Smith never gives methods, doses or harmful diet advice.
- **Adults only:** Smith asks you to confirm you're 18 or older. If what you write suggests you're under 18, chat and letters pause.

Smith is an AI. It isn't a therapist or a crisis service and can't contact anyone for you. If you're in danger, call 911. For support any time in the US, call or text 988.

## Project layout

- `Packages/SmithCore/` — everything that doesn't need a screen. It has Swift Testing tests.
  - the Chronicles client and crypto
  - live sync and export parsing
  - the privacy filters
  - the day overview
  - the persona and phrase guard
  - the Claude client
  - the safety screening and refusal ladder
  - memory
- `Smith/` — the SwiftUI app for macOS and iPadOS.
  - storage and the Secure Enclave
  - voice
  - screens
  - Siri intents
  - the Mac menu bar
  - device-to-device sync
- `project.yml` — the XcodeGen project definition.
- `docs/PLAN.md` — the full design.

## Tests

```sh
cd Packages/SmithCore && swift test
```

The privacy tests run Smith's briefing, chat, wrap-up and letters over a sample export with planted markers in its private parts. They check that none of those markers reach a request, the saved files or the sync payload. Other tests cover:

- Chronicles' encryption, using known-answer vectors from Chronicles itself
- the live sync against a fake server
- the safety screening, using the same cases as Chronicles
- the refusal ladder

## Status

Under active development, not yet in beta. Expect missing features, rough edges and breaking changes. Work happens alongside [Chronicles](https://github.com/sleddd/chronicles), and the two need to be updated together.
