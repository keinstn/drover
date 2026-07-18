#!/bin/sh
# PostToolUse hook for Edit|Write: best-effort format the edited file by
# extension. Never fails the tool call (every branch is silenced; always
# exits 0).
f=$(jq -r '.tool_input.file_path // empty')
[ -z "$f" ] && exit 0

case "$f" in
  *.dart)
    command -v dart >/dev/null 2>&1 || exit 0
    # dart format only resolves analysis_options.yaml's page_width via
    # .dart_tool/package_config.json (written by `pub get`), which doesn't
    # exist yet in a freshly created worktree -- it then silently falls
    # back to the 80-col default and rewraps the whole file. Read
    # page_width ourselves and pass it explicitly so formatting is
    # correct from the very first edit, regardless of pub get timing.
    d=$(dirname "$f")
    aopts=""
    while :; do
      if [ -f "$d/analysis_options.yaml" ]; then
        aopts="$d/analysis_options.yaml"
        break
      fi
      next=$(dirname "$d")
      # dirname reaches a fixed point at "/" (absolute) or "." (relative)
      # instead of erroring, so without this check a relative file_path
      # would loop forever.
      [ "$next" = "$d" ] && break
      d="$next"
    done
    w=""
    if [ -n "$aopts" ]; then
      w=$(awk '/^formatter:/{f=1;next} f&&/page_width:/{print $2; exit}' "$aopts")
    fi
    dart format ${w:+--page-width="$w"} "$f" >/dev/null 2>&1
    ;;
esac
exit 0
