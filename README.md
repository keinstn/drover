# Drover

Drive your [Herdr](https://herdr.dev) AI agents from your phone — a Flutter app
(iOS/macOS) that turns Herdr-managed coding agents into something you can
supervise and steer on the go.

## Concept

Drover builds on Herdr to bring **AI-agent development to your phone**. The goal
is a genuine mobile agent-development experience — not a mobile terminal.

A terminal app like moshi can give you a shell on your machine, but it hands you
raw TUI chrome and a keyboard. Drover instead speaks the agent's language: it
renders a running agent's session as a readable chat, surfaces permission
prompts as tappable buttons, lets you switch modes and dictate follow-ups by
voice, and pings you the moment an agent needs you — the things a plain mobile
terminal can't offer.

## How it works

Drover connects to a Herdr host over SSH and drives the `herdr` CLI. There is no
server to run — your phone talks directly to the machine your agents live on.

- **See your herds and agents** with live status (idle / blocked / done).
- **Read the transcript as chat** — turn-split and colorized from the agent's
  raw output, with TUI chrome stripped.
- **Answer permission prompts as buttons** instead of typing into a raw pane.
- **Steer the agent** — cycle its mode, send follow-ups, and dictate by voice.

## Repo layout

```
drover/
├── app/       # the Flutter app (fvm-pinned; iOS/macOS)
│   ├── lib/   # app source
│   └── tool/  # tool/spike.dart — SSH/herdr CLI probe used during bring-up
└── docs/      # herdr-notes.md (herdr CLI behaviours & gotchas) + agents/ (per-agent CLI notes)
```

## Getting started

You need a Herdr host reachable over SSH with key-based auth (on macOS: System
Settings → Sharing → Remote Login). Install a herdr integration for each agent
you want native transcript history for — for example,
`herdr integration install claude`, `herdr integration install codex`, or
`herdr integration install copilot`. Without an integration, drover falls back
to pane-text history (bounded by herdr's retained pane buffer); the integration
must be installed before starting the session (it only takes effect from the
next `SessionStart`). Full setup and command reference live in
[`CLAUDE.md`](CLAUDE.md).

A `justfile` wraps the common recipes (`just` to list them):

```bash
just get                    # pub get
just check                  # analyze + test
just run -d macos           # fast iteration during development
just run -d <iphone>        # on a real device (free Apple ID: signing expires after 7 days)
just spike --host <host> agents   # probe a host from the CLI, no UI
```

## Firebase setup

Drover uses Firebase Authentication for an anonymous device identity. Before
running the app, register the iOS and macOS apps in Firebase and add their
respective `GoogleService-Info.plist` files to the Runner targets:

```text
app/ios/Runner/GoogleService-Info.plist
app/macos/Runner/GoogleService-Info.plist
```

Enable the Anonymous sign-in provider in Firebase Authentication. The plist
files are environment-specific and intentionally excluded from version control;
provide them locally and inject the appropriate file during Xcode builds.

Enable the Push Notifications capability for both Runner targets. The iOS
target also requires the Remote notifications Background Mode before handling
background notification data.

Firebase project aliases are also local-only. After cloning the repository,
select the target project with:

```bash
firebase use --add
```
