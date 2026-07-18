# Herdr CLI notes

Behaviours, constraints, and gotchas of the `herdr` CLI (and its socket API)
that drover depends on. This is a living reference — add new findings here as
dogfooding surfaces them, with the date and the herdr version they were
observed on.

Observed against **herdr 0.7.1** unless noted otherwise.

## Constraints

- `herdr api snapshot` is **not yet released** (docs/next only). Use
  `agent list` for the listing.
- There is no CLI wrapper for `agent prompt`. "Text + Enter" is sent as two
  calls: `agent send <target> <text>` followed by `pane send-keys <pane> enter`.

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
- **`pane send-keys <pane> shift+tab` does not cycle a Claude Code agent's
  mode.** (2026-07-18, herdr issue #1561) herdr encodes the `shift+tab` token
  as a plain Tab byte (0x09), identical to `tab` — not the backtab sequence
  Claude Code needs. Verified by capturing the bytes herdr writes to the PTY.
  **Workaround:** send the raw backtab escape sequence `ESC [ Z` (bytes
  `1b 5b 5a`) via `pane send-text` instead. Verified end-to-end: it cycles a
  live Claude Code agent's mode exactly like a physical shift+tab. The cycle
  order is: manual → accept edits → plan → auto → (back to manual). Caveat 1:
  `accept edits` and `auto` are two distinct positions in the cycle, but
  drover's `parseAgentMode` collapses both into `AgentMode.autoAccept` — a
  future "set to a specific mode" feature (read current mode, then cycle N
  times) would need those two distinguished. Caveat 2: `bypass` is not part
  of the shift+tab cycle (it's only reachable via
  `--dangerously-skip-permissions` at launch), so it cannot be reached by
  cycling.
- **The agent input channel is text-only — images go via SFTP + a path
  reference.** (2026-07-18) `agent send` / `pane send-text` / `pane send-keys`
  carry only text or key events; there is no attachment/image-injection
  command, and a terminal clipboard-image paste can't be synthesised over them.
  drover sends an image by SFTP-uploading it to the host (dartssh2
  `SftpClient`) into the target agent's cwd (`<cwd>/.drover/`), then sending the
  file's absolute path as an ordinary prompt. Verified end-to-end against a
  Claude Code agent: a spike placed an image with a known token/colour under the
  agent's cwd and sent the path — the agent read it with its Read tool and
  reported the token and colour back, confirming it saw the actual pixels.
  Keeping the upload inside the agent's cwd avoids Claude Code's
  out-of-workspace read permission prompt. Path-reading is **agent-specific**
  (this is Claude Code's behaviour; Codex/Copilot CLI etc. will need their own
  rule), so drover's image input is Claude-Code-only for now.

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
