#!/bin/sh
# Manually verify the ntfy push config end to end, without waiting for a
# real agent to go blocked or done. Run this right after editing your
# config (or after changing phones) to confirm the topic actually reaches
# your phone — a wrong-but-reachable topic sends successfully from here but
# never arrives, so the only real confirmation is looking at your phone.
set -eu

self_dir=$(cd "$(dirname "$0")" && pwd)

topic="${NTFY_TOPIC:-}"
if [ -z "$topic" ]; then
    if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -f "${HERDR_PLUGIN_CONFIG_DIR}/config" ]; then
        . "${HERDR_PLUGIN_CONFIG_DIR}/config"
    elif [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/drover-push/config" ]; then
        . "${XDG_CONFIG_HOME:-$HOME/.config}/drover-push/config"
    fi
    topic="${NTFY_TOPIC:-}"
fi

if [ -z "$topic" ]; then
    echo "No NTFY_TOPIC configured. Copy plugin/config.example to" >&2
    echo "~/.config/drover-push/config (or your HERDR_PLUGIN_CONFIG_DIR/config)" >&2
    echo "and set NTFY_TOPIC first." >&2
    exit 1
fi

echo "Sending a test 'blocked' notification to topic '$topic'..."
HERDR_PLUGIN_EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"test","workspace_id":"test","agent_status":"blocked","agent":"claude"}}' \
    sh "$self_dir/notify.sh"
echo "Sent. Check your phone for a notification titled 'test · blocked' —"
echo "if it doesn't arrive, the topic here doesn't match what your phone is subscribed to."
