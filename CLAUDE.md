# CLAUDE.md

Guidance for Claude Code working in the drover repo. Complements (does not restate) the
global `~/.claude/CLAUDE.md` rules — those still apply.

## Repo layout

- `app/` — the Flutter app (iOS/macOS) plus `app/tool/spike.dart`, a CLI probe for the SSH/herdr path.
- `plugin/` — the Herdr → ntfy push-notification plugin.

See `README.md` for the concept and layout, and `docs/herdr-notes.md` for herdr
CLI behaviours/gotchas drover relies on.

## One-time host setup

- [Flutter](https://flutter.dev), pinned via [fvm](https://fvm.app) to 3.44.5 (see
  `app/.fvmrc`): `dart pub global activate fvm`
- [marionette_mcp](https://pub.dev/packages/marionette_mcp) (lets Claude Code
  inspect/tap/screenshot the running app via the Dart VM service): `dart pub global
  activate marionette_mcp`, then ensure `~/.pub-cache/bin` is on PATH.

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
