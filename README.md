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
├── functions/ # Firebase Functions notification backend
└── docs/      # herdr-notes.md (herdr CLI behaviours & gotchas) + agents/ (per-agent CLI notes)
```

The Herdr notification plugin (`drover.notify`) that used to live under
`plugins/` now lives in its own repo,
[`keinstn/drover-notify`](https://github.com/keinstn/drover-notify).

## Getting started

You need a Herdr host reachable over SSH with key-based auth (on macOS: System
Settings → Sharing → Remote Login; on Windows: install the OpenSSH Server
feature — and note that for an **administrator** account the public key must go
in `C:\ProgramData\ssh\administrators_authorized_keys`, not
`~\.ssh\authorized_keys`, or the connection fails with "All authentication
methods failed"). Install a herdr integration for each agent
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

## Firebase and notifications

Drover uses Firebase Authentication, Cloud Firestore, Cloud Functions, Cloud
Messaging, and App Check. Set up a deployment environment with
[`docs/firebase-setup.md`](docs/firebase-setup.md). That guide intentionally
uses placeholders and documents which configuration and credentials must remain
outside Git.

To link and pair the manually installed `drover.notify` Herdr plugin (from the
separate `keinstn/drover-notify` repo) for `blocked` notifications, see
[`docs/push-notifications.md`](docs/push-notifications.md).

## License

MIT — see [`LICENSE`](LICENSE).
