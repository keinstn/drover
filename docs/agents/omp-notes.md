# omp agent notes

Behaviours of the **omp** CLI ("Oh My Pi", the successor/rebrand of `pi`) that
drover's omp adapter depends on, as observed over herdr. For herdr's own
behaviours (which apply to every agent — workspace handling, the `shift+tab`
encoding bug, the text-only input channel, the `agent_session` mechanism), see
`../herdr-notes.md`.

Observed against **omp v18.1.11** and **herdr integration omp v8** unless noted
otherwise.

omp's adapter reuses pi's transcript parser and loader
(`app/lib/src/agents/pi/pi_transcript.dart`, parameterized by agent name), so
this file deliberately does **not** re-derive pi's observations. Where omp is
identical it cross-references `pi-notes.md`; what follows are the differences
and the newly verified facts. omp's help text still names its environment as
`PI_*` (`PI_CODING_AGENT_DIR` — "Session storage directory (default:
`~/.omp/agent`)", `PI_SMOL_MODEL`, `PI_SLOW_MODEL`, `PI_PLAN_MODEL`,
`PI_NO_PTY`), plus `OMP_PROFILE`.

## Native transcript source (`agent_session`)

- **omp reports its transcript as a path, like pi and unlike claude, codex
  and copilot.** (2026-09-06) The general `agent_session` mechanism (integration
  required, only from the next `SessionStart`, fallback to pane-text history)
  is in `../herdr-notes.md`; the `kind:'path'` consequences — no remote
  lookup, path validation plus a once-per-session SFTP readability probe, and
  the silent degrade to pane-text history when that probe fails — are in
  `pi-notes.md` and hold unchanged for omp. Live from
  `herdr agent start ompprobe --kind omp`:

  ```
  {source:'herdr:omp', agent:'omp', kind:'path',
   value:'/Users/administrator/.omp/agent/sessions/-Projects-drover-main/2026-09-06T08-53-01-667Z_01a075eb-c863-74fc-85a7-2158948439fb.jsonl'}
  ```

- **The integration installs under a different filename from pi's, so the two
  coexist.** (2026-09-06) `herdr integration install omp` writes a TypeScript
  extension to `~/.omp/agent/extensions/herdr-omp-agent-state.ts`, where pi's
  lives at `~/.pi/agent/extensions/herdr-agent-state.ts`. Installing one does
  not disturb the other. Like every herdr integration it only takes effect for
  sessions started **after** the install — see `../herdr-notes.md`.

- **Session-file layout (background only).** (2026-09-06) Session files live at
  `${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/sessions/<slugified-cwd>/<ISO-timestamp>_<uuid>.jsonl`.
  The slug rule differs from pi's: omp produced `-Projects-drover-main` where
  pi produced `--Users-administrator-Projects-drover-main--` for the same
  directory. drover never constructs this path — herdr reports it — but it is
  recorded here so nobody reuses pi's slug rule for omp.

## Windows divergence: a path drover declines

- **On a Windows herdr host omp *does* report `kind:'path'`, and drover
  rejects it.** (2026-09-06) pi's extension only reports a path when it passes
  `file.startsWith("/")`, so on a Windows host pi silently degrades to
  reporting a session id (`kind:'id'`) — see pi-notes' "Windows fallback
  (`kind:'id'`)". omp's v8 extension instead uses `isAbsoluteSessionPath()` =
  `path.posix.isAbsolute(file) || path.win32.isAbsolute(file)`, so a Windows
  host yields `kind:'path'` with a `C:\…` value. drover's
  `_isSafeTranscriptPath` requires a leading `/`, so it declines that value and
  the pane falls back to the generic ANSI pane-text transcript. The phase-1
  outcome matches pi's, but the **reason is the opposite**: pi never offers a
  path on Windows; omp offers one drover refuses. drover has shipped Windows-
  host support, so this path is reachable rather than hypothetical. Known,
  deliberate limitation, not a bug to chase; the upgrade path is to accept a
  Windows-absolute path in the validator.

## Transcript record types

- **Record shapes are identical to pi's.** (2026-09-06) `type:'message'`
  records with `message.role` in `user`/`assistant`/`toolResult`/
  `bashExecution`; content blocks `{type:'text'}`, `{type:'thinking'}`,
  `{type:'toolCall', id, name, arguments}`; a tool result is its own top-level
  record carrying `toolCallId`/`toolName`/`isError`/`content`, paired to its
  call by `toolCallId`. See `pi-notes.md` for the block-by-block detail,
  including the "iterate every content block" warning — it applies unchanged.

- **`toolCall.arguments` is already a decoded JSON object.** (2026-09-06) Same
  as pi, and unlike Codex's JSON-*encoded* string (see `codex-notes.md`). Do
  not re-decode.

- **New non-`message` top-level types beyond pi's set.** (2026-09-06) Observed
  in omp session files: `title`, `title_change`, `custom_message` (seen with
  `customType:'xdev-mount-notice'`), and `custom` with `customType` of
  `tool_execution_start` and `session_exit`. All are skipped by the parser's
  existing "top-level `type` is not `message`" guard, so no parser change was
  needed — recorded here so that guard's coverage is visible rather than
  accidental.

- **`toolCallId` is long and contains a `|`.** (2026-09-06) Real example,
  truncated:
  `call_CDXPvNPA1U69hZtEFTn5UoJR|y+sSKRvAXV0DDruBd8sDCuDVacPSg9kbIpsu/ionw…`
  — several hundred characters, apparently a provider reasoning payload
  appended after the pipe. Harmless as an opaque pairing key, but do not assume
  a short id.

## Unsupported capabilities

All three stay null on the omp adapter, as for pi — but partly for different
reasons.

- **Interaction mode: `AgentModeCapability` is null.** (2026-09-06) A
  `shift+tab` keystroke in a live omp pane cycles the **thinking level**, not
  an interaction mode — corroborated independently by the
  `thinking_level_change` records the same actions wrote to the session file.
  omp does have approval modes (`--approval-mode always-ask|write|yolo`), but
  they are a launch flag, not a status-line mode drover can read or cycle, and
  omp's status bar carries no mode line to parse. So there is nothing to map.

- **Structured prompts: `StructuredPromptCapability` is null — and unlike pi,
  this one is verified.** (2026-09-06) omp ships an `ask` tool enabled by
  default (a different tool from pi's `ask_question`, whose record shape and
  dialog remain unverified — see `pi-notes.md`). Prompting a live pane to use
  it produced an assistant `toolCall` named `ask` with arguments shaped like:

  ```json
  {"i":"Asking color preference","questions":[{"id":"color_preference","question":"Which color do you prefer?","options":[{"label":"Red","description":null,"preview":null}],"header":null,"multi":null,"recommended":null}]}
  ```

  and a TUI dialog whose footer reads
  `Enter select · n note · ↑/↓ move · Esc cancel`. The options are **not
  numbered** — selection is by arrow keys. AgentScreen's generic pane-text
  fallback parses *numbered* prompts, so it does not detect an omp `ask`: the
  pane goes `blocked` and the question has to be answered with arrow keys in
  the live terminal. Known limitation, not a bug to chase; a real
  `StructuredPromptCapability` for omp is separate work.

- **Image attachments: `ImageAttachmentCapability` is null.** (2026-09-06) omp
  takes file references as `@path` arguments (`omp @prompt.md @image.png "…"`);
  whether typing a literal `@/abs/path` into the TUI composer behaves the same
  way rather than triggering its autocomplete is **not verified**, so the
  composer's attach-image affordance is hidden for omp.

## Terminal title and avatar

- **omp's terminal title IS a conversation summary — unlike pi's.**
  (2026-09-06) pi sets `π - <directory name>` (see `pi-notes.md`); omp sets
  `π > <summary>`. Verified: a fresh pane showed `π > main`, and after one
  prompt it became `π > Reply exactly hello from omp`. So
  `AgentInfo.sessionTitle` is genuinely useful for an omp pane, where for pi it
  is only a directory name. While a pane was blocked on `ask`, the title was
  observed with a `!` marker instead: `π ! Reply exactly hello from omp`.

- **omp has no explicit avatar case arm, and that is deliberate.**
  (2026-09-06) `AgentAvatar`'s fallback takes the first letter of the agent
  type, giving `O` — which collides with nothing among claude (`C`), codex
  (`X`), copilot (`P`) and pi (`π`). Stated explicitly so nobody "fixes" the
  missing arm later. omp's own glyph is `π`, but pi already claims it.

- **Brand color `Color(0xFF55AAB9)`.** (2026-09-06) A cyan-blue at OKLCH hue
  210, chosen to sit in the same lightness/chroma band as the existing five
  while taking the largest free hue gap, between codex (161) and copilot (267).
