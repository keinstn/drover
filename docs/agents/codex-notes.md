# OpenAI Codex CLI agent notes

Behaviours of the **OpenAI Codex CLI** that drover's Codex adapter depends on,
as observed over herdr. For herdr's own behaviours (which apply to every agent
— workspace handling, the `shift+tab` encoding bug, the text-only input
channel, the `agent_session` mechanism), see `../herdr-notes.md`.

Observed against **Codex CLI 0.144.6** and **herdr integration hook v6** unless
noted otherwise.

## Native transcript source (`agent_session`)

- **`agent_session` shape and transcript layout.** (2026-07-22) The general
  `agent_session` mechanism (integration hook required, only from the next
  `SessionStart`, fallback to pane-text history) is in `../herdr-notes.md`.
  For Codex specifically: `agent list`/`agent get` populate `agent_session`
  when the Codex herdr integration hook is installed (`herdr integration
  install codex`). The field's shape is
  `{source:'herdr:codex', agent:'codex', kind:'id', value:'<uuid>'}`.
  **Important:** The first Codex launch after adding the hook can display a
  Hooks review panel. The `~/.codex/herdr-agent-state.sh` hook must be
  explicitly trusted/enabled in that panel, then a **fresh** Codex session
  started. Only sessions started after that do report the session id via
  `agent get` — existing sessions do not acquire metadata retroactively.
  The session's transcript lives at
  `${CODEX_HOME:-$HOME/.codex}/sessions/YYYY/MM/DD/rollout-...-<uuid>.jsonl`.
  `CODEX_HOME` should be expanded via `sh -lc` (not a login-shell-specific
  expansion) for the same reason as Copilot's `COPILOT_HOME` — the SSH
  account may use fish or another shell that rejects POSIX parameter
  expansion syntax.

- **Transcript record types.** (2026-07-22) Each line of the JSONL file is one
  JSON record. Two top-level `type` values carry user-visible content:
  - `event_msg` — user/assistant display records. `payload.type` is
    `user_message` or `agent_message`; visible text is in
    `payload.message`. (Note: `payload.images`/`payload.local_images` exist
    but were empty in the live path-in-prompt probe — do not use them to infer
    native attachments for this delivery path.)
  - `response_item` — tool and assistant-message records.
    `payload.type` of `function_call` or `custom_tool_call` represents a
    tool call; the matching result is a `function_call_output` or
    `custom_tool_call_output` record sharing the same `payload.call_id`.
    `function_call` arguments are JSON strings; `custom_tool_call` input is
    a plain string. `response_item` records whose payload is an assistant
    message are **skipped** to avoid duplicating text that `event_msg`
    already carries. Encrypted reasoning items must never be rendered.

## Mode cycling

- **Mode cycling via raw backtab.** (2026-07-22, herdr issue #1561) `pane
  send-keys shift+tab` is broken for every agent (see `../herdr-notes.md`);
  drover cycles Codex's mode by sending the raw backtab escape sequence
  `ESC [ Z` (bytes `1b 5b 5a`) via `pane send-text`. Verified end-to-end
  against a live Codex agent. The cycle order observed is:
  normal → plan → (back to normal). The footer in normal mode reads
  `<model> <effort> · <cwd>`; plan mode shows
  `Plan mode (shift+tab to cycle)` in the footer. The verified raw-backtab
  cycle exposed only normal and plan; the adapter maps only those and does not
  infer additional modes.

## Image input

- **Codex has no native image attachment over herdr's text channel.**
  (2026-07-22) The herdr input channel carries only text/key events (see
  `../herdr-notes.md`). Codex's native `--image` flag and clipboard-image
  paste cannot be synthesised over it. However, placing a cwd-local image path
  in an ordinary text prompt lets Codex inspect the file — verified live: Codex
  used a tool to read the image, even though `event_msg`'s
  `images`/`local_images` fields remained empty. drover uploads the image via
  SFTP into `<cwd>/.drover/` (same staging area as Claude Code and Copilot CLI)
  and sends the **absolute path(s) as ordinary prompt text**, one per line.
  **Do not claim native attachment metadata** — `images`/`local_images` will
  always be empty for this delivery path.

## Structured questions (`request_user_input`)

- **Codex structured questions via `request_user_input`.** (2026-07-22) When
  Codex asks a structured question, a `response_item` record with
  `payload.type: 'function_call'` and `payload.name: 'request_user_input'`
  appears. Arguments (a JSON string) contain
  `{questions:[{id, header, question, options:[{label, description}]}]}`. The
  matching answer arrives as a `function_call_output` record sharing the same
  `payload.call_id`.
  "Pending" = the last `request_user_input` function_call with no matching
  `function_call_output`.

- **TUI dialog behaviour.** (2026-07-22) Multiple questions can appear in a
  single call; the TUI presents them sequentially. Each question is single-select.
  The first option is initially selected; the down-arrow moves one row; Enter
  records the selection and advances to the next question or submits if it was
  the last. A synthetic `None of the above` option is always present. Pressing
  Tab opens a notes field; entering custom text and pressing Enter produces
  output like `['None of the above', 'user_note: <text>']`.
  The footer and header provide safety signals during injection (e.g. current
  question index, active selection). **Do not inject keys blindly** — drover's
  submitter is read-driven: it re-reads the pane after every keystroke and
  confirms the expected transition before continuing, aborting (throws, no
  auto-Esc) on any unrecognized state.

## Prompt delivery

- **Generic prompt delivery works regardless of pane focus.** (2026-07-22)
  Unlike the Copilot CLI (which required a focus workaround), `agent prompt`
  (herdr 0.7.5+) delivers text to a Codex pane and submits it correctly even
  when the pane's `focused` field is `false`. No focus-recovery step is needed
  before sending a prompt to a Codex agent.
