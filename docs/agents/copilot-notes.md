# GitHub Copilot CLI agent notes

Behaviours of the **GitHub Copilot CLI** that drover's Copilot adapter depends
on, as observed over herdr. For herdr's own behaviours (which apply to every
agent — workspace handling, the `shift+tab` encoding bug, the text-only input
channel, the `agent_session` mechanism), see `../herdr-notes.md`.

Observed against **Copilot CLI 1.0.72** and **herdr integration v2** unless
noted otherwise.

## Mode cycling and footer

- **Mode cycling and footer.** (2026-07-21) With the composer focused, the raw
  backtab escape sequence `ESC [ Z` (same workaround as Claude Code — `pane
  send-keys shift+tab` is equally broken for Copilot CLI and must not be used,
  see `../herdr-notes.md`) cycles `interactive` (the default, no on-screen
  label) → `plan` → `autopilot` → back to `interactive`. The composer's footer
  comes in two forms, and both name `plan`/`autopilot` explicitly when active:
  - idle: `/ commands · ? help · tab next tab`, becoming
    `plan · / commands · ? help · tab next tab`; autopilot instead shows
    `autopilot · / commands · tab next tab` (without `? help`).
  - working: `◎ Working esc interrupt`, becoming
    `◉ Working - plan esc interrupt` or
    `Working - autopilot esc interrupt`.

  On narrow panes, the idle footer can wrap across physical terminal lines;
  an update notice can also land between its `next` and `tab` words. Drover
  therefore recognizes the footer from its trailing area rather than requiring
  its chrome to remain on one line.

  `interactive` shows neither word in either form. **Caveat:** raw backtab
  only cycles the mode while the composer is focused — if focus is on the
  top-nav instead (whose focused state shows `Session | Issues | Pull
  requests | Gists`), the same keystroke changes the nav selection instead,
  and neither footer form is on-screen at all. So drover's Copilot mode
  parser anchors on the idle footer's `commands`/`next`/`tab` words, requiring
  `help` except for the autopilot-specific form, or the working footer's
  `Working`/`interrupt` words together, rather than
  scanning for the bare words `plan`/`autopilot` anywhere in the pane, which
  could otherwise misfire on an unrelated nav label. Copilot's `autopilot` is
  mapped to the existing `AgentMode.autoAccept` (no new enum value); Copilot
  has no `bypass`-equivalent mode, so `AgentMode.bypass` stays Claude-only.

## Image input

- **Copilot CLI parses `@path` as a native image attachment — but only some
  path forms.** (2026-07-21) Building on herdr's text-only input channel (see
  `../herdr-notes.md`), typing an `@path` mention in the composer is
  recognized as an image attachment and recorded in
  `user.message.attachments` — unlike Claude Code, which just reads a bare
  path off ordinary prompt text with no special mention syntax. However, a
  literal absolute-path mention (`@/abs/path with spaces/x.png`) is *not*
  parsed at all once the path contains a space. Because uploaded images live
  under the agent's own cwd, a *relative* mention (`@.drover/x.png`) resolves
  correctly regardless of whether the cwd itself contains spaces — both
  single- and multiple-space/newline-separated relative mentions produce the
  correct absolute path in `user.message.attachments`. drover's Copilot image
  capability reuses the same `<cwd>/.drover` upload-and-gitignore staging as
  Claude Code (avoids an out-of-workspace permission prompt) but prompts with
  `@.drover/<filename>` mentions, relative to cwd, rather than bare or
  absolute-path mentions; the upload helper's return value (and this
  capability's `send` return value) stay absolute paths for callers.

## Native transcript source (`agent_session` → `events.jsonl`)

- **Copilot's native transcript source is `events.jsonl` under a
  herdr-reported session id.** (2026-07-21) The general `agent_session`
  mechanism (integration hook required, only from the next `SessionStart`,
  fallback to pane-text history) is in `../herdr-notes.md`. For Copilot
  specifically: `agent list`/`agent get`'s `agent_session` for a Copilot pane
  reports `{source:"herdr:copilot", agent:"copilot", kind:"id",
  value:"<uuid>"}` — note the `source` is namespaced `herdr:copilot` (unlike
  Claude's bare `"claude"`), which drover's `CopilotTranscriptLoader`
  deliberately does not gate on (only `agent`/`kind`/`value` are checked,
  matching the Claude adapter's existing precedent of ignoring `source`).
  Like Claude's `agent_session`, this field can be absent until after the
  session's first prompt/`SessionStart`-equivalent hook fires — a pane with
  no session yet is a normal "not resolved yet" state, not an error. The
  session's transcript lives at
  `${COPILOT_HOME:-$HOME/.copilot}/session-state/<uuid>/events.jsonl`; unlike
  Claude Code's per-project directory layout (which needs a `find` to locate
  the one file matching a session id anywhere under `~/.claude/projects`),
  Copilot's path is fully deterministic from the id alone, so drover's loader
  does a direct existence check of that one candidate path (honoring
  `COPILOT_HOME` via shell parameter expansion) instead of a broader
  traversal. The file may not exist yet even once the session id is known
  (before the session's first turn) — this is the normal "no transcript yet"
  case (falls back to pane-text history), not a genuine read failure.
  `session.db` in the same session-state directory is Copilot CLI's own
  internal state store, not transcript storage, and drover never reads it.
  The lookup command is run through `sh -lc`, rather than the SSH account's
  login shell, because valid hosts can use fish, which rejects the POSIX
  variable assignment and parameter expansion needed to resolve `COPILOT_HOME`.
  Each line of `events.jsonl` is one JSON event
  `{type, data, id, timestamp, parentId, agentId?}`. Only four `type`s carry
  user-visible content: `user.message` (`data.content`, plus an
  `attachments` array drover's parser does not render, to avoid exposing
  local binary data), `assistant.message` (`data.content` together with
  `data.phase` — visible only when `phase` is `final_answer` or
  `commentary`; the intermediate `phase: null` step can have empty content
  or opaque/encrypted reasoning and is never rendered, matching the "no
  plaintext reasoning" constraint), `tool.execution_start`
  (`data.{toolCallId, toolName, arguments}`), and `tool.execution_complete`
  (`data.{toolCallId, success, result:{content, detailedContent}}`, paired
  to its start by `toolCallId`). Every other `type` (hook/session-lifecycle/
  usage events, etc.) is noise the parser skips. Tool events are mapped onto
  the same `TranscriptToolUse`/`TranscriptToolResult` shapes Claude Code's
  parser already produces (not Copilot-specific types), so a later ask_user
  detector can work across agents without new plumbing.

## The `ask_user` tool and TUI dialog

- **Copilot CLI's `ask_user` tool and TUI dialog.** (2026-07-21) The prompt is
  a `tool.execution_start` event with `toolName: 'ask_user'` and
  `data.arguments.{question:String, choices?:List<String>}`, keyed by
  `toolCallId`; it is *answered* once a later `tool.execution_complete` event's
  `toolCallId` matches — so "pending" = the last `ask_user` tool_use with no
  matching `tool.execution_complete`, the same pattern as Claude Code's
  `AskUserQuestion`. Unlike Claude Code, exactly **one single-select question**
  is ever carried per call — there is no multi-question/multi-select schema, so
  drover's `CopilotStructuredPromptCapability` always maps it to a single
  `multiSelect: false` `StructuredPromptQuestion`; a `choices` entry that
  isn't a string is skipped rather than invalidating the whole call, and a
  missing/blank `question` makes the whole tool_use unparseable (returns
  null), matching Claude's AskUserQuestion parser's safety precedent. The
  live TUI dialog has two shapes:
  - **With `choices`:** numbered options `1..N` plus a trailing
    `N+1. Other (type your answer)` row, header `Question` above the full
    question text, footer `↑/↓ to select · enter to confirm · esc to
    cancel`. Sending a normal option's digit alone **confirms and closes the
    dialog immediately** — no Enter, no review step (like Claude's lone
    single-select case). Selecting "Other" (digit `N+1`) replaces that
    numbered row with a `Type your answer:` edit field (capital `T`, unlike
    the lowercase `(type your answer)` inside the row's own label) without
    closing the dialog; typing the answer and sending `enter` commits it and
    closes the dialog. The edit field's own footer text was not spiked live,
    so drover's submitter (`agents/copilot/copilot_askuser_submitter.dart`)
    does not assert a specific edit-mode footer string. It also cannot rely
    on "same question still showing, dialog not closed" alone, since that
    also holds on the unmodified original screen if the digit silently
    no-ops; instead it requires the live-observed `Type your answer`
    placeholder itself as positive evidence (text that cannot appear on the
    original numbered-choices screen) before typing, with the numbered
    "Other" row's disappearance as corroborating (not sole) evidence.
  - **Without `choices`:** a plain freeform text box, footer `enter to
    submit · esc to cancel`. Typing the answer and sending `enter` submits
    and closes.
  Because the question dialog re-uses generic single-select machinery,
  drover's parser maps the no-choices case to a `StructuredPromptQuestion`
  with an **empty `options` list** rather than inventing a synthetic option
  — `StructuredPromptSheet`'s existing customText field (used for Claude's
  "Type something" answers) already renders as a bare free-text box when
  there are no options to list, so no sheet changes were needed. As with
  Claude's dialog, the pane wraps long questions at terminal width, so
  drover's confirmation matching whitespace-normalizes both sides. Closure is
  detected by the `Question` header and both known footers being *absent* —
  not by the question text being gone, since Copilot's scrollback echoes a
  `● Asked user` summary line that reprints the question text after it
  closes (the same reasoning as Claude's `Esc to cancel`-chrome check).
  Digits are capped at single-digit option/row numbers (index ≤ 8, so option
  count ≤ 9) for the same reason as Claude's submitter: a two-digit send
  would have its first digit acted on immediately by the TUI. The submitter
  is read-driven like Claude's: it re-reads the pane after every keystroke
  and aborts (throws `CopilotAskUserSubmitError`, never sends Esc) on any
  unrecognized state rather than guessing.

## Scrollbar glyph strands a floating `|` in wrapped pane text

(Copilot-specific; no Claude Code counterpart.)

- **Copilot CLI's scrollbar strands a floating `|` when drover wraps the pane
  text.** (Copilot CLI 1.0.73) Copilot CLI draws a scrollbar as a `┃`
  (U+2503) glyph at one fixed display-cell column on **every** history-viewport
  row (reverse-video for the thumb, plain for the track) — not a per-message
  panel border. Verified against a live pane via `herdr agent read <target>
  --source recent --format ansi`: every row shared the same cell column while
  CJK rows reached it at different rune offsets. When drover soft-wraps those
  padded rows at phone width, the scrollbar glyph lands on its own wrapped
  line, appearing as a lone `|` detached from its content. **Fix:** turn the
  scrollbar off in Copilot CLI itself — run its `/config` slash command and
  toggle **scrollbar** off (persisted as `"scrollbar": false` in
  `~/.copilot/settings.json`). With the column no longer drawn, the pane text
  drover reads has no trailing border to strand and transcripts wrap cleanly;
  no drover-side rendering workaround is needed. Confirmed on an iPhone
  simulator against a live Copilot pane. (General lesson: probe the agent
  CLI's own settings for a source-side fix before building a rendering-side
  workaround.)
