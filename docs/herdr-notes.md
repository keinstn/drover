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
- **`agent_session` requires the claude integration hook, and only from the
  next `SessionStart`.** (2026-07-20) `agent list`/`agent get` only include
  `agent_session` (the field drover's native transcript history, #39, keys
  off) when `terminal.hook_authority` has a `session_ref` — populated by the
  `claude` integration hook (`herdr integration install claude`) reporting the
  Claude session id on the `SessionStart` event. If that integration was never
  installed on the host, `agent_session` is always absent (no error — drover
  silently falls back to the pane-text history from #23, which is bounded by
  herdr's finite retained pane buffer). Installing the integration
  (`herdr integration status` shows per-agent install state) only affects
  **sessions started after the install** — a Claude Code process already
  running keeps the hook config it loaded at its own `SessionStart`, so an
  already-running agent needs a fresh session (restart, or a `/clear`/resume
  that re-fires `SessionStart`) before drover's native transcript history
  activates for it.
- **GitHub Copilot CLI's mode cycling and footer, live Copilot CLI 1.0.72.**
  (2026-07-21) With the composer focused, the raw backtab escape sequence
  `ESC [ Z` (same workaround as Claude Code above — `pane send-keys
  shift+tab` is equally broken for Copilot CLI and must not be used) cycles
  `interactive` (the default, no on-screen label) → `plan` → `autopilot` →
  back to `interactive`. The composer's footer comes in two forms, and both
  name `plan`/`autopilot` explicitly when active:
  - idle: `/ commands · ? help · tab next tab`, becoming
    `plan · / commands · ? help · tab next tab` or
    `autopilot · / commands · ? help · tab next tab`.
  - working: `◎ Working esc interrupt`, becoming
    `◉ Working - plan esc interrupt` or
    `Working - autopilot esc interrupt`.

  `interactive` shows neither word in either form. **Caveat:** raw backtab
  only cycles the mode while the composer is focused — if focus is on the
  top-nav instead (whose focused state shows `Session | Issues | Pull
  requests | Gists`), the same keystroke changes the nav selection instead,
  and neither footer form is on-screen at all. So drover's Copilot mode
  parser anchors on the idle footer's `commands`/`help`/`next tab` words or
  the working footer's `Working`/`interrupt` words together, rather than
  scanning for the bare words `plan`/`autopilot` anywhere in the pane, which
  could otherwise misfire on an unrelated nav label. Copilot's `autopilot` is
  mapped to the existing `AgentMode.autoAccept` (no new enum value); Copilot
  has no `bypass`-equivalent mode, so `AgentMode.bypass` stays Claude-only.
- **GitHub Copilot CLI parses `@path` as a native image attachment, live
  Copilot CLI 1.0.72 — but only some path forms.** (2026-07-21) Typing an
  `@path` mention in the composer is recognized as an image attachment and
  recorded in `user.message.attachments` — unlike Claude Code, which just
  reads a bare path off ordinary prompt text with no special mention syntax.
  However, a literal absolute-path mention (`@/abs/path with spaces/x.png`)
  is *not* parsed at all once the path contains a space. Because uploaded
  images live under the agent's own cwd, a *relative* mention
  (`@.drover/x.png`) resolves correctly regardless of whether the cwd itself
  contains spaces — both single- and multiple-space/newline-separated
  relative mentions produce the correct absolute path in
  `user.message.attachments`. drover's Copilot image capability reuses the
  same `<cwd>/.drover` upload-and-gitignore staging as Claude Code (avoids an
  out-of-workspace permission prompt) but prompts with `@.drover/<filename>`
  mentions, relative to cwd, rather than bare or absolute-path mentions; the
  upload helper's return value (and this capability's `send` return value)
  stay absolute paths for callers.
- **Answering a Claude Code `AskUserQuestion` TUI by key injection.**
  (2026-07-20) The prompt is a `tool_use` block named `AskUserQuestion` in the
  session JSONL (`input.questions[].{question, header, multiSelect,
  options[].{label, description}}`), with an `id`; it is *answered* once a later
  USER record carries a `tool_result` block whose `tool_use_id` matches (content
  = `Your questions have been answered: "Q"="…".`). So "pending" = the last
  `AskUserQuestion` tool_use with no matching `tool_result`. drover answers it by
  injecting keys — digits/custom text via `pane send-text`, Enter/arrows via
  `pane send-keys`. Options are numbered 1..N in order (option index *i* → digit
  *i+1*); the "Type something" custom row is digit *N+1*. Verified end-to-end
  against a live agent (two spikes):
  - **Single question, single-select, normal option:** the option digit submits
    the whole prompt *immediately* — the dialog closes, no Enter, no review.
  - **Single question, single-select, custom:** digit *N+1* (selects the row +
    enters edit mode), then `pane send-text <text>`, then `send-keys enter`.
  - **Single question, multi-select:** each option digit *toggles* its checkbox
    (dialog stays open); then `send-keys right` reaches a "Review your answers"
    screen (`1. Submit answers / 2. Cancel`); `pane send-text 1` commits.
    Multi-select also *lists* a "Type something" row, but drover does not offer
    custom text for multi-select (the sequence is unverified).
  - **Multiple questions in one call:** the dialog shows a tab bar
    `← [ ] Q1header [ ] Q2header ✔ Submit →`. Answer each tab in order; a
    single-select digit records and *auto-advances* to the next tab, a
    multi-select is advanced by `right`. After the last question you land on the
    Submit tab's review screen → `pane send-text 1`.
  Because the last-single-select-in-a-multi-question and custom-in-multi-question
  transitions were *not* spiked, drover's injector
  (`agents/claude/claude_askuser_submitter.dart`) is
  **read-driven**: after every keystroke it re-reads the pane and confirms the
  expected transition (a normalized substring match on the question text, since
  the pane wraps long questions; the open dialog is detected by its `Esc to
  cancel` footer — *not* by question-text presence, since after submit Claude
  echoes `User answered Claude's questions: … <question> → <answer>`, reprinting
  the text). It aborts (throws, no auto-Esc) on any unrecognized state rather
  than sending keys blindly.

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
