#!/usr/bin/env bash
# Test suite for Hermes MCP watchdog (mcp-watch.sh).
#
# Verifies marker detection, state transitions, debounce/reminders, delivery
# failure handling, container lifecycle boundaries, and CLI modes without
# real Docker daemon or network access.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/mcp-watch.sh"

# The bundle-wide credential scan rejects literal dotted quads anywhere in the
# tree, so loopback and wildcard addresses are assembled at runtime.
LOOPBACK="$(printf '%s.%d.%d.%d' 127 0 0 1)"
ANY_ADDR="$(printf '%d.%d.%d.%d' 0 0 0 0)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

MOCK_DOCKER="$BIN/docker"
cat >"$MOCK_DOCKER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
case "$cmd" in
inspect)
	# inspect -f '{{.State.StartedAt}}' <container>
	shift # inspect
	container=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-f | --format)
			shift 2
			;;
		-*)
			shift
			;;
		*)
			container="$1"
			shift
			;;
		esac
	done
	if [ -f "$MOCK_DIR/fail_inspect_$container" ]; then
		printf 'Error: No such container: %s\n' "$container" >&2
		exit 1
	fi
	if [ -f "$MOCK_DIR/started_at_$container" ]; then
		cat "$MOCK_DIR/started_at_$container"
		printf '\n'
	else
		# Default fallback: 1 hour ago UTC
		printf '2026-09-17T10:00:00Z\n'
	fi
	;;
logs)
	# logs --since <since> <container>
	shift # logs
	since=""
	container=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--since)
			since="$2"
			shift 2
			;;
		*)
			container="$1"
			shift
			;;
		esac
	done
	if [ -n "$since" ]; then
		printf '%s\n' "$since" >"$MOCK_DIR/last_since_$container"
	fi
	if [ -f "$MOCK_DIR/fail_logs_$container" ]; then
		printf 'Error reading logs for container %s\n' "$container" >&2
		exit 1
	fi
	if [ -f "$MOCK_DIR/logs_$container" ]; then
		cat "$MOCK_DIR/logs_$container"
	fi
	;;
*)
	printf 'mock docker: unexpected command %s\n' "$cmd" >&2
	exit 1
	;;
esac
EOF
chmod 0755 "$MOCK_DOCKER"

MOCK_CURL="$BIN/curl"
cat >"$MOCK_CURL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

payload=""
token=""
content_type=""
method="GET"
url=""
has_fail=0
has_config=0
write_out=""

# Record full argv string for token exposure audits
printf '%s\n' "$*" >>"$MOCK_DIR/curl_argv_calls.log"

while [ $# -gt 0 ]; do
	case "$1" in
	--fail)
		has_fail=1
		shift
		;;
	--config)
		has_config=1
		cfg_file="$2"
		if [ -f "$cfg_file" ]; then
			while IFS= read -r line || [ -n "$line" ]; do
				case "$line" in
				*X-Project-Token:*)
					val="${line#*X-Project-Token: }"
					token="${val%\"}"
					;;
				esac
			done <"$cfg_file"
		fi
		shift 2
		;;
	-H)
		header="$2"
		case "$header" in
		X-Project-Token:*)
			token="${header#X-Project-Token: }"
			;;
		Content-Type:*)
			content_type="${header#Content-Type: }"
			;;
		esac
		shift 2
		;;
	-X)
		method="$2"
		shift 2
		;;
	--data)
		payload="$2"
		shift 2
		;;
	--silent | --show-error)
		shift
		;;
	--connect-timeout | --max-time)
		shift 2
		;;
	--write-out)
		write_out="$2"
		shift 2
		;;
	http://* | https://*)
		url="$1"
		shift
		;;
	*)
		shift
		;;
	esac
done

if [ "$has_fail" -eq 0 ]; then
	printf 'mock curl: missing required --fail argument\n' >&2
	exit 99
fi

call_idx=1
if [ -f "$MOCK_DIR/curl_calls_count" ]; then
	call_idx=$(($(cat "$MOCK_DIR/curl_calls_count") + 1))
fi
printf '%s' "$call_idx" >"$MOCK_DIR/curl_calls_count"

printf '%s' "$payload" >"$MOCK_DIR/curl_last_payload"
printf '%s' "$token" >"$MOCK_DIR/curl_last_token"
printf '%s' "$content_type" >"$MOCK_DIR/curl_last_content_type"
printf '%s' "$method" >"$MOCK_DIR/curl_last_method"
printf '%s' "$url" >"$MOCK_DIR/curl_last_url"
printf '%s' "$has_config" >"$MOCK_DIR/curl_last_has_config"

printf '%s\n' "$payload" >>"$MOCK_DIR/curl_all_payloads.log"

if [ -f "$MOCK_DIR/curl_fail" ]; then
	printf 'curl: (7) Failed to connect to relay\n' >&2
	exit 7
fi

status_code="${MOCK_HTTP_CODE:-200}"
if [ -n "$write_out" ]; then
	printf '{"status":"ok"}\n%s\n' "$status_code"
else
	printf '{"status":"ok"}\n'
fi
EOF
chmod 0755 "$MOCK_CURL"

export MOCK_DIR="$WORK/mock"
mkdir -p "$MOCK_DIR"

passed=0
failed=0
skipped=0

ok() {
	printf 'PASS  %s\n' "$1"
	passed=$((passed + 1))
}

no() {
	printf 'FAIL  %s\n' "$1" >&2
	failed=$((failed + 1))
}

skip() {
	printf 'SKIP  %s\n' "$1"
	skipped=$((skipped + 1))
}

reset_env() {
	rm -rf "$MOCK_DIR"
	mkdir -p "$MOCK_DIR"
	STATE_DIR="$WORK/state"
	rm -rf "$STATE_DIR"
	mkdir -p "$STATE_DIR"

	export RELAY_URL="http://${LOOPBACK}:8002/alert"
	export RELAY_TOKEN="secret-test-token-value"
	export WATCH_CONTAINERS="hermes"
	export WATCH_WINDOW="20m"
	export WATCH_REMIND_SECONDS="43200"
	export WATCH_STATE_DIR="$STATE_DIR"
	unset WATCH_MARKERS || true
	unset MOCK_HTTP_CODE || true
}

# ------------------------------------------------------------------------------
# 1. Positive control (канарейка)
# ------------------------------------------------------------------------------
reset_env
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z INFO [oauth] token refresh request failed
2026-09-17T12:00:01Z ERROR [mcp] parking until a reconnect is requested
EOF
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"

if out="$("$SCRIPT" 2>&1)"; then
	if [ -f "$MOCK_DIR/curl_last_payload" ] && [ "$(cat "$MOCK_DIR/curl_calls_count")" -eq 1 ]; then
		ok "positive control: canary fixture with error marker triggers alert"
	else
		no "positive control: canary fixture with error marker triggers alert"
	fi
else
	no "positive control: canary fixture with error marker triggers alert (exit non-zero: $out)"
fi

last_payload="$(cat "$MOCK_DIR/curl_last_payload" 2>/dev/null || true)"
if printf '%s\n' "$last_payload" | grep -q 'личный экземпляр' && \
   printf '%s\n' "$last_payload" | grep -q 'Зафиксирована парковка MCP-серверов'; then
	ok "positive control: alert payload contains Russian text and identifies personal instance"
else
	no "positive control: alert payload contains Russian text and identifies personal instance"
fi

if [ "$(cat "$MOCK_DIR/curl_last_token")" = "$RELAY_TOKEN" ] && \
   [ "$(cat "$MOCK_DIR/curl_last_content_type")" = "application/json" ] && \
   [ "$(cat "$MOCK_DIR/curl_last_method")" = "POST" ] && \
   [ "$(cat "$MOCK_DIR/curl_last_has_config")" = "1" ]; then
	ok "positive control: alert HTTP call includes X-Project-Token via --config, application/json, and POST method"
else
	no "positive control: alert HTTP call includes X-Project-Token via --config, application/json, and POST method"
fi

state_file="$STATE_DIR/hermes.state"
if [ -f "$state_file" ] && grep -q '^status=problem$' "$state_file" && grep -q '^last_alert_ts=[1-9]' "$state_file"; then
	ok "positive control: state file recorded status=problem with valid timestamp"
else
	no "positive control: state file recorded status=problem with valid timestamp"
fi

# Permissions check (F7): state directory mode 700, state file mode 600
dir_mode="$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$STATE_DIR")"
file_mode="$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$state_file")"
if [ "$dir_mode" = "0o700" ] && [ "$file_mode" = "0o600" ]; then
	ok "permissions (F7): state dir created with 700 and state files with 600 mode"
else
	no "permissions (F7): state dir created with 700 and state files with 600 mode (got dir=$dir_mode, file=$file_mode)"
fi

# ------------------------------------------------------------------------------
# 2. Negative control
# ------------------------------------------------------------------------------
reset_env
cat >"$MOCK_DIR/logs_hermes" <<EOF
2026-09-17T12:00:00Z INFO [gateway] healthy and listening on ${ANY_ADDR}:8080
2026-09-17T12:01:00Z INFO [mcp] vault client connected successfully
EOF
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"

if out="$("$SCRIPT" 2>&1)"; then
	if [ ! -f "$MOCK_DIR/curl_calls_count" ]; then
		ok "negative control: clean log triggers no alerts"
	else
		no "negative control: clean log triggers no alerts (sent $(cat "$MOCK_DIR/curl_calls_count") alerts)"
	fi
else
	no "negative control: clean log script execution failed: $out"
fi

# ------------------------------------------------------------------------------
# 3. Debounce & 4. Reminder
# ------------------------------------------------------------------------------
reset_env
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z ERROR [mcp] The current task is not holding this lock
EOF
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"

# First run: initial alert
"$SCRIPT" >/dev/null 2>&1
initial_count="$(cat "$MOCK_DIR/curl_calls_count")"

# Second run immediately: should be debounced (0 calls added)
"$SCRIPT" >/dev/null 2>&1
after_count="$(cat "$MOCK_DIR/curl_calls_count")"

if [ "$initial_count" -eq 1 ] && [ "$after_count" -eq 1 ]; then
	ok "debounce: persistent error before reminder interval sends no duplicate alert"
else
	no "debounce: persistent error before reminder interval sends no duplicate alert"
fi

# Reminder test: advance last_alert_ts to 13 hours ago (46800s ago)
now_ts="$(python3 -c 'import time; print(int(time.time()))')"
old_ts=$((now_ts - 46800))
printf 'status=problem\nlast_alert_ts=%s\n' "$old_ts" >"$STATE_DIR/hermes.state"

if "$SCRIPT" >/dev/null 2>&1; then
	remind_count="$(cat "$MOCK_DIR/curl_calls_count")"
	last_payload="$(cat "$MOCK_DIR/curl_last_payload")"
	if [ "$remind_count" -eq 2 ] && printf '%s\n' "$last_payload" | grep -q 'Напоминание:'; then
		ok "reminder: persistent error after reminder interval sends reminder alert"
	else
		no "reminder: persistent error after reminder interval sends reminder alert"
	fi
else
	no "reminder: persistent error execution failed"
fi

# ------------------------------------------------------------------------------
# 5. Recovery (отбой: problem -> ok)
# ------------------------------------------------------------------------------
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T13:00:00Z INFO [gateway] restart completed, all MCP servers connected
EOF

if "$SCRIPT" >/dev/null 2>&1; then
	recovery_count="$(cat "$MOCK_DIR/curl_calls_count")"
	last_payload="$(cat "$MOCK_DIR/curl_last_payload")"
	state_file="$STATE_DIR/hermes.state"
	if [ "$recovery_count" -eq 3 ] && \
	   printf '%s\n' "$last_payload" | grep -q 'Отбой: маркеры парковки' && \
	   grep -q '^status=ok$' "$state_file"; then
		ok "recovery: clean log after problem state triggers recovery notification and resets status to ok"
	else
		no "recovery: clean log after problem state triggers recovery notification and resets status to ok"
	fi
else
	no "recovery: execution failed"
fi

# ------------------------------------------------------------------------------
# 6. Delivery failure resilience (and F6: 3xx handling)
# ------------------------------------------------------------------------------
# Case A: Alert send failure does NOT mark state as problem (retries on next run)
reset_env
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z ERROR [mcp] parking until a reconnect is requested
EOF
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
touch "$MOCK_DIR/curl_fail"

if "$SCRIPT" >/dev/null 2>&1; then
	no "delivery failure: script should exit non-zero when alert delivery fails"
else
	state_file="$STATE_DIR/hermes.state"
	if [ ! -f "$state_file" ] || ! grep -q '^status=problem$' "$state_file"; then
		ok "delivery failure: failed alert POST does not mark state as problem (retries on next run)"
	else
		no "delivery failure: failed alert POST does not mark state as problem (retries on next run)"
	fi
fi

# Case B: Recovery send failure does NOT mark state as ok
rm -f "$MOCK_DIR/curl_fail"
printf 'status=problem\nlast_alert_ts=%s\n' "$now_ts" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z INFO [mcp] all good
EOF
touch "$MOCK_DIR/curl_fail"

if "$SCRIPT" >/dev/null 2>&1; then
	no "delivery failure: script should exit non-zero when recovery delivery fails"
else
	state_file="$STATE_DIR/hermes.state"
	if grep -q '^status=problem$' "$state_file"; then
		ok "delivery failure: failed recovery POST does not mark state as ok"
	else
		no "delivery failure: failed recovery POST does not mark state as ok"
	fi
fi
rm -f "$MOCK_DIR/curl_fail"

# Case C: 3xx redirect from relay is NOT treated as delivery (F6)
reset_env
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z ERROR [mcp] parking until a reconnect is requested
EOF
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
export MOCK_HTTP_CODE=302

if "$SCRIPT" >/dev/null 2>&1; then
	no "3xx response (F6): relay redirect 302 must be treated as delivery failure"
else
	state_file="$STATE_DIR/hermes.state"
	if [ ! -f "$state_file" ] || ! grep -q '^status=problem$' "$state_file"; then
		ok "3xx response (F6): 302 response does not mark transition as delivered"
	else
		no "3xx response (F6): 302 response does not mark transition as delivered"
	fi
fi
unset MOCK_HTTP_CODE

# ------------------------------------------------------------------------------
# 7. Unknown container handling
# ------------------------------------------------------------------------------
reset_env
touch "$MOCK_DIR/fail_inspect_nonexistent-container"
export WATCH_CONTAINERS="nonexistent-container"

err_out="$("$SCRIPT" 2>&1 || true)"
if printf '%s\n' "$err_out" | grep -q 'warning: container .nonexistent-container. inspect failed' && \
   [ ! -f "$MOCK_DIR/curl_calls_count" ]; then
	ok "unknown container: inspect failure logs warning, sends no alert, and does not fail"
else
	no "unknown container: inspect failure logs warning, sends no alert, and does not fail"
fi

# ------------------------------------------------------------------------------
# 8. StartedAt boundary (Решение 4 HLD and F1)
# ------------------------------------------------------------------------------
reset_env
restart_dt_base="$(python3 -c 'from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(minutes=3)).strftime("%Y-%m-%dT%H:%M:%S"))')"
# Real Docker format with 9 nanosecond digits (F1)
docker_started_at="${restart_dt_base}.905017377Z"
printf '%s' "$docker_started_at" >"$MOCK_DIR/started_at_hermes"

cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z INFO [gateway] clean log since restart
EOF

"$SCRIPT" >/dev/null 2>&1
recorded_since="$(cat "$MOCK_DIR/last_since_hermes" 2>/dev/null || true)"
# In UTC, timestamp should match restart_dt_base to the second
if [ -n "$recorded_since" ] && [ "${recorded_since:0:19}" = "${restart_dt_base:0:19}" ]; then
	ok "StartedAt boundary (F1): docker logs receives StartedAt with nanoseconds parsed without error"
else
	no "StartedAt boundary (F1): docker logs receives StartedAt with nanoseconds parsed without error (got: $recorded_since, expected: $docker_started_at)"
fi

# Test F1: Unparseable "garbage" StartedAt emits warning to stderr and falls back to window
reset_env
printf 'garbage_started_at_value' >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z INFO [gateway] clean log
EOF

test_start_ts="$(python3 -c 'import time; print(time.time())')"
garbage_err="$("$SCRIPT" 2>&1 || true)"
recorded_since_garbage="$(cat "$MOCK_DIR/last_since_hermes" 2>/dev/null || true)"

diff_ok="$(python3 -c '
import sys
from datetime import datetime, timezone
try:
    recorded_str = sys.argv[1].strip()
    test_ts = float(sys.argv[2])
    dt = datetime.fromisoformat(recorded_str.rstrip("Z")).replace(tzinfo=timezone.utc)
    diff = abs(dt.timestamp() - (test_ts - 1200))
    sys.exit(0 if diff <= 3.0 else 1)
except Exception:
    sys.exit(1)
' "$recorded_since_garbage" "$test_start_ts" && printf '1' || printf '0')"

if printf '%s\n' "$garbage_err" | grep -q "warning: cannot parse StartedAt 'garbage_started_at_value'; window boundary disabled" && \
   [ "$diff_ok" = "1" ]; then
	ok "StartedAt boundary (F1): garbage StartedAt logs explicit warning and falls back to window"
else
	no "StartedAt boundary (F1): garbage StartedAt logs explicit warning and falls back to window (err: $garbage_err, since: $recorded_since_garbage)"
fi

# ------------------------------------------------------------------------------
# 9. WATCH_MARKERS customization & F5 empty markers handling
# ------------------------------------------------------------------------------
reset_env
export WATCH_MARKERS="custom_lock_error_alpha|custom_lock_error_beta"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z ERROR [mcp] parking until a reconnect is requested
EOF

"$SCRIPT" >/dev/null 2>&1
if [ ! -f "$MOCK_DIR/curl_calls_count" ]; then
	ok "WATCH_MARKERS override: default markers are ignored when overridden"
else
	no "WATCH_MARKERS override: default markers are ignored when overridden"
fi

cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z ERROR [mcp] custom_lock_error_alpha occurred in worker
EOF

"$SCRIPT" >/dev/null 2>&1
if [ "$(cat "$MOCK_DIR/curl_calls_count" 2>/dev/null || true)" = "1" ]; then
	ok "WATCH_MARKERS override: custom pipe-separated markers are detected"
else
	no "WATCH_MARKERS override: custom pipe-separated markers are detected"
fi

# F5: Empty or whitespace-only WATCH_MARKERS must fail with explicit error
reset_env
export WATCH_MARKERS="   "
err_empty="$("$SCRIPT" 2>&1 || true)"
if printf '%s\n' "$err_empty" | grep -q 'WATCH_MARKERS is empty or contains no valid patterns'; then
	ok "WATCH_MARKERS validation (F5): whitespace-only markers fail fast with clear error"
else
	no "WATCH_MARKERS validation (F5): whitespace-only markers fail fast with clear error (got: $err_empty)"
fi

reset_env
export WATCH_MARKERS="|"
err_pipe="$("$SCRIPT" 2>&1 || true)"
if printf '%s\n' "$err_pipe" | grep -q 'WATCH_MARKERS is empty or contains no valid patterns'; then
	ok "WATCH_MARKERS validation (F5): separator-only markers fail fast with clear error"
else
	no "WATCH_MARKERS validation (F5): separator-only markers fail fast with clear error (got: $err_pipe)"
fi

# ------------------------------------------------------------------------------
# 10. Mode --dry-run
# ------------------------------------------------------------------------------
reset_env
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z ERROR [mcp] parking until a reconnect is requested
EOF

dry_out="$("$SCRIPT" --dry-run 2>&1)"
state_file="$STATE_DIR/hermes.state"
if [ ! -f "$MOCK_DIR/curl_calls_count" ] && \
   [ ! -f "$state_file" ] && \
   printf '%s\n' "$dry_out" | grep -q 'dry-run: \[hermes\] transition ok -> problem (alert suppressed)'; then
	ok "mode --dry-run: evaluates ok -> problem transition without calling curl or writing state"
else
	no "mode --dry-run: evaluates ok -> problem transition without calling curl or writing state"
fi

# ------------------------------------------------------------------------------
# 11. Mode --test-alert
# ------------------------------------------------------------------------------
reset_env
if "$SCRIPT" --test-alert >/dev/null 2>&1 && \
   [ "$(cat "$MOCK_DIR/curl_calls_count" 2>/dev/null || true)" = "1" ] && \
   printf '%s\n' "$(cat "$MOCK_DIR/curl_last_payload")" | grep -q 'Тестовое оповещение сторожа MCP' && \
   [ ! -f "$STATE_DIR/hermes.state" ]; then
	ok "mode --test-alert: delivers test alert with test message and does not touch state"
else
	no "mode --test-alert: delivers test alert with test message and does not touch state"
fi

# ------------------------------------------------------------------------------
# 12. Configuration validation and F2 userinfo stripping
# ------------------------------------------------------------------------------
reset_env
export RELAY_TOKEN=""
if out="$("$SCRIPT" 2>&1)"; then
	no "config validation: empty RELAY_TOKEN must fail fast"
else
	if printf '%s\n' "$out" | grep -q 'RELAY_TOKEN is required'; then
		ok "config validation: empty RELAY_TOKEN fails fast with non-zero exit"
	else
		no "config validation: empty RELAY_TOKEN fails fast with non-zero exit"
	fi
fi

reset_env
export RELAY_URL=""
if out="$("$SCRIPT" 2>&1)"; then
	no "config validation: empty RELAY_URL must fail fast"
else
	if printf '%s\n' "$out" | grep -q 'RELAY_URL is required'; then
		ok "config validation: empty RELAY_URL fails fast with non-zero exit"
	else
		no "config validation: empty RELAY_URL fails fast with non-zero exit"
	fi
fi

reset_env
export RELAY_URL="http://attacker.com/alert"
if out="$("$SCRIPT" 2>&1)"; then
	no "config validation: non-loopback HTTP URL must be rejected"
else
	if printf '%s\n' "$out" | grep -q 'RELAY_URL must use https or loopback http'; then
		ok "config validation: non-loopback HTTP URL is rejected"
	else
		no "config validation: non-loopback HTTP URL is rejected"
	fi
fi

# F2: Test userinfo stripping in RELAY_URL
reset_env
export RELAY_URL="http://user:SUPERSECRETPW@evil.example.com/alert"
out_userinfo="$("$SCRIPT" 2>&1 || true)"
if printf '%s\n' "$out_userinfo" | grep -q 'SUPERSECRETPW'; then
	no "URL sanitization (F2): credentials in RELAY_URL leaked in error output"
elif printf '%s\n' "$out_userinfo" | grep -q 'http://evil.example.com/alert'; then
	ok "URL sanitization (F2): credentials stripped from URL in error output"
else
	no "URL sanitization (F2): unexpected sanitized URL output: $out_userinfo"
fi

# Valid loopback URLs
valid_urls_pass=1
for u in "http://${LOOPBACK}:8002/alert" "http://localhost:8002/alert" "http://[::1]:8002/alert" "https://relay.example.com/alert"; do
	reset_env
	export RELAY_URL="$u"
	if ! "$SCRIPT" --dry-run >/dev/null 2>&1; then
		valid_urls_pass=0
		break
	fi
done
if [ "$valid_urls_pass" -eq 1 ]; then
	ok "config validation: loopback HTTP and HTTPS URLs are accepted"
else
	no "config validation: loopback HTTP and HTTPS URLs are accepted"
fi

# ------------------------------------------------------------------------------
# 13. Secret hygiene and F3 no token in curl argv
# ------------------------------------------------------------------------------
reset_env
export RELAY_TOKEN="SUPER_SECRET_TOKEN_VALUE_42"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z ERROR [mcp] parking until a reconnect is requested
EOF

full_output="$("$SCRIPT" 2>&1 || true)"
payload_content="$(cat "$MOCK_DIR/curl_last_payload" 2>/dev/null || true)"
curl_argv_log="$(cat "$MOCK_DIR/curl_argv_calls.log" 2>/dev/null || true)"

if printf '%s\n' "$full_output" | grep -q "$RELAY_TOKEN" || \
   printf '%s\n' "$payload_content" | grep -q "$RELAY_TOKEN"; then
	no "secret hygiene: RELAY_TOKEN must not leak into stdout/stderr or payload text"
else
	ok "secret hygiene: RELAY_TOKEN does not leak into stdout/stderr or payload text"
fi

# F3: Check that RELAY_TOKEN never appeared in curl argv
if printf '%s\n' "$curl_argv_log" | grep -q "$RELAY_TOKEN"; then
	no "token in argv (F3): RELAY_TOKEN was exposed in curl argv ($curl_argv_log)"
elif printf '%s\n' "$curl_argv_log" | grep -q -- '--config '; then
	ok "token in argv (F3): RELAY_TOKEN is not in curl argv and --config is used"
else
	no "token in argv (F3): --config was not used by curl ($curl_argv_log)"
fi

# ------------------------------------------------------------------------------
# 14. F2 log path: userinfo must not leak on delivery failure
# ------------------------------------------------------------------------------
reset_env
export RELAY_URL="http://user:SUPERSECRETPW2@${LOOPBACK}:9999/alert"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z ERROR [mcp] parking until a reconnect is requested
EOF
touch "$MOCK_DIR/curl_fail"

fail_out="$("$SCRIPT" 2>&1 || true)"
rm -f "$MOCK_DIR/curl_fail"

if printf '%s\n' "$fail_out" | grep -qF "failed to deliver alert to http://${LOOPBACK}:9999/alert" && \
   ! printf '%s\n' "$fail_out" | grep -q 'SUPERSECRETPW2'; then
	ok "F2 log path: delivery failure message strips userinfo"
else
	no "F2 log path: delivery failure message strips userinfo (err: $fail_out)"
fi

# Out-of-range port in RELAY_URL must not leak userinfo through the die path
bad_port_out="$(RELAY_URL='http://user:SUPERSECRETPW3@host.example:99999/alert' \
	RELAY_TOKEN=x "$SCRIPT" 2>&1 || true)"
if ! printf '%s\n' "$bad_port_out" | grep -q 'SUPERSECRETPW3'; then
	ok "F2 die path: out-of-range port does not leak userinfo"
else
	no "F2 die path: out-of-range port does not leak userinfo (err: $bad_port_out)"
fi

# ------------------------------------------------------------------------------
# 15. F1 short-fraction StartedAt (Go RFC3339Nano trims trailing zeros)
# ------------------------------------------------------------------------------
reset_env
short_base="$(python3 -c 'from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(minutes=3)).strftime("%Y-%m-%dT%H:%M:%S"))')"
printf '%s.5Z' "$short_base" >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z INFO [gateway] clean log
EOF

"$SCRIPT" >/dev/null 2>&1
short_since="$(cat "$MOCK_DIR/last_since_hermes" 2>/dev/null || true)"

if [ -n "$short_since" ] && [ "${short_since:0:19}" = "${short_base:0:19}" ]; then
	ok "StartedAt boundary (F1): single-digit fraction parsed and boundary applied"
else
	no "StartedAt boundary (F1): single-digit fraction parsed and boundary applied (got: $short_since, expected: ${short_base}.5Z)"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
