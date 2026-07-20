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
- **Get pushed when it matters** — a Herdr plugin notifies your phone (via
  [ntfy](https://ntfy.sh)) when an agent goes `blocked` or `done`, so you don't
  have to keep the app open.

## Repo layout

```
drover/
├── app/       # the Flutter app (fvm-pinned; iOS/macOS)
│   ├── lib/   # app source
│   └── tool/  # tool/spike.dart — SSH/herdr CLI probe used during bring-up
├── plugin/    # Herdr → ntfy push-notification plugin
└── docs/      # herdr-notes.md — herdr CLI behaviours & gotchas drover relies on
```

## Getting started

You need a Herdr host reachable over SSH with key-based auth (on macOS: System
Settings → Sharing → Remote Login), with the `claude` Herdr integration
installed (`herdr integration install claude`) so full transcript history
works, plus Flutter via `fvm`. One-time host setup and the full command
reference live in [`CLAUDE.md`](CLAUDE.md).

A `justfile` wraps the common recipes (`just` to list them):

```bash
just get                    # pub get
just check                  # analyze + test + plugin tests
just run -d macos           # fast iteration during development
just run -d <iphone>        # on a real device (free Apple ID: signing expires after 7 days)
just spike --host <host> agents   # probe a host from the CLI, no UI
```

Push notifications are optional and set up separately — see
[`plugin/README.md`](plugin/README.md).
