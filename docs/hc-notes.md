# Herdr 2 (herdr-core / `hc`) notes

Herdr 2 is the Herdr desktop app ([herdr-app](https://github.com/herdrdev/herdr-app))
on top of [herdr-core](https://github.com/herdrdev/herdr-core), whose CLI is
`hc`. It is a different product from herdr 1 (the TUI, `herdr` CLI — see
`herdr-notes.md`): no workspaces/panes/agents verbs, no integrations, no
plugins. A host picks one or the other in drover's host settings
(`HostConfig.backend`); `HcClient` presents hc through `HerdrClient`'s API.

Verified against hc 0.1.17 on 2026-11-03.

## Transport

drover pipes JSON-RPC 2.0 lines into `hc connect` over SSH
(`runWithStdin`), one request per line, and reads one reply line per
request. `hc connect` exits 0 at stdin EOF. Several requests batch into one
SSH exec (the agent poll sends `terminal.list` + `doc.get herdr-app`
together). Errors carry a stable `data.kind` (`blocked`, `not_found`,
`invalid_params`, …), which becomes `HerdrException.code`.

The CLI verbs (`hc ls --json`, …) are not used: `ls --json` omits labels
and titles, and `read`/`run` print text when piped.

## Agents and status

- core has no agent registry. An "agent" is a live terminal whose program
  reports status over OSC 7501; plain shells report none. Claude Code does
  this natively (`status.app = "claude-code"`).
- Words: `idle`, `working`, `done`, `blocked` (+ `kind`: permission /
  question / auth), `error`. `done` sticks until the program reports again,
  so drover applies the shared `herdr.seen=<turn>` label rule from
  herdr-app's `docs/labels.md` (done only while `turn > herdr.seen`) and
  writes `herdr.seen` while an agent is on screen (`markSeen`).
- Addresses with a `/` (`vps/t7`) are another machine's terminals mirrored
  into this core; drover skips them (it connects to that host directly).

## Spaces

Spaces/tabs belong to the desktop app, stored in core document `herdr-app`
(`doc.get`, API-only). A terminal joins a space through labels
`herdr.space=<id>` (+ optional `herdr.tab`; without it the app makes a new
tab). drover launches with `terminal.run` + those labels, so it can only
launch into an existing space — creating/renaming spaces would mean
writing the app's private document.

## Input

- `terminal.send` pastes text and presses Enter. It refuses a `blocked`
  terminal unless `force: true`; drover answers dialogs that way (a forced
  `"1"` approved a Claude permission dialog in testing).
- `terminal.keys` takes key names only: single `a-z`/`0-9`, `shift+<letter>`,
  `space`, the punctuation `` ` \ [ ] , = - . ' ; / ``, `enter`, `esc`, `tab`,
  arrows, `f1`–`f12`, modifiers. `shift+tab` cycles Claude Code's mode.
- There is no way to type arbitrary text without Enter (non-ASCII, `!`, …)
  short of a framed `terminal.attach` stream, which would also take over the
  terminal's size. `HcClient.sendPaneText` holds such text and pastes it
  (with Enter) on the `enter` that the structured-prompt submitters send
  next; any other call on that pane drops it. So Codex custom answers, whose
  submitter checks the typed text on screen before Enter, fail on Herdr 2
  without sending anything.
- `HcClient.prompt` forces only digit-only text (dialog option answers);
  other text to a blocked agent is refused with `blocked`.
- Agents drover launches carry `drover.launched=1`, so they stay listed
  (status unknown) even if they never report OSC 7501. They start through
  the user's login shell (`$SHELL -lic`) so the core's PATH doesn't matter.
- `terminal.read` returns plain text — no ANSI colors in the live terminal.
