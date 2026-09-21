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
- Pull `main` into `voice-live` about weekly, by rebasing: `git rebase
  origin/main`, then `git push --force-with-lease`. Back the branch up first
  (`git branch voice-live-prerebaseN origin/voice-live` and push it) — the
  rewrite is the whole point, so the backup is the only way back. Xcode Cloud
  resolves the branch by name and builds whatever the remote tip is, so a
  rewrite doesn't disturb it; keeping the history linear is what makes the
  eventual single `voice-live` → `main` PR readable. The cost is the usual
  one: anyone else holding the branch has to reset onto the new tip.
- When it is ready, open one PR `voice-live` → `main`, merge it, then run
  `just release 1.1.0` from `main` as usual.
- Re-decide the Settings toggle's default before that merge (2026-09-18): it
  ships **on** here, where builds only reach TestFlight internal testers. The
  per-session cost has never been measured and nothing meters it (see
  `docs/voice-billing.md`), so on-by-default on the App Store train is a
  separate decision from on-by-default on this branch.
- Versioning: `voice-live` carries marketing version `1.1.0`; `main` stays
  `1.0.x`. Apple closes a marketing version's pre-release train once it ships
  (ITMS-90186, see "Releasing" in `CLAUDE.md`), and a `1.0.x` build from this
  branch would either be rejected or, worse, end up in the shipped train.
  Keeping the branch one minor ahead avoids both.
- That rebase conflicts in at most two places, both in the commits that set
  the branch up (#226, #227):
  - `app/pubspec.yaml`'s `version:` line, whenever `main` released in between
    (its `just release` commits bump that line). Keep `1.1.0` and take
    `main`'s build number — the `+N` is cosmetic either way, since Xcode Cloud
    assigns build numbers from its own counter. `just voice-build` refuses to
    run if the marketing version equals `main`'s, so a botched resolution is
    caught before a build starts.
  - `app/pubspec.lock`, whenever a dependency bump landed on `main`. Never
    hand-merge it: take `main`'s side and regenerate. During a rebase `--ours`
    is `main`, not the branch — so `git checkout --ours app/pubspec.lock`,
    then `fvm flutter pub get` to add the voice packages back on top. Check
    the result with `fvm flutter pub outdated`: `firebase_ai` constrains
    `firebase_core`, so pub can silently downgrade packages `main` just
    upgraded. Direct and dev dependencies should still read "all up-to-date".
- Verify the rebased tip locally before pushing — `fvm flutter analyze`, the
  full `fvm flutter test`, and the `ci-ios-deps` steps by hand (`fvm flutter
  build ios --config-only --release --no-codesign`, then `xcodebuild
  -resolvePackageDependencies -workspace Runner.xcworkspace -scheme Runner`,
  then `git diff --exit-code` on both `Package.resolved` files). That workflow
  only triggers on `pull_request`, so a direct push to `voice-live` runs no
  CI for it at all: local is the only gate. A real `fvm flutter build ios
  --release --no-codesign` is worth the 100s too — it is the only check that
  covers the native packages (`record`, `flutter_soloud`) and the native-assets
  transitives, which a passing test suite and a resolution-only check both miss.

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
  through the Mac speaker and interrupts itself. A **debug build therefore
  mutes the microphone while the model is speaking** (half-duplex), and a
  release build does not — `voiceMicGateNeeded` in `voice_session.dart`. So
  barge-in (talking over the assistant to cut it off) works on TestFlight but
  not on the simulator; wear headphones to test it there. The build mode is a
  proxy for "is this the simulator": an iOS app gets an empty
  `Platform.environment` (measured 2026-09-13), so the app cannot detect the
  simulator without a new dependency or an FFI `sysctl` call, and here the
  simulator only ever runs debug builds while the device only gets release
  builds through TestFlight.
- A device's echo canceller is **adaptive**, and the model's first utterance
  plays right after the mic opens: on a real iPhone the model still heard
  itself for the first two or three turns of a session, then never again
  (measured 2026-09-13). A release build therefore keeps the gate on while
  the model speaks until roughly ten seconds of *model audio* have played —
  cumulative playback, not wall clock — and drops it afterwards, which gives
  the canceller the input it needs to converge and still leaves barge-in
  working for the rest of the session. The threshold is `kVoiceAecWarmUp` in
  `voice_session.dart`, a first guess meant to be tuned on device; the cost
  of raising it is that barge-in stays off for more of the first turns.
- Verified on Flutter with `firebase_ai` 4.0.0: the Live API works, including
  function calling, `sendTextRealtime`, input and output transcription, and
  `SpeechConfig(languageCode: 'ja-JP')`.
- Audio format: input PCM16 16 kHz mono, output PCM16 24 kHz.
- Model: `gemini-3.8-live` on the Developer API backend, since 2026-09-21.
  It replaced `gemini-3.1-flash-live-preview`, which Google now lists as the
  legacy preview model to migrate off; the two share a pricing row, so the
  move cost nothing. On the minted-token path `voiceModel` in
  `functions/src/index.ts` is what actually decides the model — the token's
  `fieldMask` freezes it and `kVoiceModel` is ignored — so a future model can
  be swapped server side without shipping a build. See
  [voice-billing.md](voice-billing.md).
- Session limits: the server caps a single Live connection at roughly ten
  minutes, but a drop no longer ends the conversation (2026-09-13). Every
  connect asks for session resumption and sliding-window context-window
  compression (`FirebaseVoiceTransport.connect`); the server then keeps
  handing out resumption handles, and when the socket drops `VoiceSession`
  reconnects once on the latest handle, logs a "Reconnected, continuing" line
  and keeps the mic and speaker up. The conversation carries on across
  connections.
- The app sets its own ceiling instead (2026-09-17): `kVoiceSessionCap` in
  `voice_session.dart`, five minutes of wall clock from `start()`, after which
  the session ends itself and logs why through the normal end path. Wall
  clock, not per connection — a cap that restarted with every reconnect would
  bound nothing, and an open mic streaming to a third party has to have an
  end. Only the user's End begins a fresh conversation on a fresh cap; a
  session that `background()` merely parked keeps the deadline it already had
  (see 2026-09-19 below). It just ends, with no warning beforehand; raise or lower
  the constant if five minutes turns out to cut real conversations short.
- The screen is held awake for as long as a session is open (2026-09-18;
  owner moved 2026-09-19, below). `ScreenWake`
  (`app/lib/src/infra/screen_wake.dart`) drives
  `UIApplication.isIdleTimerDisabled` over the `com.keinstn.drover/screen`
  method channel. `HerdScreen` — which owns the call — turns it on while the
  session is connecting or live and releases it on every end path, whether or
  not the voice screen is showing. Without it the device
  auto-locked mid-conversation — the user is talking, not touching the screen
  — and that alone broke the session: backgrounding interrupts the audio
  session, `record` defaults to `AudioInterruptionMode.pause` with no
  auto-resume, and nothing told `VoiceSession`, so it sat in `live` with no
  audio flowing and looked frozen. The call is best-effort, so macOS, which
  registers no such handler, silently no-ops.
- Leaving the app ends the session, logged as `backgroundedCode` (2026-09-18;
  since 2026-09-19 it parks the conversation rather than dropping it, see
  below). Keeping the screen awake does not cover a manual lock, an answered
  call or a notification tap that opens something else, and the half-dead
  state above is the worst possible outcome, so the app lifecycle is observed
  — by the herd screen and, while it is showing, the voice screen (2026-09-19,
  below) — and the session ended through the normal end path instead.
  Same reasoning as `kVoiceSessionCap`: an open mic streaming to a third
  party must not outlive the foreground. Only `AppLifecycleState.paused` ends
  it — `inactive` fires on a Control Centre glance or an app-switcher flick,
  the same `paused`-only choice `main.dart`'s own `didChangeAppLifecycleState`
  doc comment argues for.
- Still NOT handled (2026-09-18): an audio-session interruption that never
  backgrounds the app. Siri on iOS 14+ is a compact overlay, and a ringing or
  declined call is a banner; both stop at `inactive`, so `background()` never
  fires — yet both take the audio session, and `record`'s default
  `AudioInterruptionMode.pause` (the config in `voice_audio.dart` leaves it
  unset) stops the mic with no auto-resume and no signal to `VoiceSession`.
  That is the same half-dead state, still reachable. Ending on `inactive` is
  not the answer, because a Control Centre glance lands there too. The fix is
  to observe the interruption itself: `AudioRecorder.onStateChanged()` carries
  `RecordState.pause` out of the plugin's own interruption handler, which is
  also where resuming a session after a real call would hook in.
- A call now survives leaving the app, and is continued rather than restarted
  (2026-09-19). `VoiceSession.background()` parks the session — it closes the
  mic and the socket, logs `backgroundedCode`, and keeps the resumption
  handle. Coming back — re-entering the screen, or `AppLifecycleState.resumed`
  while the session is `resumable`
  — reconnects on that handle and logs the same "Reconnected, continuing" line
  a dropped connection does; to the user the two are the same event, because
  they are. The conversation is the thing kept, so what carried over carries
  over whole: the model's context, the accumulated usage totals, and the
  `kVoiceSessionCap` deadline, which is absolute — time spent away is spent,
  not given back, and coming back after it ran out ends the call with
  `capReachedCode` instead of dialling. Only the explicit End drops the
  conversation, and it does so deliberately: it clears the handle, so the next
  start is a genuinely fresh call on a fresh cap and a fresh usage total. An
  error does the same, because a handle the server refused would otherwise
  make Restart loop on it. Ownership moved with the behaviour: `HerdScreen`
  holds the session between visits and disposes it, `VoiceScreen` only drives
  the one it is handed. The retained session is dropped when it can no longer
  apply — the first host in scope changes (by id or revision: its tools talk
  to that host's client alone), the Settings toggle goes off, or the herd
  screen itself goes.
- The call stays live while the user moves around drover (2026-09-19, the
  second change that day). Leaving the voice screen does not touch the session
  at all: mic, socket and speaker keep running, and re-entering finds the same
  call on the same socket — no reconnect, nothing logged. Leaving the *app* is
  the only thing that closes the microphone, so `background()` is the single
  parking path; there is deliberately no second one keyed to the screen.
  - **The "we are listening" signal moved to the herd screen.** With the voice
    screen popped and the mic open, the OS indicator would otherwise be the
    only sign, so the voice FAB carries drover's own: while the session is
    `connecting` or `live` it wears the voice screen's listening ink
    (`voiceListeningInk`, `0xFF8FC0F2` dark / `0xFF388ADC` light — the same
    colour that screen's glow uses for a listening room) in place of
    `colorScheme.primary`, and an open microphone in place of the waveform,
    with `herdVoiceButtonLive` as its tooltip. Colour *and* glyph change, so
    the state survives greyscale and a screenshot. The pending-events badge
    still rides on top of it, and tapping the button re-enters the call.
  - **The screen wake follows the call, not the screen.** `_HerdScreenState`
    holds it and keys it on the same `_voiceOnTheWire`, attaching a listener
    when a session is built and dropping it in `_dropVoiceSession()`;
    `VoiceScreen` no longer knows about `ScreenWake` at all. It has to be this
    way round, or the feature guts itself: a wake released with the voice
    screen would start the idle timer on a call that is still going, the
    device would auto-lock about thirty seconds later, `paused` would fire and
    the call would end — exactly the user who steps back to the herd screen
    mid-conversation to look at their agents and keeps talking. It is released
    on every end path the session notifies, plus the two it cannot: the
    retained session being dropped or replaced, and the herd screen itself
    going.
  - **The lifecycle observer now lives in two places.** `_HerdScreenState` is
    a `WidgetsBindingObserver` as well and calls `background()` on the
    retained session on `paused`; `VoiceScreen` keeps its own for when it is
    showing. Both firing for one backgrounding is harmless — `background()`
    is a no-op unless the session is active — and with the voice screen
    popped the herd screen's is the only one left, without which a call would
    sit `live` on a microphone iOS has already killed. `resumed` was
    deliberately *not* copied over: re-opening the microphone stays in
    `VoiceScreen`, because that is the boundary the consent copy is written
    to. Foregrounding onto the herd screen must never re-open a mic by
    itself.
  - `_openVoice` reuses the retained session whenever it is still usable —
    `connecting`, `live`, `resumable`, or `parked` — not only when
    `resumable`, which would have disposed and replaced a live call
    mid-sentence on the way back in, and would have thrown away a park whose
    resumption handle a reconnect had consumed, buying a second credit for a
    call already paid for.
  - Still foreground-only: `UIBackgroundModes: audio` remains rejected (next
    bullet). What changed is which drover screen the user may be on, not
    whether drover has to be in front.
  - The consent sheet says so — "A call keeps listening while you use the rest
    of drover; leaving the app closes the microphone and stops sending, and
    returning to the conversation re-opens the microphone by itself…" — and
    `kVoiceConsentVersion` went to **2** with it. That is what the constant is
    for: version 1 promised the microphone closed when the voice screen was
    left, so everyone who accepted it is asked again rather than having the
    new behaviour start on an old yes.
  - **The composer's dictation button yields while a call is up.** With the
    call surviving the voice screen, this is two taps away: call → Back →
    an agent → the composer's mic. That mic drives `speech_to_text`, which
    puts `SFSpeechRecognizer`'s tap on the same `AVAudioSession` that
    `record`'s engine holds and `flutter_soloud` plays through. The expected
    loser is the call's microphone, with nothing to tell `VoiceSession`, which
    would sit `live` over a dead mic — the half-dead state above. So
    `HerdScreen` passes `canDictate: !_voiceOnTheWire` to `AgentScreen`, and
    the composer renders without the button at all — the same way a missing
    images capability hides attach. A flag rather than a withheld
    `SpeechInput`: null already means "build the shared controller", which is
    what demo mode and `lib/previews/` rely on, and re-plumbing who owns the
    speech plugin is not this change's business.
    The call wins because it is the one the user is in the middle of;
    dictation is one tap of a keyboard alternative. **Not verified on a
    device** — this is reasoning about a shared audio session, not a measured
    failure; if it turns out the two coexist, this is cheap to undo.
    Deliberate ceiling: the decision is made once, when the agent screen is
    pushed, so a call that ends while that screen is open leaves the mic
    missing until the user goes back and in again. A listenable that flips it
    live is only worth it if that annoys in use.
- `UIBackgroundModes: audio` was considered for this and rejected
  (2026-09-18). It would let the mic keep streaming from a locked phone in a
  pocket, which contradicts the data boundary below and the reasoning behind
  `kVoiceSessionCap`, and background audio in an app whose main job is not
  playback invites questions at review time — on the `1.1.0` submission this
  branch is heading for. Resuming a session interrupted by a real call is a
  separate feature: hold the resumption handle and reconnect on `resumed`.
- **The model is told which agent's screen the user is on** (2026-09-21).
  Until now an unnamed agent — "what is it waiting for?", "tell it to carry
  on" — had to be guessed from the last event or asked back about, even while
  the user was staring at the agent they meant. `AgentScreen` now reports
  itself through an `onVoiceFocus` callback, `HerdScreen` routes it to
  `VoiceSession.focusAgent` / `releaseFocus`, and the session injects a
  `[focus] The user is now looking at …'s screen.` line; the system prompt
  tells the model to resolve an unnamed agent to that one. It is a *hint*,
  not a binding: an agent the user names by name still wins.
  - It rides the same injected-text channel as the `[event]` announcements
    and shares their chain, so it waits out the model's estimated playback
    before it goes. Gemini Live treats injected text as a barge-in, and a
    hint landing mid-sentence would cut the model off just for walking to
    another screen. Everything is read at send time rather than captured
    when queued, so a run of switches says only where the user ended up, and
    a screen opened and left again while a hint waits out the playback
    cancels itself — nothing is sent, rather than two barge-ins that between
    them say nothing changed.
  - **What the model was told is tracked apart from where the user is**, and
    the session speaks only when the two disagree. A hint that never made it
    — the socket was gone mid-reconnect, the send threw — is not recorded as
    delivered, so it simply still disagrees at the next connect and goes out
    there. Without that split a reconnect, which the server's few-minute
    connection cap makes routine, would silently swallow a focus for good;
    worse, a swallowed *release* would leave the resumed conversation sure
    the user was still on a screen they had left, and the prompt tells the
    model to prefer that over asking. A `start` that opens a conversation
    the server is not restoring forgets what the last one was told, because
    the new one has been told nothing.
  - **Deliberately no transcript entry.** Focus is navigation, not
    conversation: a line in the log on every screen change would bury the
    conversation the hint exists to help. The tests assert this, so the
    silence is on purpose rather than an omission.
  - **The release is pane-guarded**, and the bottom switcher bar is why.
    `pushReplacement` builds the incoming agent screen before the outgoing
    one is disposed, so the release arrives *after* the focus the new screen
    just set; without the guard a bar switch would blank the focus it had
    just moved. `releaseFocus(paneId)` is a no-op unless that pane still
    holds the focus, and the screens keep the agent they reported so the
    release names the same pane the focus did. The ordering is the
    framework's, not something the screens work around.
  - **Only the voice host's agents are named.** A session's tools talk to one
    host's client (the one-host ceiling below), so an agent on any other host
    is a name the model could not read, message or act on. `HerdScreen`
    withholds the callback for anything but `_voiceHost`, and with no session
    there is no host and nothing is reported.
  - Ceilings. Marked `ponytail:` in the code: "told" is never confirmed, and
    the live config compacts the context window by dropping the oldest turns,
    so a focus injected early in a long call can fall out of the model's
    context while the session still records it as known; and a screen opened
    without an initial agent never reports at all, because there is nothing
    to name before the first `listAgents` resolves one (no caller does that
    today). Not marked, because it belongs to another path entirely: a
    **notification tap** opens its agent screen from `main.dart`, which pops
    to the root — firing the release for whatever was open — and pushes
    without the callback, so the model is left believing no screen is open
    while the user looks at the tapped agent. That path never had the voice
    session in reach; wiring it is issue #232. The failure is the safe one —
    the model falls back to asking or to the last event, rather than
    confidently naming the wrong agent.

## Voicemail and callback model

Talking to an agent is asynchronous, so the conversation is modelled on
voicemail: you leave the agent a message, and it "calls back" when it is done
or needs you.

- **Leaving a message.** The user says something like "tell claude to add
  tests too". Sending is two-step: the model calls `draft_message`, which
  stores the message in the session's `VoiceDrafts` and returns it with a
  `draft_id`; the model reads that text back word for word and asks for
  confirmation; after an explicit yes it calls `send_message(draft_id)`,
  which runs `herdr agent prompt` on the pane and marks the draft sent. The
  app, not the model's narration, is the source of truth: on device
  (2026-09-13) the model said "message sent" after the user's yes without
  ever calling the single-step `send_message`, and nothing reached the
  agent. Every draft shows on the voice screen as a card with the agent, the
  message and a **Send** button while it is pending, so the user can deliver
  it by hand if the model stalls; the card drops the button once sent and a
  "Sent to …" line is logged. Ending the session with a draft still pending
  logs an "unsent draft" notice, and Send still works after the session
  ended (it only needs the SSH client). The user can end the voice session
  while the agent works.
- **Callback.** HerdScreen's 2 s poll records status transitions per pane
  into a `VoiceInbox` (one per host): `working → idle|done` is a *finished*
  event, `* → blocked` a *blocked* event. A live `VoiceSession` drains the
  inbox and injects one text block into the conversation
  (`sendTextRealtime`), one paragraph per event, each starting with
  `[event]`; the system prompt tells the model to announce those immediately.
  Events that arrive while no session is open stay pending — the voice button
  shows a badge — and are announced as one block when the next session goes
  live.
- **Answering by voice.** A blocked event carries every question the agent is
  waiting on, each with its numbered options: a Claude `AskUserQuestion` from
  the native transcript when the agent has a `StructuredPromptCapability`,
  else a numbered prompt parsed from the pane text (permission dialogs, which
  are always a single question). The model reads each question out — a
  multi-question prompt numbers them "Question 1 of N", and a multi-select
  question says more than one choice is allowed — and asks them in order; the
  user picks numbers or answers freely; the model then calls
  `answer_question` **once**, with one `answers` entry per question in the
  order asked. That submits through the same capability the app uses, or
  types the digit / text into the pane. `AskUserQuestionSubmitter` validates
  the whole answer set before sending a single keystroke, so a mismatched or
  unkeyable set leaves the dialog untouched rather than half-answered.

The tools (`app/lib/src/voice/voice_tools.dart`) and what each sends
off-device:

| Tool | Sends to Gemini |
| --- | --- |
| `list_agents` | title, kind, status, project folder name per agent |
| `read_agent` | one agent's status and the text of its last reply |
| `draft_message` | `{draft_id, agent, message}` — echoes the message the model itself composed |
| `send_message` | `{sent: true, agent, message}` or an error; the draft stays pending on error |
| `draft_launch` | `{draft_id, kind, project, brief}` — echoes the brief the model itself composed |
| `launch` | `{launched: true, agent, project, brief_delivered}` or an error; the draft stays pending on error |
| `answer_question` | `{answered}` or an error string |

Callbacks are **foreground-only**: the event source is HerdScreen's poll, so
nothing is recorded while the app is backgrounded or another screen suspends
the poll. Background callbacks would need drover-notify to push `done` as
well as `blocked`; not done yet.

Ceilings, marked `ponytail:` in code:

- One host per voice session (the first host in scope).
- An option number past 9, or a custom-text row past 9, cannot be keyed
  safely (the TUI acts on the first digit), so the submitter refuses it and
  the prompt has to be answered in the app. Custom text on a multi-select
  question is refused too — that dialog has no "Type something" row.
- Announced replies are reduced to speakable prose (code fences become
  "(code omitted)") and cut at 600 characters.
- A resumption handle can be refused by the server (it expires, or the state
  is gone). The session then errors out and Restart starts a fresh
  conversation with no context — there is no retry ladder, one resume attempt
  per drop.

## Launching an agent by voice

The user brainstorms, then says "start an agent for this". Starting is the
same two-step draft as a message, for the same reason — only the app decides
that something happened:

1. The model writes the task as a **brief** for a coding agent, in the user's
   language, and calls `draft_launch(kind, project, brief)`. It then says in
   one sentence what the brief asks for, points at the card on screen, and
   waits for an explicit yes.
2. `launch(draft_id)` runs `VoiceHerd.launch`: `workspace create` (labelled
   with the folder name) → `agent start` → wait for the new pane to list as
   `idle` → `agent prompt` with the brief. A failed start closes the
   workspace again, exactly like the launch sheet, so nothing leaks.
3. The card carries the full brief and a **Launch** button, which works if
   the model never calls the tool and after the session ended (it only needs
   the SSH client), like the draft card's Send.

**Folder resolution.** Voice cannot dictate a path, so `project` is a folder
*name*, matched case-insensitively against the last path segment of the
working directories of the agents already running on the host — `foregroundCwd
?? cwd`, the same value `list_agents` names the project after and the launch
sheet offers, so a name the model spoke always resolves back. An unknown name,
or one shared by two different directories, is an error listing the available
folder names. Launching into a brand-new directory stays a screen-only feature
(the launch sheet).

**The dropped-send guard.** herdr can silently drop a prompt sent right after
`agent start`, even when the status already reads `idle`
(`docs/herdr-notes.md`). So the brief is sent, the pane is re-read, and if
the brief is not there it is sent once more. The check compares the head of
the brief with all whitespace removed against the ANSI-stripped pane, because
panes hard-wrap mid-word; a false negative costs one duplicated prompt, a
false positive costs the brief.

Ceilings, marked `ponytail:` in code:

- The wait for the new agent to read `idle` is bounded (~60 s, polled every
  1 s). On timeout the launch still counts as done but returns
  `brief_delivered: false` and no prompt is sent at all — the system prompt
  then has the model offer to deliver the brief with `draft_message`.
- The brief is re-sent at most once.
- While a delivery is in flight the draft is *busy*: the tool refuses a second
  `launch` (or `send_message`) and the card's button is greyed out, so the
  minute-long launch cannot be started twice into two workspaces. Busy is
  released on success and on failure alike.
- Only folder names of already-running agents can be named.

## Data boundary

Consent is taken before anything is sent (2026-09-17): the first tap on the
voice button opens a sheet naming Google and listing what crosses to it, and
only an accept builds the session — declining returns to the herd screen with
no microphone opened and no socket dialled. The answer persists as
`voice_consent_version` — the version of the disclosure that was accepted,
not a yes/no (2026-09-19) — so later taps go straight to the session only
while that version is still current. Bumping `kVoiceConsentVersion`, next to the
copy in `voice_consent_sheet.dart`, is what re-asks, and copy that describes
new behaviour has to bump it: this round's own change (leaving the app parks
the call, and returning re-opens the microphone with no tap of the user's)
would otherwise have run on a yes given to a sheet that said the opposite.
Installs from before carry the old `voice_consent_accepted` boolean, which
nothing reads any more, so they read as "not yet accepted" and are asked
again. The Settings toggle ships **on** (2026-09-18) and decides whether the
voice entry point and its on-device inbox are live at all: the sheet, not the
toggle, is the opt-in, and it gates every transmission, so a fresh install
still sends nothing until the user taps the voice button and accepts.
Switching the toggle off is the revoke — it clears the stored version, so
turning it back on asks again. The tools return only agent status and short
assistant prose. This is a deliberate policy: drover is otherwise SSH-local,
and the voice path is the only place its data leaves the device for a
third-party model, so
the surface sent there stays as small as the feature allows.

Concretely, what crosses to Gemini Live: the user's microphone audio, and the
transcripts Google makes of *both* sides of the conversation — `connect` asks
for `inputAudioTranscription` and `outputAudioTranscription`, so the model's
own speech is transcribed server side too, not only the user's. Then agent
status, session titles and kinds, project folder names, an agent's pending
question with its option labels, and the agent's last reply as prose
capped at 600 characters, with code — fenced or inline — replaced by "(code
omitted)" by `speakable`. Pane text is parsed on the device; only the
extracted question and options leave it. A tool that fails reports a coded
reason through `voiceToolError` rather than the exception's text
(2026-09-17): a `HerdrException`'s message is assembled from raw herdr
stdout/stderr, and an unrecognised failure is reduced to its type because an
SSH or socket error names hosts and ports.

What is deliberately **not** promised (2026-09-17): a path an agent typed
into ordinary prose is sent as written. `speakable` strips code, not paths,
and a blocked agent's question and option labels never go through it at all —
redacting the thing the user is being asked to choose between would make the
question unanswerable. A scrubber over prose is a heuristic that misfires on
ordinary sentences and that no test could keep honest, so the consent sheet
says this in as many words instead of reaching for an absolute. Announcements
are unprompted, too: an agent finishing sends its last reply with no user
utterance at all (`announceEvents`), which the consent copy also states.
