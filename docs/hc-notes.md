# Herdr 2 (herdr-core / `hc`) notes

Herdr 2 is the Herdr desktop app ([herdr-app](https://github.com/herdrdev/herdr-app))
on top of [herdr-core](https://github.com/herdrdev/herdr-core), whose CLI is
`hc`. It is a different product from herdr 1 (the TUI, `herdr` CLI — see
`herdr-notes.md`): no workspaces/panes/agents verbs, no integrations, no
plugins. `HcClient` presents hc through `HerdrClient`'s API.

## One host, both backends

`HostConfig.backendMode` picks what drover talks to on a host: `herdr`
(herdr 1 only, a plain `HerdrClient`), `hc` (Herdr 2 only) or `auto`
(default: both). `buildHerdrClient` wraps the hc-only and auto cases in a
`CombinedHerdrClient`, which merges both backends' agent and workspace
lists and routes every per-id call by the id's prefix. Host-level calls
(plugins, SFTP, agent detection, `version`) go to herdr 1 when the host has
it. `herdrBin` is herdr 1's CLI and `hcBin` is Herdr 2's. A host saved before
`backendMode` existed with `backend: hc` loads as mode `hc`, its `herdrBin`
moving to `hcBin`. Any other legacy host loads as `auto`.

- Ids: every id `HcClient` hands out carries `hc:` (`hc:t16`, workspace
  `hc:sp…`, tab `hc:tb…`), and it strips the prefix again on the way in.
  An agent outside any space keeps workspace id `''`. herdr 1 ids
  (`w2H:p1`) are unchanged; `backendOfId` tells them apart.
- Core gate: `hc connect` starts a core when none is running, and auto mode
  must never do that. Auto mode's `HcClient(requireRunningCore: true)` runs
  `sh -c 'pgrep -x -U "$(id -u)" herdr-core … || { echo
  drover-hc-not-running >&2; exit 3; }; exec <hcBin> connect'`, so the check
  happens in the same exec as the connect. The marker becomes
  `HerdrException('hc_not_running')`. A Windows host fails the gate without
  running anything (`hc_unsupported_host`, treated like a missing binary),
  because Herdr 2 on Windows is deferred. Explicit `hc`
  mode is ungated.
- Absent backends: a backend is *absent* when its binary is missing
  (`isHerdrBinaryMissing`: exit 127, "not found", "No such file") or its
  core isn't running. A missing binary is skipped for 5 minutes while the
  other backend answers, then probed again. A core that isn't running is
  re-probed on every poll, since the gate is cheap. Opening the Herdr app
  shows its agents on the next poll, and the launch sheet offers Herdr 2.
  An absent backend is never offered by `availableBackends`.
- If every backend is absent, each poll probes again. hc's "not running" is
  thrown in preference to herdr 1's missing binary: Herdr 2 is installed,
  so the app being closed is the real cause. It renders as "the Herdr app
  isn't running" (`AppErrorKind.hcNotRunning`). With no hc part, or both
  binaries missing, herdr 1's error is thrown, so "herdr not found" still
  shows, also on a Windows host.
- Any other failure of one backend: the other backend's agents are still
  returned. `listAgentsReportingErrors()` returns the failure with its
  backend in `partialErrors`, as part of that call's result rather than
  client state, so concurrent listings can't clobber it. The herd poll uses
  it and shows each failure through `ErrorMessageView`, labelled "Herdr 1"
  or "Herdr 2". If both fail, a real error is thrown in preference to an
  absent one, and herdr 1's in preference to hc's.
- The gate needs a procps-style `pgrep -x -U`. Without pgrep, or with a
  BusyBox one that rejects `-U`, Auto treats hc as absent. Explicit Herdr 2
  mode is the workaround. A core that exits between pgrep and connect gets
  autostarted; the window is tiny but real.
- `displayId` strips `hc:` for labels that fall back to an id. Routing always
  keeps the prefix.

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
- Which agent CLIs report status (checked 2026-11-03, hc 0.1.17, each
  launched once in a throwaway terminal):

  | agent | reports? | `status.app` | notes |
  |---|---|---|---|
  | Claude Code | yes | `claude-code` (drover maps it to `claude`) | |
  | pi 1.3.0 | yes | `pi` | idle / blocked (`kind: question`, e.g. its MCP trust prompt) / done, `turn` advances; opt out with `PI_PROGRAM_STATUS=0` |
  | codex 0.166.0 | no | — | binary has no OSC 7501 support |
  | copilot 1.0.80 | no | — | answered a prompt, never reported |
  | omp | no | — | package has no OSC 7501 support |

  Herdr 2 has no counterpart to herdr 1's `herdr integration install`, by
  design (herdr-core only reads OSC 7501; herdr-app's `programs.json` is
  display metadata only). So codex/copilot/omp show up only when drover
  launched them (`drover.launched=1`), with status unknown; ones started from
  the Herdr app are invisible to drover. The only route to status for them
  would be an agent-side hook (Codex/Copilot hooks) writing OSC 7501 to its
  own terminal — not built.
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
