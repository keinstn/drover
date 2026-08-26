# pi agent notes

Behaviours of the **pi** CLI (https://pi.dev) that drover's pi adapter depends
on, as observed over herdr. For herdr's own behaviours (which apply to every
agent — workspace handling, the `shift+tab` encoding bug, the text-only input
channel, the `agent_session` mechanism), see `../herdr-notes.md`.

Observed against **pi 0.84.3** and **herdr integration hook v8** unless noted
otherwise.

## Native transcript source (`agent_session`)

- **pi reports its transcript as a path, not an id — the first `kind:'path'`
  agent in drover.** (2026-08-27) The general `agent_session` mechanism
  (integration hook required, only from the next `SessionStart`, fallback to
  pane-text history) is in `../herdr-notes.md`. For pi specifically:
  `herdr integration install pi` installs a TypeScript extension at
  `~/.pi/agent/extensions/herdr-agent-state.ts`, and `agent list`/`agent get`
  then report
  `{source:'herdr:pi', agent:'pi', kind:'path', value:'<absolute .jsonl path>'}`
  — e.g.
  `/Users/…/.pi/agent/sessions/--Users-administrator-Projects-ideas--/2026-08-26T10-10-04-319Z_01a03d8c-5d9f-742a-aa32-348af8eed560.jsonl`.
  claude, codex and copilot all report `kind:'id'` and have to locate the file
  themselves (a `find` under `~/.claude/projects` for Claude — see
  `claude-notes.md`; a deterministic path rebuilt from the id for Copilot —
  see `copilot-notes.md`). For pi the value **is** the file, so drover's loader
  does no remote lookup at all: it validates the path (absolute, no `..`
  segment, `.jsonl` suffix), probes once per session that it is readable, and
  reads it over SFTP. That probe stands in for the "not found" answer the
  other three get from their lookup command, so an unreadable path degrades to
  pane-text history instead of a retry banner. It does not distinguish "no such
  file" from a transport failure, so a dropped connection degrades the same
  silent way — the pane-text fallback shares that connection and still
  surfaces it. Because it never *resolves*
  a path, it also needs none of the `sh -lc` shell parameter expansion that
  Codex's `CODEX_HOME` and Copilot's `COPILOT_HOME` lookups had to document.

- **Session-file layout (background only).** (2026-08-27) Session files live at
  `${PI_CODING_AGENT_SESSION_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions}/<slugified-cwd>/<ISO-timestamp>_<uuid>.jsonl`,
  where `<slugified-cwd>` is e.g. `--Users-administrator-Projects-drover-main--`.
  drover never constructs this path — it is recorded here as context for a
  reader, not as something the adapter depends on.

## When the extension reports state

- **Only interactive TUI sessions report state.** (2026-08-27) The installed
  extension gates on `ctx?.mode !== "tui"`, so a headless run (`-p`,
  `--mode json`, `--mode rpc`) reports nothing and is invisible to herdr.
  Like every herdr integration, it also only takes effect for sessions started
  **after** the install (see `../herdr-notes.md`).

## Windows fallback (`kind:'id'`)

- **On a Windows herdr host, pi degrades to pane-text history.** (2026-08-27)
  The extension only reports the path when it passes
  `typeof file === "string" && file.startsWith("/")`. On a Windows host that
  guard fails and the extension falls back to reporting `agent_session_id`
  instead, i.e. `kind:'id'`. drover's pi loader supports `kind:'path'` only, so
  a pi pane on a Windows host falls back to the generic ANSI pane-text
  transcript. This is a known, deliberate phase-1 limitation, not a bug to
  chase.

## Transcript record types

- **Record shapes.** (2026-08-27, counts from ~3400 real records) Each line of
  the JSONL file is one JSON record. The top-level `type` values seen are
  `message` — the only one carrying user-visible content — plus `custom`
  (`customType:"web-search-results"`), `model_change`, `session` and
  `thinking_level_change`, all of which drover skips. A `message` record's
  `role` is one of `user`, `assistant`, `toolResult` or `bashExecution`.
  Content blocks are `{"type":"text","text":…}`,
  `{"type":"thinking","thinking":…}`,
  `{"type":"toolCall","id":"call_…","name":"bash","arguments":{…}}`, and —
  under a `toolResult` — also `{"type":"image",…}`.

- **`toolCall.arguments` is already a JSON object.** (2026-08-27) Unlike
  Codex's `function_call.arguments`, which is a JSON-*encoded string* (see
  `codex-notes.md`), pi's arguments arrive parsed. Do not re-decode them.

- **Tool results are their own top-level message.** (2026-08-27) A result is a
  record with `role:"toolResult"` carrying `toolCallId`, `toolName`, `content`
  and `isError` — it is *not* nested inside a user record the way Claude Code's
  `tool_result` block and Codex's `function_call_output` payload are. Pair a
  result to its call by `toolCallId`.

- **Iterate every content block.** (2026-08-27) One assistant message
  routinely carries several blocks, including **two `toolCall` blocks in a
  single message**. A parser that reads only the first block will silently drop
  tool calls.

- **`bashExecution` records are skipped.** (2026-08-27) `role:"bashExecution"`
  records (`{command, output}`) come from the TUI's `!` shell escape. drover
  does not render them today.

## Unsupported capabilities

- **Interaction mode: `AgentModeCapability` is null.** (2026-08-27) pi has no
  built-in cyclable mode; plan mode ships as a third-party extension (`--plan`
  from the plan-mode extension). There is no mode line to parse and nothing to
  cycle, so drover hides the mode control for pi rather than mapping anything.

- **Structured prompts: `StructuredPromptCapability` is null.** (2026-08-27) pi
  has a built-in `ask_question` tool (visible as `--exclude-tools ask_question`
  in `pi --help`), but neither its transcript record shape nor its TUI dialog
  has been captured live — both are **not verified**. AgentScreen's generic
  numbered-prompt pane-text fallback therefore applies, and a pending question
  is answered in the pane.

- **Image attachments: `ImageAttachmentCapability` is null.** (2026-08-27) pi
  takes file references as `@path` arguments; whether typing a literal
  `@/abs/path` into the TUI composer behaves the same way (rather than
  triggering its autocomplete) is **not verified**, so the composer's
  attach-image affordance is hidden for pi.

## Terminal title and avatar

- **pi's terminal title is its working directory, not a conversation
  summary.** (2026-08-27) pi sets its terminal title to `π - <directory name>`
  (observed: `π - ideas`). Claude Code and Copilot CLI both write a short
  summary of the current conversation there instead (see `copilot-notes.md`),
  so drover's `AgentInfo.sessionTitle` shows a directory name for a pi pane.
  Left as-is in this phase; a known rough edge.

- **pi's avatar initial is `π`, not `P`.** (2026-08-27) Copilot already claims
  `P` in drover's agent avatars, so pi uses `π` — matching the glyph pi itself
  puts in its terminal title.
