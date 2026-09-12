# Voice assistant (`voice-live` branch)

How the Gemini Live voice assistant is developed, built, and kept away from
the App Store release train while it matures. This is a living reference —
add findings with the date they were observed. Facts below were recorded on
2026-09-12 unless noted otherwise.

## Purpose

The voice assistant lets you control drover by talking to it: a full-duplex
voice session with Gemini Live, reached through Firebase AI Logic. The model
drives drover via function calling over the same `HerdrClient` operations the
UI uses (list agents, read status, send a prompt, …). No Gemini API key lives
on the device — the app talks to Firebase AI Logic, and App Check protects
that endpoint, so only a build of this app (or a registered debug token) can
use the project's quota.

It lives on the long-lived `voice-live` branch rather than `main` because it
needs several weeks of on-device iteration (session limits, echo handling,
tool surface) before it is fit for the App Store, and because every build of
it must reach TestFlight testers without ever being uploadable to the
released `1.0.x` train.

## Branch workflow

- Feature PRs target `voice-live`, not `main`.
- Merge `main` into `voice-live` about weekly — a merge, not a rebase. The
  branch is shared and Xcode Cloud builds it by name, so its history must
  not be rewritten.
- When it is ready, open one PR `voice-live` → `main`, merge it, then run
  `just release 1.1.0` from `main` as usual.
- Versioning: `voice-live` carries marketing version `1.1.0`; `main` stays
  `1.0.x`. Apple closes a marketing version's pre-release train once it ships
  (ITMS-90186, see "Releasing" in `CLAUDE.md`), and a `1.0.x` build from this
  branch would either be rejected or, worse, end up in the shipped train.
  Keeping the branch one minor ahead avoids both.
- The weekly merge from `main` conflicts on `app/pubspec.yaml`'s `version:`
  line whenever `main` released in between (its `just release` commits bump
  that line). Resolve it by keeping `1.1.0`. `just voice-build` refuses to run
  if the marketing version equals `main`'s, so a botched resolution is caught
  before a build starts.

## TestFlight builds

Run `just voice-build` from `voice-live`. It changes nothing locally — no
version bump, no commit, no push — it only checks that the local tip matches
`origin/voice-live` (Xcode Cloud builds the remote tip) and that the marketing
version differs from `main`'s, then starts the "Voice Live" Xcode Cloud
workflow. The marketing version comes from the name part of pubspec's
`version:`; the build number comes from Xcode Cloud's per-app counter, not
from pubspec's `+N` (which is why there is nothing to bump). It never touches
tags or `CHANGELOG.md`.

One-time App Store Connect setup (done in the console, not scriptable):

1. Xcode Cloud → Manage Workflows → add a workflow named exactly
   **Voice Live** (the justfile looks it up by that name).
2. Start conditions: manual only — remove the branch and pull-request
   triggers, same reasoning as the `Default` workflow (see the comment above
   `release` in the `justfile`).
3. Environment/branch: `voice-live`.
4. Archive action for iOS with the post-action **TestFlight Internal Testing**
   only. Do not add an App Store distribution post-action.
5. Leave "Next Build Number" alone (Xcode Cloud → Settings). The counter is
   per app and shared by every workflow (Apple: "Setting the next build
   number for Xcode Cloud builds"), so Voice Live builds simply continue
   main's numbering and cannot collide with it. It can only ever be raised,
   never lowered, so do not touch it for this branch.
6. Testers: an internal tester group only. External testing needs Beta App
   Review and is out of scope for this branch.

## Firebase prerequisites

Already done for this project; recorded so a fresh setup can repeat it.

- Firebase console → AI Services → AI Logic → Get started → choose the
  **Gemini Developer API** backend. This creates (or links) a Gemini API
  project behind the scenes.
- App Check is auto-enforced for AI Logic. That means **every** simulator or
  device install needs its App Check debug token registered: Firebase
  console → App Check → the iOS app → Manage debug tokens. A new simulator, a
  reset simulator, or a reinstall on a device is a new token.
- Recovering the token when you missed it: it is printed once in the
  simulator syslog —

  ```sh
  xcrun simctl spawn <udid> log show --last 15m --predicate 'eventMessage CONTAINS[c] "app check"'
  ```

  — or read it from the app container's preferences, where it is stored as
  `GACAppCheckDebugToken` in `Library/Preferences/com.keinstn.drover.plist`
  under the directory printed by

  ```sh
  xcrun simctl get_app_container <udid> com.keinstn.drover data
  ```

- Failure signature without a registered token: HTTP 403
  `App attestation failed` on the first AI Logic request.
- Billing: the Gemini API project that AI Logic created was in prepaid mode
  with zero credits. The Live WebSocket then closes with code 1011
  `Your prepayment credits are depleted`. Top up at
  <https://ai.studio/projects>.

## Development notes

- Use the **iOS simulator** for voice work: the Mac's microphone and speaker
  work there. A real iPhone on iOS 26.6.2 with Xcode 26.6 stalled —
  `xcodebuild -showBuildSettings` took over 60 s over wireless debugging and
  the LLDB launch sat on a white screen.
- `xcrun simctl privacy grant microphone com.keinstn.drover` pre-grants the
  microphone prompt, but it terminates the running app; restart `flutter
  run` afterwards.
- The simulator has no echo cancellation, so the model hears its own speech
  through the Mac speaker and interrupts itself. The app therefore mutes the
  microphone while the model is speaking (half-duplex) until echo
  cancellation is verified on a device. Wear headphones to test barge-in.
- Verified on Flutter with `firebase_ai` 4.0.0: the Live API works, including
  function calling, `sendTextRealtime`, input and output transcription, and
  `SpeechConfig(languageCode: 'ja-JP')`.
- Audio format: input PCM16 16 kHz mono, output PCM16 24 kHz.
- Model: `gemini-3.1-flash-live-preview` on the Developer API backend.
- Session limits: 15 minutes of audio, roughly 10 minutes per connection,
  unless context-window compression and session resumption are enabled. They
  are not enabled yet.

## Data boundary

The assistant is opt-in via a Settings toggle. Its tools return only agent
status and short assistant prose — never code, paths beyond the working
directory, or raw terminal output. This is a deliberate policy: drover is
otherwise SSH-local, and the voice path is the only place its data leaves the
device for a third-party model, so the surface sent there stays as small as
the feature allows.
