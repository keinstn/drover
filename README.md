# Drover

Remote control for your Herdr agents — a Flutter app PoC for supervising
Herdr-managed AI agents from your phone.

Proposal: `~/Projects/ideas/drover.md` (feasibility, differentiation, the
moshi problem, push design)

## Repo layout

```
drover/
├── README.md    # this file
└── app/         # the Flutter project (fvm-pinned)
    ├── lib/      # app source (Stage 1+)
    └── tool/     # tool/spike.dart — Stage 0 spike
```

All `flutter`/`dart` commands run from `app/`.

## PoC plan (3 stages)

| Stage | What | Goal |
|---|---|---|
| **0. Spike** | `app/tool/spike.dart` (dartssh2 CLI) | Settle the 4 unknowns below with no UI |
| **1. Foreground MVP** | 3 screens: host setup / herd list / agent view | Dogfood on iPhone (foreground only, local notifications) |
| **2. Push** | Herdr plugin event hook → ntfy → APNs | Go/no-go decided after Stage 1 dogfooding |

**Dogfooding success metric (doubles as the kill criterion)**: over a week of
real work, count whether an agent going `blocked` makes you open **Drover
instead of moshi**.

## Stage 0 spike

Prerequisite: the target host has sshd enabled (on this Mac: System Settings
→ Sharing → Remote Login) and key-based auth working.

```bash
cd app

# List agents and their status
fvm dart run tool/spike.dart --host <mac-hostname>.local agents

# Raw output read (the most important measurement: the chat-formatting gap)
fvm dart run tool/spike.dart --host <host> read <pane|name> --lines 120

# Send text + Enter (can we answer y/n/1/2 permission prompts?)
fvm dart run tool/spike.dart --host <host> send <pane|name> "y"

# Long-poll a status change (a precursor to push-within-session)
fvm dart run tool/spike.dart --host <host> watch <pane|name> --status blocked

# Latency measurement (basis for a polling interval)
fvm dart run tool/spike.dart --host <host> bench 10
```

### The 4 unknowns this measures

1. How readable is `agent read`'s raw output? → decides Stage 1's display approach
2. Can `agent send` + Enter answer permission prompts? → the precondition for supervising
3. Connection/command latency → basis for a polling interval
4. Is `agent wait` usable as a long-poll? → whether polling can be reduced

### Known CLI constraints (installed herdr 0.7.1)

- `herdr api snapshot` is **not yet released** (docs/next only). Use
  `agent list` for the listing.
- There's no CLI wrapper for `agent prompt` either. "Text + Enter" is sent as
  two calls: `agent send` followed by `pane send-keys <pane> enter`.

### Results (2026-07-18, localhost loopback, herdr 0.7.1, Claude Code agent)

1. **Chat-formatting gap — better than expected.** Claude Code's raw output
   already carries turn markers: `❯ ...` for a sent user turn, `⏺ ...` for an
   assistant turn/action, `✻ Worked for Ns` as a meta/status footer, and a
   trailing `-- INSERT -- ⏵⏵ auto mode on...` mode line that's TUI chrome and
   should be stripped from any rendered view. A turn-splitting parser keyed on
   `❯`/`⏺` is enough for a first chat view. This is agent-specific — Codex,
   Copilot CLI, etc. will need their own parsing rules later, mirroring
   Herdr's own per-agent detection manifests.
2. **Permission prompts can be answered end-to-end.** Confirmed on a
   disposable pane: sent a task → `agent wait --status blocked` returned in
   **121ms** with the prompt text (`Do you want to proceed? ❯ 1. Yes / 2. Yes,
   always / 3. No`) → `agent send "1"` selected it → `agent wait --status
   idle` returned in **122ms** → the file the task asked for was actually
   created. Numbered/lettered prompts can be parsed from `read` output and
   rendered as tappable buttons instead of a raw text field.
   - **Caveat found**: a send immediately after `agent start` (during the
     splash screen) was silently dropped even though `agent_status` already
     read `idle`. Stage 1 should confirm the send landed (e.g. re-check pane
     content shortly after) rather than trust `idle` alone right after launch.
3. **Latency is comfortable.** `agent list` over loopback: 99–122ms
   (avg 103ms) across 8 runs. This is a **lower bound** — a real remote host
   over a mobile network will be higher and more variable — but it's enough
   headroom to support a 1–2s foreground poll interval.
4. **`agent wait` works as a long-poll**, returning in ~120ms on state change
   rather than only at timeout. Good precursor for reducing polling once
   Stage 2 push exists.

## Development

```bash
cd app
fvm flutter run -d macos    # fast iteration during development
fvm flutter run -d <iphone> # dogfooding on a real device (free Apple ID: signing expires after 7 days)
```
