#!/bin/sh
# Shell tests for plugin/notify.sh — stubs curl and herdr, no network.
set -eu

self_dir=$(cd "$(dirname "$0")" && pwd)
plugin_dir=$(cd "$self_dir/.." && pwd)
notify_sh="$plugin_dir/notify.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail_count=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fail_count=$((fail_count + 1)); }

# Stub curl: record every invocation's args to curl.log.
cat >"$tmp/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$(dirname "$0")/curl.log"
exit 0
EOF
chmod +x "$tmp/curl"

# Stub herdr: mirrors the real CLI's `agent get <target>` (no --json flag —
# `agent get` already returns JSON natively). Anything else, including a
# trailing `--json`, is a usage error, exactly like the real binary.
cat >"$tmp/herdr" <<'EOF'
#!/bin/sh
if [ "$1" = "agent" ] && [ "$2" = "get" ] && [ -n "${3:-}" ] && [ -z "${4:-}" ]; then
    cat <<'JSON'
{"id":1,"result":{"agent":{"agent":"claude","agent_status":"blocked","cwd":"/x/y/demo","foreground_cwd":"/x/y/demo","name":"drover-DEMO","pane_id":"wB:pQ","workspace_id":"wB"}}}
JSON
    exit 0
fi
echo "usage: herdr agent get <target>" >&2
exit 1
EOF
chmod +x "$tmp/herdr"

# Isolate from any real host config so tests don't pick up a live NTFY_TOPIC.
export HOME="$tmp/home"
mkdir -p "$HOME"
unset XDG_CONFIG_HOME 2>/dev/null || true
unset HERDR_PLUGIN_CONFIG_DIR 2>/dev/null || true

export CURL="$tmp/curl"
export HERDR_BIN_PATH="$tmp/herdr"

event_json() {
    status="$1"
    printf '{"event":"pane.agent_status_changed","data":{"pane_id":"wB:pQ","workspace_id":"wB","agent_status":"%s","agent":"claude"}}' "$status"
}

run_notify() {
    HERDR_PLUGIN_EVENT_JSON="$1" NTFY_TOPIC="${NTFY_TOPIC:-}" NTFY_SERVER="${NTFY_SERVER:-}" sh "$notify_sh"
}

# --- a. status blocked: expect a send with Priority: high and the right title ---
export NTFY_TOPIC=testtopic
export NTFY_SERVER=https://example.test
rm -f "$tmp/curl.log"
run_notify "$(event_json blocked)"
if [ -f "$tmp/curl.log" ] \
    && grep -qF 'https://example.test/testtopic' "$tmp/curl.log" \
    && grep -qF 'Priority: high' "$tmp/curl.log" \
    && grep -qF 'drover-DEMO · blocked' "$tmp/curl.log"; then
    pass "blocked status sends notification with high priority"
else
    fail "blocked status sends notification with high priority"
fi

# --- a2. enrichment actually worked against the stub herdr: the title must
# carry the agent NAME (not the bare pane id), and the body must carry the
# workspace and cwd tail. This fails if `agent get` is ever called with an
# extra flag (like --json) the real CLI rejects, since the stub then errors
# out and notify.sh degrades to pane_id-only. ---
if grep -qF 'Title: drover-DEMO · blocked' "$tmp/curl.log" \
    && grep -qF 'workspace wB' "$tmp/curl.log" \
    && grep -qF 'demo' "$tmp/curl.log"; then
    pass "enrichment fills in agent name, workspace, and cwd tail"
else
    fail "enrichment fills in agent name, workspace, and cwd tail"
fi

# --- b. status working: expect no send ---
rm -f "$tmp/curl.log"
run_notify "$(event_json working)"
if [ ! -s "$tmp/curl.log" ]; then
    pass "working status does not send"
else
    fail "working status does not send"
fi

# --- c. status done: expect a send with Priority: default ---
rm -f "$tmp/curl.log"
run_notify "$(event_json done)"
if [ -f "$tmp/curl.log" ] && grep -qF 'Priority: default' "$tmp/curl.log"; then
    pass "done status sends notification with default priority"
else
    fail "done status sends notification with default priority"
fi

# --- d. no NTFY_TOPIC: expect no send even though status is blocked ---
rm -f "$tmp/curl.log"
unset NTFY_TOPIC
run_notify "$(event_json blocked)"
if [ ! -s "$tmp/curl.log" ]; then
    pass "missing NTFY_TOPIC does not send (plugin inert without config)"
else
    fail "missing NTFY_TOPIC does not send (plugin inert without config)"
fi
export NTFY_TOPIC=testtopic

# --- e. always exits 0, even with empty event JSON ---
rm -f "$tmp/curl.log"
set +e
HERDR_PLUGIN_EVENT_JSON="" sh "$notify_sh"
exit_code=$?
set -e
if [ "$exit_code" -eq 0 ]; then
    pass "always exits 0 (empty event JSON)"
else
    fail "always exits 0 (empty event JSON), got exit $exit_code"
fi

if [ "$fail_count" -eq 0 ]; then
    echo "All notify.sh tests passed."
    exit 0
else
    echo "$fail_count test(s) failed."
    exit 1
fi
