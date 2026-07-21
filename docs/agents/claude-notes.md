# Claude Code agent notes

Behaviours of the **Claude Code** CLI that drover's Claude adapter depends on,
as observed over herdr. For herdr's own behaviours (which apply to every agent
— workspace handling, the `shift+tab` encoding bug, the text-only input
channel, the `agent_session` mechanism), see `../herdr-notes.md`.

## Mode cycling

- **Cycle order via the raw backtab workaround.** (2026-07-18, herdr issue
  #1561) `pane send-keys shift+tab` is broken for every agent (see
  `../herdr-notes.md`); drover cycles Claude Code's mode by sending the raw
  backtab escape sequence `ESC [ Z` (bytes `1b 5b 5a`) via `pane send-text`.
  Verified end-to-end against a live Claude Code agent: it cycles the mode
  exactly like a physical shift+tab. The cycle order is:
  manual → accept edits → plan → auto → (back to manual).
  - Caveat 1: `accept edits` and `auto` are two distinct positions in the
    cycle, but drover's `parseAgentMode` collapses both into
    `AgentMode.autoAccept` — a future "set to a specific mode" feature (read
    current mode, then cycle N times) would need those two distinguished.
  - Caveat 2: `bypass` is not part of the shift+tab cycle (it's only reachable
    via `--dangerously-skip-permissions` at launch), so it cannot be reached
    by cycling.

## Image input

- **Claude Code reads a bare path off ordinary prompt text.** (2026-07-18)
  Building on herdr's text-only input channel (see `../herdr-notes.md`),
  drover SFTP-uploads the image into `<cwd>/.drover/` and then sends the
  file's **absolute path as an ordinary prompt** — Claude Code needs no
  special mention syntax. Verified end-to-end: a spike placed an image with a
  known token/colour under the agent's cwd and sent the path — the agent read
  it with its Read tool and reported the token and colour back, confirming it
  saw the actual pixels. Keeping the upload inside the agent's cwd avoids
  Claude Code's out-of-workspace read permission prompt.

## Native transcript source (`agent_session`)

- **`agent_session` shape and transcript layout.** (2026-07-20) The general
  `agent_session` mechanism (integration hook required, only from the next
  `SessionStart`, fallback to pane-text history) is in `../herdr-notes.md`.
  For Claude Code specifically: `agent list`/`agent get` populate
  `agent_session` when `terminal.hook_authority` has a `session_ref`, set by
  the `claude` integration hook (`herdr integration install claude`) reporting
  the Claude session id on the `SessionStart` event. The field's `source` is
  the bare string `"claude"`. The session's transcript lives under
  `~/.claude/projects` in a per-project directory layout, so drover's loader
  must `find` the one file matching the session id anywhere under that tree
  (unlike Copilot's fully-deterministic path — see `copilot-notes.md`).

## Answering an `AskUserQuestion` TUI by key injection

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
