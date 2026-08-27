# CLAUDE.md

Guidance for Claude Code working in the drover repo. Complements (does not restate) the
global `~/.claude/CLAUDE.md` rules — those still apply.

## Repo layout

- `app/` — the Flutter app (iOS/macOS) plus `app/tool/spike.dart`, a CLI probe for the SSH/herdr path.

See `README.md` for the concept and layout, `docs/herdr-notes.md` for herdr
CLI behaviours/gotchas drover relies on, and `docs/agents/` for per-agent CLI
notes (`claude-notes.md`, `copilot-notes.md`, `codex-notes.md`,
`pi-notes.md`).

## One-time host setup

- [Flutter](https://flutter.dev), pinned via [fvm](https://fvm.app) to 3.44.5 (see
  `app/.fvmrc`): `dart pub global activate fvm`
- [marionette_mcp](https://pub.dev/packages/marionette_mcp) (lets Claude Code
  inspect/tap/screenshot the running app via the Dart VM service): `dart pub global
  activate marionette_mcp`, then ensure `~/.pub-cache/bin` is on PATH.
- [`asc`](https://asccli.sh) (starts Xcode Cloud builds — only needed to
  release): `brew install asc`, then `asc auth login --name drover --key-id …
  --issuer-id … --private-key …p8`. An App Store Connect API key with the
  **Developer** role is enough. Credentials go to the system keychain, so the
  `.p8` can be deleted afterwards.
- [git-cliff](https://git-cliff.org) (generates `CHANGELOG.md` entries — only
  needed for `just tag-release`, run after a version actually ships):
  `brew install git-cliff`.
- [`jq`](https://jqlang.org) (reads the App Store version state in
  `just tag-release` — only needed for that recipe): `brew install jq`.
- On the Herdr host (the SSH target running your agents): install a herdr
  integration for each agent you want native transcript history for:
  `herdr integration install claude`, `herdr integration install codex`,
  `herdr integration install copilot`, `herdr integration install pi`.
  Without an integration, drover falls back to pane-text history. See
  `docs/herdr-notes.md` for the gotchas — notably, it only takes effect for
  sessions started after the install. For Codex specifically, the first
  launch after install may show a Hooks review panel; trust/enable the hook
  there, then start a fresh session.

## Marionette MCP

Register the server with Claude Code once:

```sh
claude mcp add --transport stdio marionette -- marionette_mcp
```

To control a local app, start it in debug mode, then copy the `ws://.../ws`
Dart VM service URI printed by `flutter run`. Call `marionette-connect` with
that URI before using its inspection or interaction tools.

## Key commands

A `justfile` wraps the app commands below (`just` to list recipes).

```sh
cd app
fvm flutter pub get
fvm flutter analyze
fvm flutter test
fvm flutter run
fvm flutter gen-l10n # regenerate localizations after editing lib/l10n/*.arb
fvm dart run tool/spike.dart --host <host> agents
```

## Releasing

The Xcode Cloud workflow is **manual-start only** — pushing builds nothing. Bump
the version and start a build in one step, from `main`:

```sh
just release        # 1.0.0+48 -> 1.0.0+49, same version, next build
just release 1.0.1  # 1.0.0+48 -> 1.0.1+49, new App Store version
```

Once a marketing version has actually been released on the App Store (state
`READY_FOR_DISTRIBUTION`), Apple closes that version's pre-release train for
new build uploads entirely — TestFlight-only iteration is **not** exempt
(confirmed 2026-08-09: a build-only bump on an already-released 1.0.0 failed
with ITMS-90186 "Invalid Pre-Release Train" + ITMS-90062). Plain `just release`
only works while the current marketing version hasn't shipped yet; once it has,
the next release needs a new semver.

`just release` never touches `CHANGELOG.md` or tags — it only starts a build,
and a build can be rejected or resubmitted before it actually ships. Once
`asc versions list` (or the App Store Connect dashboard) shows the target
semver as `READY_FOR_DISTRIBUTION`, record it:

```sh
just tag-release 1.0.1
```

`tag-release` re-checks that state itself, then asks App Store Connect which
Xcode Cloud build run actually produced the approved build and tags *that*
commit — not `HEAD`, which may have moved on while the build sat in review,
and not just "the last commit that bumped pubspec to this version": Xcode
Cloud assigns the shipped build number from its own counter, which doesn't
always match the number `just release` last wrote to `app/pubspec.yaml`. It
then generates a `CHANGELOG.md` section from the Conventional Commits since
the previous release tag and commits it separately on top of current `main`,
so the entry lands after the tagged commit rather than inside it. See
`cliff.toml` for the commit grouping/skip rules.

## UI previews

All previews run against a stubbed herdr backend (no SSH host needed) so you
can screenshot/inspect UI on a simulator. `just preview` opens an in-app
gallery listing every registered screen; `just preview <name>` (e.g.
`just preview launch`) boots one screen directly, which is handy for
marionette-driven screenshots. Pick a scenario via
`--dart-define=SCENARIO=idle|blocked` (default `idle`). The harness is a single
entrypoint `app/lib/previews/preview.dart` plus `app/lib/src/demo/demo_herdr.dart`,
and shares `droverTheme` and l10n with production. To add a screen, register a
`WidgetBuilder` in the `_previews` map in `preview.dart` — no new entrypoint
file or justfile recipe needed.
