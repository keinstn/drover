---
name: screenshots
description: Capture drover's App Store screenshots — the 6.9" en and ja sets, shot from the shipped demo mode on an iOS simulator. Use when asked to take, redo, or refresh the store screenshots (e.g. "スクショを撮り直して", "recapture the App Store screenshots").
---

# App Store screenshots

The app-independent mechanics live in the portable **`flutter-ios-screenshots`**
skill — how to capture, the required pixel size, status bar and locale handling,
launching, and Flutter's gesture traps. Read that first. This file is only what
is specific to drover.

Two recipes wrap the simulator side: `just sim-prep <locale>` (boot, set the
device language, reboot, re-apply the status bar override) and
`just sim-shot <locale> <name>` (capture into
`site/public/screenshots/<locale>/<name>.png` and print its pixel size).

**Run them from the branch that owns the captures** — `feat/store-screenshots`,
worktree `../drover-screenshots`. `site/` does not exist on `main`, where
`sim-shot` would silently create it as an untracked tree that a `git clean`
throws away.

## The four shots, and why each earns its slot

Captured for both `en` and `ja`, in this order — the order is the point, the
first shot is what most viewers see:

| Name | Content | Why |
| --- | --- | --- |
| `01-hero-prompt` | the agent's permission prompt rendered as tappable buttons, with chat above it | Leads because it is the one screen that distinguishes drover from a mobile terminal. |
| `02-chat` | markdown prose plus a syntax-highlighted code fence | Shows the transcript is read as chat, not as scrollback. |
| `03-herd` | three agents in distinct states | The status pills only teach the vocabulary if they carry real counts. With one agent this screen is ~60% empty — that is why the demo ships three. |
| `04-setup` | the first-run screen with the demo entry | The honest "what you see on install" shot. |

## Source from the shipped demo, never from `lib/previews/`

The preview harness (`just preview …`) is for design judgement only. An earlier
set had one shot taken from it, and preview-only fixture data — a placeholder
workspace name, a hardcoded session title — went into a store asset. Store
assets must depict what ships. Run the real entrypoint and enter demo mode.

## Navigation

First-run setup screen (capture `04-setup` here) → tap `enter_demo_button` →
herd screen (`03-herd`) → tap the scripted agent's tile, titled
`Set up a demo file` / `デモ用のファイルを作る` → the agent view.

The agent view opens scrolled to the live terminal, so the chat starts
off-screen above. Treat the scroll as an intent, not a coordinate: bring the
chat into frame above the permission prompt, capture, then check the capture
itself and adjust. Scroll further up for the markdown-and-code shot. Do not
copy scroll offsets out of a previous run — the transcript content changed
twice during the original session and any hardcoded numbers went stale
immediately.

## Locale

Set the device language with `just sim-prep <locale>` **before launching**, and
enter the demo after the app comes up in that language. `_enterDemo` in
`app/lib/main.dart` binds the demo's content locale once, at the moment you tap
the demo entry (`DemoBackend(content: demoContentFor(locale))`). The in-app
language setting *is* reachable from demo mode, but switching there after
entering flips the UI chrome while leaving the whole transcript in the old
language — a mixed set that looks like a bug in the app.

The ja set legitimately mixes languages, and that is correct. The demo
localises what the **user** would have written — session titles, user turns,
assistant prose — and deliberately leaves in English what the **CLI emits**:
the permission prompt body, the live terminal, mode indicators, and code
identifiers. Do not "fix" the English in a ja capture.

## Where the navigation contract is enforced

`app/test/demo/demo_screen_test.dart` asserts the demo entry and the scripted
agent's render, including the three-agent status pills and the ja
mixed-language rule. If a future UI change moves either, that test is where it
surfaces — so if this skill's navigation path no longer matches the app, read
that test to see what actually changed. Don't add new tests for the capture
flow.
