# Herdr CLI notes

Behaviours, constraints, and gotchas of the `herdr` CLI (and its socket API)
that drover depends on. This is a living reference — add new findings here as
dogfooding surfaces them, with the date and the herdr version they were
observed on.

Observed against **herdr 0.7.1** unless noted otherwise.

Notes that are specific to one agent CLI (mode cycling, transcript source,
image input, structured-prompt dialogs, …) live under `docs/agents/`:

- `docs/agents/claude-notes.md` — Claude Code specifics.
- `docs/agents/copilot-notes.md` — GitHub Copilot CLI specifics.
- `docs/agents/codex-notes.md` — OpenAI Codex CLI specifics.

This file covers only behaviours of herdr itself, which apply regardless of
which agent is running in the pane.

## Constraints

- `herdr api snapshot` is **not yet released** (docs/next only). Use
  `agent list` for the listing.
- `agent send` was removed in herdr 0.7.5, replaced by `agent prompt <target>
  <text>`, which types the text and submits it in a single atomic call.
  drover's `HerdrClient.prompt` uses `agent prompt` directly (no fallback, no
  version detection — herdr 0.7.5+ only).
- In herdr 0.7.5, `agent start` requires an existing shell pane:
  `agent start <name> --kind <kind> --pane <id>`. The former `--cwd`,
  `--workspace`, and `--no-focus` options are gone. Drover creates a workspace
  first for new launches and uses its `root_pane`; for an existing workspace,
  it splits a new shell pane before starting the agent.
- In herdr 0.7.5, `agent read --format ansi` prints raw terminal output rather
  than a JSON response envelope. Consumers must use stdout directly and pass
  its SGR escapes to their ANSI renderer.
- `agent wait --status` was renamed to `agent wait --until` in herdr 0.7.5.
- **An agent's `name` (from `agent rename`) is a slug, not a display title.**
  herdr validates it as `^[a-z][a-z0-9_-]{0,31}$` — must start with a lowercase
  letter and contain only lowercase letters, digits, `-` or `_`, 1–32 chars
  (`src/app/agents.rs:11-17`; error `invalid_agent_name`). It therefore cannot
  hold spaces, uppercase, or multibyte text (a Japanese/emoji name is rejected,
  verified live on 0.7.5). So drover must not treat `name` as a human-readable
  session title — for that, use `terminal_title_stripped` (see below).

## Behaviours / gotchas

- **`agent start` without `--workspace` hijacks the focused workspace.**
  (2026-07-18) A workspace-less `agent start` does *not* create a new
  workspace — it drops the new agent into whatever workspace is currently
  *focused on the host*, as an extra pane. Closing that workspace afterwards
  terminates whatever was running in it (including a Claude Code agent driving
  the session). drover therefore always passes an explicit `--workspace`:
  "new workspace" runs `workspace create` first (and rolls it back with
  `workspace close` if the launch then fails), "existing" uses the selected id.
  When probing manually, read `HERDR_WORKSPACE_ID` and never `workspace close`
  it — clean up test agents with `pane close <pane>` instead.
- **A send immediately after `agent start` can be silently dropped.**
  (2026-07-18) During the agent's splash/startup a send was lost even though
  `agent_status` already read `idle`. Confirm the send landed (re-check pane
  content shortly after) rather than trusting `idle` right after launch.
- **`integration status` is unreliable for "is this agent launchable".** It
  reports detection-hook install state, and an agent can be running while its
  integration reads "not installed". To decide what can be launched, probe the
  host PATH (`command -v <bin>`) instead.
- **`pane send-keys <pane> shift+tab` is broken — herdr writes a plain Tab
  byte.** (2026-07-18, herdr issue #1561) herdr encodes the `shift+tab` token
  as a plain Tab byte (0x09), identical to `tab` — not the backtab sequence
  agent TUIs need to cycle their mode. Verified by capturing the bytes herdr
  writes to the PTY. **Workaround:** send the raw backtab escape sequence
  `ESC [ Z` (bytes `1b 5b 5a`) via `pane send-text` instead. Verified
  end-to-end against Claude Code, Copilot CLI, and Codex CLI: it cycles a
  live agent's mode exactly like a physical shift+tab. `pane send-keys
  shift+tab` must not be used for any agent. The per-agent cycle order and
  how drover maps each position onto `AgentMode` are documented in the agent
  notes under `docs/agents/`.
- **The agent input channel is text-only — images go via SFTP + a path
  reference.** (2026-07-18) `agent send` / `pane send-text` / `pane send-keys`
  carry only text or key events; there is no attachment/image-injection
  command, and a terminal clipboard-image paste can't be synthesised over them.
  drover sends an image by SFTP-uploading it to the host (dartssh2
  `SftpClient`) into the target agent's cwd (`<cwd>/.drover/`), then referencing
  the uploaded file from an ordinary text prompt. *How* the path is referenced
  (a bare absolute path vs. an `@mention`) is **agent-specific** and lives in
  the agent notes under `docs/agents/`. Keeping the upload inside the agent's
  cwd avoids out-of-workspace read permission prompts.
- **`agent_session` requires the agent's integration hook, and only from the
  next `SessionStart`.** (2026-07-20) `agent list`/`agent get` only include
  `agent_session` — the field drover's native transcript history (#39) keys
  off — when the agent's herdr integration hook is installed on the host
  (`herdr integration install <agent>`; `herdr integration status` shows
  per-agent install state). If the integration was never installed,
  `agent_session` is always absent (no error — drover silently falls back to
  the pane-text history from #23, which is bounded by herdr's finite retained
  pane buffer). Installing the integration only affects **sessions started
  after the install** — an agent process already running keeps the hook config
  it loaded at its own `SessionStart`, so an already-running agent needs a
  fresh session (restart, or a `/clear`/resume that re-fires `SessionStart`)
  before native transcript history activates for it. Separately, the field can
  stay absent until after the session's *first* prompt even once the hook is
  installed — a pane with no session yet is a normal "not resolved yet" state,
  not an error. The concrete shape of `agent_session` (its `source`/`kind`/
  `value`) and where each agent's transcript file lives are agent-specific —
  see the agent notes under `docs/agents/`.
- **`terminal_title_stripped` is the agent CLI's own conversation title, and
  herdr strips only a leading activity glyph — never a trailing suffix.**
  (2026-07-22, herdr 0.7.5) `agent list`/`agent get` expose `terminal_title`
  (the raw OSC 0/2 window title the agent CLI itself sets — Claude/Codex/Copilot
  each write a short summary of the current conversation) and
  `terminal_title_stripped`. herdr captures the raw title unchanged apart from
  sanitising (UTF-8 lossy, drop control chars, 256-char cap;
  `src/pane/osc.rs`), and the *stripped* variant removes **only one leading
  activity/spinner glyph** — a Braille char `U+2800..=U+28FF` or one of
  `·✢✳✶✻✽` — followed by whitespace, then trims (`src/terminal/title.rs`). It
  does **not** strip any trailing app-name suffix. So Claude's idle `✳ ` prefix
  and every agent's Braille spinner are gone, but suffixes like Copilot's
  ` - GitHub Copilot`, Grok's ` - grok`, or Amp's ` - amp - ` remain. Because
  this value is CLI-maintained (drover never writes it) it tracks the live
  conversation and updates on resume/switch — unlike the manual `name` slug it
  never goes stale. drover uses `terminal_title_stripped` as the session title
  in the herd/agent screens and strips known CLI-specific suffixes client-side
  (see `AgentInfo.sessionTitle` / `stripAgentTitleSuffix`); the per-agent
  suffixes are noted under `docs/agents/`.
- **An error envelope's channel and exit code are not consistent across
  commands.** (2026-07-24, herdr 0.7.5) `agent start --pane <busy pane>` was
  observed returning `agent_pane_busy` with **exit 0, an empty stdout, and the
  JSON error envelope on stderr** — not the "non-zero exit, envelope on
  stdout" shape drover's client previously assumed everywhere. This broke
  `HerdrClient.startAgent`'s busy-pane retry (the error's `code` was never
  reached because the client only parsed stdout on exit 0). `HerdrClient._exec`
  now checks both stdout and stderr for a JSON error envelope regardless of
  exit code, so callers see the real `code` no matter which shape a given
  herdr command uses.

## Measurements (Stage 0, 2026-07-18, localhost loopback, Claude Code agent)

- `agent list` over loopback: 99–122ms (avg ~103ms) — a lower bound; a real
  remote host over a mobile network will be higher. Enough headroom for a 1–2s
  foreground poll.
- `agent wait` works as a long-poll, returning ~120ms on a state change rather
  than only at timeout.
- `agent read`'s raw output carries turn markers (`❯` user turn, `⏺` assistant
  turn/action, `✻ Worked for Ns` meta footer) plus a trailing `-- INSERT -- ...`
  mode line that is TUI chrome and should be stripped — enough for a turn-split
  chat view. Numbered/lettered permission prompts parse into tappable buttons,
  and an end-to-end answer (task → `blocked` → `send "1"` → `idle`) works.
