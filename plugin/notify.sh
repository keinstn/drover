#!/bin/sh
# Herdr plugin hook for pane.agent_status_changed: push a phone notification
# via ntfy when an agent goes blocked or finishes.
#
# Guarantee: this script always exits 0. A non-zero exit would show up as an
# error in Herdr's plugin logs, and every failure mode below (missing
# config, network down, malformed event JSON, herdr enrichment failing) is
# expected and non-actionable — so the real work lives in run(), and `run`
# is the non-final command of an OR-list, which makes `set -e` ignore its
# internal failures instead of aborting the whole script.
set -eu

run() {
    event_json="${HERDR_PLUGIN_EVENT_JSON:-}"
    [ -n "$event_json" ] || return 0

    status=$(printf '%s' "$event_json" | jq -r '.data.agent_status // empty')
    pane_id=$(printf '%s' "$event_json" | jq -r '.data.pane_id // empty')

    # Filter: only the "go look at your phone" states. blocked = agent is
    # waiting on input, done = agent finished. Herdr fires this event once
    # per transition, so no extra dedup is needed here.
    case "$status" in
        blocked) priority=high; tags=warning ;;
        done) priority=default; tags=white_check_mark ;;
        *) return 0 ;;
    esac

    # Config: env vars already set (e.g. injected into Herdr's environment)
    # take precedence over config files. Without a topic the plugin is
    # inert — exit quietly rather than erroring.
    if [ -z "${NTFY_TOPIC:-}" ]; then
        if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -f "${HERDR_PLUGIN_CONFIG_DIR}/config" ]; then
            . "${HERDR_PLUGIN_CONFIG_DIR}/config"
        elif [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/drover-push/config" ]; then
            . "${XDG_CONFIG_HOME:-$HOME/.config}/drover-push/config"
        fi
    fi
    [ -n "${NTFY_TOPIC:-}" ] || return 0
    server="${NTFY_SERVER:-https://ntfy.sh}"

    # Enrich with agent details; degrade to just pane_id + status on failure.
    agent_json=$("${HERDR_BIN_PATH:-herdr}" agent get "$pane_id" 2>/dev/null) || agent_json=""
    name=$(printf '%s' "$agent_json" | jq -r '.result.agent.name // .result.agent.agent // empty' 2>/dev/null)
    [ -n "$name" ] || name="$pane_id"
    workspace=$(printf '%s' "$agent_json" | jq -r '.result.agent.workspace_id // empty' 2>/dev/null)
    cwd=$(printf '%s' "$agent_json" | jq -r '.result.agent.foreground_cwd // .result.agent.cwd // empty' 2>/dev/null)
    cwd_tail=""
    [ -n "$cwd" ] && cwd_tail=$(basename "$cwd")

    title="$name · $status"
    body=""
    [ -n "$workspace" ] && body="workspace $workspace"
    if [ -n "$cwd_tail" ]; then
        [ -n "$body" ] && body="$body · $cwd_tail" || body="$cwd_tail"
    fi
    [ -n "$body" ] || body="$status"

    # Only stdout (ntfy's response body) is discarded. curl's stderr is left
    # alone: a transport-level failure (DNS, timeout, connection refused) is
    # a real diagnostic signal, and Herdr captures a plugin hook's stderr
    # into `herdr plugin log list`, so it stays visible there for debugging.
    # This does NOT catch a wrong-but-reachable topic — ntfy accepts a
    # publish to any topic string whether or not a phone is subscribed to
    # it, so that failure mode is invisible to the publisher by design; use
    # send-test-notification.sh to verify your config end to end instead.
    "${CURL:-curl}" -sS --max-time 10 -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" -d "$body" "$server/$NTFY_TOPIC" >/dev/null || true
}

run || true
exit 0
