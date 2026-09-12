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
- Session limits: the server caps a single Live connection at roughly ten
  minutes, but the app no longer ends there (2026-09-13). Every connect asks
  for session resumption and sliding-window context-window compression
  (`FirebaseVoiceTransport.connect`); the server then keeps handing out
  resumption handles, and when the socket drops `VoiceSession` reconnects
  once on the latest handle, logs a "Reconnected, continuing" line and keeps
  the mic and speaker up. The conversation carries on across connections.

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
  Events that arrive while no session is open stay pending — the mic button
  shows a badge — and are announced as one block when the next session goes
  live.
- **Answering by voice.** A blocked event carries the agent's pending
  question and its options, numbered: a Claude `AskUserQuestion` from the
  native transcript when the agent has a `StructuredPromptCapability`, else a
  numbered prompt parsed from the pane text (permission dialogs). The model
  reads the options out; the user picks a number or answers freely; the
  model calls `answer_question`, which submits through the same capability
  the app uses, or types the digit / text into the pane.

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
- A multi-question structured prompt is announced (first question only) but
  must be answered in the app; `answer_question` refuses it.
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

The assistant is opt-in via a Settings toggle. Its tools return only agent
status and short assistant prose — never code, paths beyond the working
directory, or raw terminal output. This is a deliberate policy: drover is
otherwise SSH-local, and the voice path is the only place its data leaves the
device for a third-party model, so the surface sent there stays as small as
the feature allows.

Concretely, what crosses to Gemini Live: agent status, session titles and
kinds, project folder names, the user's own spoken message, an agent's
pending question with its option labels, and the agent's last reply as prose
with code blocks omitted and capped at 600 characters. Pane text is parsed on
the device; only the extracted question and options leave it.
