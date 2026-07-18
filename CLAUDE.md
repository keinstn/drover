# CLAUDE.md

Guidance for Claude Code working in the drover repo. Complements (does not restate) the
global `~/.claude/CLAUDE.md` rules — those still apply.

## Repo layout

- `app/` — the Flutter app (iOS/macOS) plus `app/tool/spike.dart`, the Stage 0 SSH spike.

See `README.md` for the PoC plan and Stage 0 measurement results, and
`~/Projects/ideas/drover.md` for the product proposal.

## One-time host setup

- [Flutter](https://flutter.dev), pinned via [fvm](https://fvm.app) to 3.44.5 (see
  `app/.fvmrc`): `dart pub global activate fvm`
- [marionette_mcp](https://pub.dev/packages/marionette_mcp) (lets Claude Code
  inspect/tap/screenshot the running app via the Dart VM service): `dart pub global
  activate marionette_mcp`, then ensure `~/.pub-cache/bin` is on PATH.

## Key commands

A `justfile` wraps the app commands below (`just` to list recipes).

```sh
cd app
fvm flutter pub get
fvm flutter analyze
fvm flutter test
fvm flutter run
fvm dart run tool/spike.dart --host <host> agents
```
