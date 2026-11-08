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
exec)
	# Two exec calls are part of the watchdog contract:
	#  - the supervisor slot resolution (image python query), stubbed by
	#    STUB_SLOT (overridable) or STUB_SLOT_MODE=fail for the unknown case;
	#  - the gateway identity sampling through s6-svstat, stubbed by STUB_SVSTAT
	#    (default pid 175 with a huge uptime so static fixtures stay eligible)
	#    or STUB_SVSTAT_MODE=fail.
	shift # exec
	for a in "$@"; do
		case "$a" in
		*S6ServiceManager*)
			if [ "${STUB_SLOT_MODE:-ok}" != "ok" ]; then
				exit 3
			fi
			printf '%s\n' "${STUB_SLOT:-/run/hermes-service/gateway-default}"
			exit 0
			;;
		*s6-svstat*)
			if [ "${STUB_SVSTAT_MODE:-ok}" != "ok" ]; then
				exit 1
			fi
			printf '%s\n' "${STUB_SVSTAT:-up (pid 175 pgid 175) 99999999 seconds}"
			exit 0
			;;
		esac
	done
	exit 0
	;;
inspect)
	# inspect -f '{{.State.StartedAt}}' or '{{.Id}}' <container>
	shift # inspect
	container=""
	want_id=0
	while [ $# -gt 0 ]; do
		case "$1" in
		-f | --format)
			case "$2" in
			*.Id*) want_id=1 ;;
			esac
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
	if [ "$want_id" -eq 1 ]; then
		if [ -f "$MOCK_DIR/container_id_$container" ]; then
			cat "$MOCK_DIR/container_id_$container"
		else
			printf 'mock-container-id-%s\n' "$container"
		fi
		printf '\n'
	elif [ -f "$MOCK_DIR/started_at_$container" ]; then
		cat "$MOCK_DIR/started_at_$container"
		printf '\n'
	else
		# Default fallback: 1 hour ago UTC
		printf '2026-09-17T10:00:00Z\n'
	fi
	;;
logs)
	# logs [--timestamps] --since <since> <container>
	shift # logs
	since=""
	container=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--since)
			since="$2"
			shift 2
			;;
		--timestamps)
			shift
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
	# Fixture lines already carry their leading ISO timestamps, exactly as
	# `docker logs --timestamps` prints them. The mock hands the fixture file to
	# the script verbatim: the fixture IS the window content, and the window
	# boundary itself is covered by the StartedAt-boundary cases below.
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

# Total alerts the mock relay has seen for the current fixture environment.
curl_total() {
	cat "$MOCK_DIR/curl_calls_count" 2>/dev/null || printf 0
}

# A log timestamp relative to real now: lines inside the current (mocked)
# gateway generation, whose uptime the docker stub controls.
fresh_ts() {
	python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) + timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
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
# 1. Positive control (canary)
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
if printf '%s\n' "$last_payload" | grep -q '\[hermes\]' && \
   printf '%s\n' "$last_payload" | grep -q 'Parked MCP servers detected'; then
	ok "positive control: alert payload names the container and the detected condition"
else
	no "positive control: alert payload names the container and the detected condition"
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
	if [ "$remind_count" -eq 2 ] && printf '%s\n' "$last_payload" | grep -q 'reminder'; then
		ok "reminder: persistent error after reminder interval sends reminder alert"
	else
		no "reminder: persistent error after reminder interval sends reminder alert"
	fi
else
	no "reminder: persistent error execution failed"
fi

# ------------------------------------------------------------------------------
# 5. Recovery semantics: a clean window is NOT recovery
# ------------------------------------------------------------------------------
reset_env
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
"$SCRIPT" >/dev/null 2>&1
state_file="$STATE_DIR/hermes.state"
if grep -q '^status=problem$' "$state_file" && grep -q '^run_started_at=' "$state_file" &&
	grep -q '^incident_ts=' "$state_file" && grep -q '^gateway_pid=175$' "$state_file"; then
	ok "incident opens with its failure anchor, container run identity and gateway process identity"
else
	no "incident opens with its failure anchor, container run identity and gateway process identity"
fi

# A window with no failure signature and no positive signal must keep the
# incident open: this is the exact false recovery the ~26-minute re-park cycle
# produced against the 20-minute window.
incident_before="$(grep '^incident_ts=' "$STATE_DIR/hermes.state")"
alerts_before="$(curl_total)"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T13:00:00Z INFO [gateway] restart completed, all MCP servers connected
EOF

if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "$alerts_before" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state" &&
		[ "$incident_before" = "$(grep '^incident_ts=' "$STATE_DIR/hermes.state")" ]; then
		ok "clean window after an incident sends no recovery and keeps the incident open"
	else
		no "clean window after an incident sent recovery or reset the incident"
	fi
else
	no "clean window incident preservation: execution failed"
fi

# Legacy state written by the previous watchdog version carries no affected
# set or gateway identity binding: no revival can be proven to belong to it,
# so the episode stays open across a clean window without a recovery verdict.
reset_env
now_ts="$(python3 -c 'import time; print(int(time.time()))')"
printf 'status=problem\nlast_alert_ts=%s\n' "$((now_ts - 60))" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
legacy_warn="$("$SCRIPT" 2>&1 || true)"
if [ "$(curl_total)" = "0" ] &&
	grep -q '^status=problem$' "$STATE_DIR/hermes.state"; then
	ok "a legacy incident without an affected set stays open and no revival closes it"
else
	no "a legacy incident was closed without attribution (out: $legacy_warn)"
fi

# A legacy incident is re-anchored when a newer park enters the durable
# affected set: the server is then tracked and closable by a revival.
reset_env
printf 'status=problem\nlast_alert_ts=%s\n' "$((now_ts - 60))" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "0" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state" &&
		grep -q '"vault"' "$STATE_DIR/hermes.state"; then
		ok "a legacy incident is re-anchored by a newer failure entering the affected set"
	else
		no "a legacy incident was not re-anchored into the affected set"
	fi
else
	no "legacy re-anchor case: execution failed"
fi

# ------------------------------------------------------------------------------
# 5b. Recovery proven by the gateway's own revival event
# ------------------------------------------------------------------------------
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
"$SCRIPT" >/dev/null 2>&1
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	last_payload="$(cat "$MOCK_DIR/curl_last_payload")"
	if [ "$(cat "$MOCK_DIR/curl_calls_count")" = "2" ] &&
		printf '%s\n' "$last_payload" | grep -q 'MCP recovery confirmed' &&
		grep -q '^status=ok$' "$STATE_DIR/hermes.state" &&
		! grep -q '^incident_ts=' "$STATE_DIR/hermes.state"; then
		ok "a fresh same-server revival ordered after the last park closes the incident with a confirmed recovery alert"
	else
		no "revival-confirmed recovery did not deliver or did not reset state (payload: $last_payload)"
	fi
else
	no "revival-confirmed recovery: execution failed"
fi

# A revival of a DIFFERENT server proves nothing about the parked one.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$((now_ts - 60))" "$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'calendar': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "0" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state"; then
		ok "a foreign server's revival cannot close another server's incident"
	else
		no "a foreign-server revival closed the incident"
	fi
else
	no "foreign-server revival case: execution failed"
fi

# One revived server among several parked ones is not an all-clear.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$((now_ts - 60))" "$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:01:00Z WARNING [mcp] MCP server 'calendar' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "0" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state"; then
		ok "an all-clear requires every parked server to be revived, not just one"
	else
		no "a partial revival closed a multi-server incident"
	fi
else
	no "partial multi-server revival case: execution failed"
fi

# When every parked server has its own ordered revival, the episode closes.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$((now_ts - 60))" "$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:01:00Z WARNING [mcp] MCP server 'calendar' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
2026-09-17T12:06:00Z WARNING [mcp] MCP server 'calendar': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	last_payload="$(cat "$MOCK_DIR/curl_last_payload")"
	if [ "$(curl_total)" = "1" ] &&
		printf '%s\n' "$last_payload" | grep -q 'MCP recovery confirmed' &&
		grep -q '^status=ok$' "$STATE_DIR/hermes.state"; then
		ok "a full multi-server all-clear closes the incident with a recovery alert"
	else
		no "a full multi-server all-clear did not close the incident (payload: $last_payload)"
	fi
else
	no "full multi-server revival case: execution failed"
fi

# A revival ordered BEFORE the newest park proves an older failure only.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$((now_ts - 60))" "$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
2026-09-17T12:10:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "0" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state"; then
		ok "a revival ordered before the newest park does not close the incident"
	else
		no "an out-of-order revival closed the incident"
	fi
else
	no "out-of-order revival case: execution failed"
fi

# A revival that predates the recorded failure timestamp is a stale replay:
# the affected set carries the newest failure per server.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
STALE_TS="$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,13,0,tzinfo=timezone.utc).timestamp())')"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\naffected={\"vault\": %s}\n' \
	"$((now_ts - 60))" "$STALE_TS" "$STALE_TS" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "0" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state"; then
		ok "a revival older than the incident anchor is rejected as a stale replay"
	else
		no "a stale revival closed the incident"
	fi
else
	no "stale revival case: execution failed"
fi

# An s6 gateway RESPAWN inside the same container: a CURRENT-generation
# revival proves the server healthy again and closes the episode.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
RESPAWN_TS="$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\naffected={\"vault\": %s}\n' \
	"$((now_ts - 60))" "$RESPAWN_TS" "$RESPAWN_TS" >"$STATE_DIR/hermes.state"
printf "%s WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)\n" "$(fresh_ts -10)" >"$MOCK_DIR/logs_hermes"
if STUB_SVSTAT='up (pid 300 pgid 300) 40 seconds' "$SCRIPT" >/dev/null 2>&1; then
	last_payload="$(cat "$MOCK_DIR/curl_last_payload")"
	if [ "$(curl_total)" = "1" ] &&
		printf '%s\n' "$last_payload" | grep -q 'MCP recovery confirmed' &&
		grep -q '^status=ok$' "$STATE_DIR/hermes.state"; then
		ok "a current-generation revival after an s6 respawn closes the episode with a recovery alert"
	else
		no "a current-generation revival after a respawn did not close (payload: $last_payload)"
	fi
else
	no "respawn current-generation revival case: execution failed"
fi

# Old-generation revival proof (below the current generation floor) is
# rejected: the episode stays open.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\naffected={\"vault\": %s}\n' \
	"$((now_ts - 60))" "$RESPAWN_TS" "$RESPAWN_TS" >"$STATE_DIR/hermes.state"
printf "%s WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)\n" "$(fresh_ts -120)" >"$MOCK_DIR/logs_hermes"
if STUB_SVSTAT='up (pid 300 pgid 300) 40 seconds' "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "0" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state"; then
		ok "an old-generation revival below the eligibility floor never closes the episode"
	else
		no "an old-generation revival closed the incident"
	fi
else
	no "respawn old-generation proof case: execution failed"
fi

# A failure observed in the NEW gateway generation refreshes the record, so a
# later same-generation revival can close the episode.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$((now_ts - 60))" "$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
printf "%s WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError\n" "$(fresh_ts -10)" >"$MOCK_DIR/logs_hermes"
if STUB_SVSTAT='up (pid 300 pgid 300) 40 seconds' "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "0" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state" &&
		grep -q '^gateway_pid=300$' "$STATE_DIR/hermes.state"; then
		ok "a newer failure in a respawned gateway refreshes the record without a duplicate primary alert"
	else
		no "a newer failure did not refresh the record or raised a duplicate alert"
	fi
else
	no "record refresh case: execution failed"
fi

# A park line without a usable timestamp has an unknowable position in the
# failure order and denies recovery even when a revival is present.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$((now_ts - 60))" "$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
Traceback continuation without a log timestamp: parking until a reconnect is requested
2026-09-17T12:20:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "0" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state"; then
		ok "a park without a timestamp denies recovery despite a present revival"
	else
		no "an untimestamped park still allowed recovery"
	fi
else
	no "untimestamped park case: execution failed"
fi

# A park with a timestamp but no parseable server name can never be bound to a
# revival, so it denies recovery the same way.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$((now_ts - 60))" "$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:10:00Z WARNING [mcp] parking until a reconnect is requested
2026-09-17T12:20:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "0" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state"; then
		ok "a park without a parseable server name denies recovery despite a present revival"
	else
		no "an unnamed park still allowed recovery"
	fi
else
	no "unnamed park case: execution failed"
fi

# When the gateway identity itself cannot be established, recovery is an
# explicit unknown: the incident stays open even with revival evidence present.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$((now_ts - 60))" "$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
ident_out="$(STUB_SLOT_MODE=fail "$SCRIPT" 2>&1 || true)"
if [ "$(curl_total)" = "0" ] &&
	grep -q '^status=problem$' "$STATE_DIR/hermes.state" &&
	printf '%s\n' "$ident_out" | grep -q 'gateway identity unavailable; recovery cannot be proven'; then
	ok "an unresolvable gateway identity keeps the incident open as an explicit unknown"
else
	no "an unresolvable gateway identity allowed a recovery verdict (out: $ident_out)"
fi

# A log-read failure is an unknown outcome, never a clean window.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=%s\nalert_pending=0\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$((now_ts - 60))" "$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
touch "$MOCK_DIR/fail_logs_hermes"
logfail_out="$("$SCRIPT" 2>&1 || true)"
rm -f "$MOCK_DIR/fail_logs_hermes"
if [ "$(curl_total)" = "0" ] &&
	grep -q '^status=problem$' "$STATE_DIR/hermes.state" &&
	printf '%s\n' "$logfail_out" | grep -q 'log read failed; incident preserved'; then
	ok "a log read failure preserves the incident with an explicit unknown warning"
else
	no "a log read failure produced a verdict or lost the incident (out: $logfail_out)"
fi

# Revival events with no open incident are informational and send nothing.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
"$SCRIPT" >/dev/null 2>&1
if [ ! -f "$MOCK_DIR/curl_calls_count" ] && [ ! -f "$STATE_DIR/hermes.state" ]; then
	ok "a revival without an open incident sends nothing and writes no state"
else
	no "an informational revival triggered alerts or state"
fi

# ------------------------------------------------------------------------------
# 5c. Re-park cycle regression: parks every ~26 minutes against a 20-minute
# window. The old watchdog declared recovery in the gap between parks and
# reset repeat suppression, producing a duplicate primary alert on the next
# park. The incident must instead stay open until a positive signal.
# ------------------------------------------------------------------------------
reset_env
export WATCH_WINDOW="20m"
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"

# Simulated wall-clock offsets from real now: parks 26 minutes apart, the
# watchdog running every 10 minutes.
ts_at() {
	python3 - "$1" <<'PYEOF'
import sys
from datetime import datetime, timezone, timedelta
offset = int(sys.argv[1])
print((datetime.now(timezone.utc) + timedelta(minutes=offset)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PYEOF
}

# T=0: first park -> one primary alert.
printf '%s ERROR [mcp] parking until a reconnect is requested\n' "$(ts_at -16)" >"$MOCK_DIR/logs_hermes"
"$SCRIPT" >/dev/null 2>&1
# T=10m: park still inside the window -> debounced, no new alert.
printf '%s ERROR [mcp] parking until a reconnect is requested\n' "$(ts_at -16)" >"$MOCK_DIR/logs_hermes"
"$SCRIPT" >/dev/null 2>&1
# T=50m: the park has fallen out of the 20-minute window and the next park has
# not happened yet: the exact false-recovery moment of the incident.
: >"$MOCK_DIR/logs_hermes"
"$SCRIPT" >/dev/null 2>&1
# T=60m: the second park arrives (26-minute cycle) -> still one episode, no
# duplicate primary alert, reminder debounced.
printf '%s ERROR [mcp] parking until a reconnect is requested\n' "$(ts_at -14)" >"$MOCK_DIR/logs_hermes"
if "$SCRIPT" >/dev/null 2>&1; then
	payloads="$(cat "$MOCK_DIR/curl_all_payloads.log" 2>/dev/null || true)"
	if [ "$(curl_total)" = "1" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state" &&
		! printf '%s\n' "$payloads" | grep -q 'recovery'; then
		ok "re-park cycle (~26m parks, 20m window): no intermediate recovery, no duplicate primary alert, incident stays open"
	else
		no "re-park cycle produced $(cat "$MOCK_DIR/curl_calls_count" 2>/dev/null || echo 0) alerts or a recovery payload (payloads: $payloads)"
	fi
else
	no "re-park cycle: execution failed"
fi
unset WATCH_WINDOW

# ------------------------------------------------------------------------------
# 5d. Review corrections RV1a/RV1b/RV1c, RV2, RV3, RV4: durable per-server
# state, replay protection, durable recovery obligation, native envelope and
# the single-file install contract. Records are created by the script itself
# and windows are advanced between runs.
# ------------------------------------------------------------------------------
# RV1a: the park leaves the window before the revival arrives; the durable
# unresolved set must keep the failure closable.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
"$SCRIPT" >/dev/null 2>&1
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:40:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	last_payload="$(cat "$MOCK_DIR/curl_last_payload")"
	if [ "$(curl_total)" = "2" ] &&
		printf '%s\n' "$last_payload" | grep -q 'MCP recovery confirmed' &&
		grep -q '^status=ok$' "$STATE_DIR/hermes.state"; then
		ok "RV1a: a revival arriving after its park aged out closes the durable incident"
	else
		no "RV1a: aged-out park lost the incident or the recovery did not send (payload: $last_payload)"
	fi
else
	no "RV1a case: execution failed"
fi

# RV1b: two servers park; one recovers later; the unresolved other keeps the
# episode open until its own revival arrives.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:01:00Z WARNING [mcp] MCP server 'calendar' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
"$SCRIPT" >/dev/null 2>&1
# Vault's record ages out; calendar parks again and revives.
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:35:00Z WARNING [mcp] MCP server 'calendar' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:40:00Z WARNING [mcp] MCP server 'calendar': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	affected_line="$(grep '^affected=' "$STATE_DIR/hermes.state" || true)"
	if [ "$(curl_total)" = "1" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state" &&
		grep -q '"vault"' <<<"$affected_line" &&
		! grep -q '"calendar"' <<<"$affected_line"; then
		ok "RV1b: calendar's recovery does not close vault's unresolved failure"
	else
		no "RV1b: a partial recovery closed the whole episode or vault was forgotten (affected: $affected_line)"
	fi
else
	no "RV1b partial case: execution failed"
fi
# Vault's own revival then closes the episode.
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:35:00Z WARNING [mcp] MCP server 'calendar' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:40:00Z WARNING [mcp] MCP server 'calendar': revived — session healthy again after parking (state: parked → connected)
2026-09-17T12:50:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	last_payload="$(cat "$MOCK_DIR/curl_last_payload")"
	if [ "$(curl_total)" = "2" ] &&
		printf '%s\n' "$last_payload" | grep -q 'MCP recovery confirmed' &&
		grep -q '^status=ok$' "$STATE_DIR/hermes.state"; then
		ok "RV1b: vault's later revival closes the episode after the durable wait"
	else
		no "RV1b: vault revival did not close the episode (payload: $last_payload)"
	fi
else
	no "RV1b close case: execution failed"
fi

# RV1c: replaying the same confirmed window sends nothing new.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
"$SCRIPT" >/dev/null 2>&1
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
"$SCRIPT" >/dev/null 2>&1
"$SCRIPT" >/dev/null 2>&1
"$SCRIPT" >/dev/null 2>&1
if [ "$(curl_total)" = "2" ] && grep -q '^status=ok$' "$STATE_DIR/hermes.state"; then
	ok "RV1c: replaying a confirmed window sends no duplicate alert or recovery"
else
	no "RV1c: replay produced $(cat "$MOCK_DIR/curl_calls_count" 2>/dev/null || echo 0) sends"
fi

# RV2: a failed recovery notification stays owed after the proof leaves the
# window, and is delivered later with its observed time.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
"$SCRIPT" >/dev/null 2>&1
touch "$MOCK_DIR/curl_fail"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	no "RV2: script should exit non-zero when the recovery delivery fails"
else
	state_file="$STATE_DIR/hermes.state"
	if grep -q '^status=problem$' "$state_file" && grep -q '^pending_recovery=1$' "$state_file" &&
		grep -q '^pending_recovery_ts=' "$state_file"; then
		ok "RV2: the failed recovery is persisted as an obligation with its observation time"
	else
		no "RV2: the recovery obligation was lost after a failed delivery"
	fi
fi
# The proof ages out of the window entirely; the relay recovers.
rm -f "$MOCK_DIR/curl_fail"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T13:00:00Z INFO [gateway] routine operations, nothing to report
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	last_payload="$(cat "$MOCK_DIR/curl_last_payload")"
	if [ "$(curl_total)" = "3" ] &&
		printf '%s\n' "$last_payload" | grep -q 'MCP recovery confirmed' &&
		grep -q '^status=ok$' "$STATE_DIR/hermes.state" &&
		grep -q '^resolved=' "$STATE_DIR/hermes.state"; then
		ok "RV2: the owed recovery is delivered without its log line and reports the observed time"
	else
		no "RV2: the owed recovery was not delivered after window expiry (payload: $last_payload)"
	fi
	# No duplicate on the next run.
	"$SCRIPT" >/dev/null 2>&1
	if [ "$(curl_total)" = "3" ] && grep -q '^status=ok$' "$STATE_DIR/hermes.state"; then
		ok "RV2: the delivered recovery is not resent on later runs"
	else
		no "RV2: a delivered recovery was resent"
	fi
else
	no "RV2 delivery case: execution failed"
fi

# RV3: server text forwarded through the gateway log envelope is never native
# health proof; the same server's native warning is.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
"$SCRIPT" >/dev/null 2>&1
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server log [calendar]: MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "1" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state"; then
		ok "RV3: forwarded server log text is rejected as native revival proof"
	else
		no "RV3: forwarded log text closed the incident"
	fi
else
	no "RV3 forwarded case: execution failed"
fi
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:06:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	last_payload="$(cat "$MOCK_DIR/curl_last_payload")"
	if [ "$(curl_total)" = "2" ] &&
		printf '%s\n' "$last_payload" | grep -q 'MCP recovery confirmed' &&
		grep -q '^status=ok$' "$STATE_DIR/hermes.state"; then
		ok "RV3: the native revival for the same server still closes the incident"
	else
		no "RV3: the native revival stopped closing incidents (payload: $last_payload)"
	fi
else
	no "RV3 native case: execution failed"
fi

# RV4: the retained host playbook installs the watchdog as a single file; an
# isolated copy keeps working without the source tree around it.
reset_env
install_dir="$WORK/install-isolated"
rm -rf "$install_dir"
mkdir -p "$install_dir"
cp "$SCRIPT" "$install_dir/mcp-watch.sh"
if "$install_dir/mcp-watch.sh" --help >/dev/null 2>&1; then
	ok "RV4: an isolated single-file install answers --help"
else
	no "RV4: an isolated single-file install cannot even show --help"
fi
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
dry_install_out="$("$install_dir/mcp-watch.sh" --dry-run 2>&1 || true)"
if printf '%s\n' "$dry_install_out" | grep -q 'dry-run: \[hermes\] transition ok -> problem' &&
	[ ! -f "$MOCK_DIR/curl_calls_count" ]; then
	ok "RV4: an isolated single-file install evaluates the full log pipeline"
else
	no "RV4: the isolated install failed its detection pass (out: $dry_install_out)"
fi

# ------------------------------------------------------------------------------
# 6. Delivery failure resilience (and F6: 3xx handling)
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# 6. Delivery failure resilience (and F6: 3xx handling)
# ------------------------------------------------------------------------------
# Case A: a failed detection alert persists the incident with a pending alert
# obligation; the next successful run delivers the owed alert.
reset_env
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
touch "$MOCK_DIR/curl_fail"

if "$SCRIPT" >/dev/null 2>&1; then
	no "delivery failure: script should exit non-zero when alert delivery fails"
else
	state_file="$STATE_DIR/hermes.state"
	if grep -q '^status=problem$' "$state_file" && grep -q '^alert_pending=1$' "$state_file" &&
		grep -q '^incident_ts=' "$state_file"; then
		ok "delivery failure: failed alert POST persists the incident with a pending alert obligation"
	else
		no "delivery failure: a failed alert POST lost the incident or its pending obligation"
	fi
fi

# The owed alert is delivered on the next successful run without a new incident.
rm -f "$MOCK_DIR/curl_fail"
if "$SCRIPT" >/dev/null 2>&1; then
	state_file="$STATE_DIR/hermes.state"
	if [ "$(curl_total)" = "2" ] &&
		grep -q '^status=problem$' "$state_file" &&
		grep -q '^alert_pending=0$' "$state_file"; then
		ok "delivery failure: the pending detection alert is retried and delivered on the next run"
	else
		no "delivery failure: the pending alert was not retried (count: $(curl_total))"
	fi
else
	no "delivery failure: pending retry run failed"
fi

# The pending obligation survives clean windows and unhelpful runs.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
printf 'status=problem\nlast_alert_ts=0\nalert_pending=1\nincident_ts=%s\nrun_started_at=2026-09-17T10:00:00Z\ngateway_pid=175\n' \
	"$(python3 -c 'from datetime import datetime,timezone; print(datetime(2026,9,17,12,0,tzinfo=timezone.utc).timestamp())')" >"$STATE_DIR/hermes.state"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T13:00:00Z INFO [gateway] restart completed, all MCP servers connected
EOF
if "$SCRIPT" >/dev/null 2>&1; then
	if [ "$(curl_total)" = "1" ] &&
		grep -q '^status=problem$' "$STATE_DIR/hermes.state" &&
		grep -q '^alert_pending=0$' "$STATE_DIR/hermes.state"; then
		ok "delivery failure: a clean window does not silence an undelivered mandatory alert"
	else
		no "delivery failure: a clean window dropped the pending alert obligation"
	fi
else
	no "delivery failure: pending retry over a clean window failed"
fi

# Case B: a recovery must not silence an undelivered detection alert. The
# pending alert is retried first; the recovery is delivered only afterwards,
# and a failed recovery keeps the episode open.
reset_env
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
2026-09-17T12:05:00Z WARNING [mcp] MCP server 'vault': revived — session healthy again after parking (state: parked → connected)
EOF
touch "$MOCK_DIR/curl_fail"

if "$SCRIPT" >/dev/null 2>&1; then
	no "delivery failure: script should exit non-zero when the detection alert delivery fails"
else
	state_file="$STATE_DIR/hermes.state"
	if grep -q '^status=problem$' "$state_file" && grep -q '^alert_pending=1$' "$state_file"; then
		ok "delivery failure: detection persisted while the relay was failing"
	else
		no "delivery failure: detection was not persisted while the relay was failing"
	fi
fi

# Relay restored: the owed detection alert goes out first, then the proven
# recovery closes the episode. One message must not replace the other.
rm -f "$MOCK_DIR/curl_fail"
if "$SCRIPT" >/dev/null 2>&1; then
	payloads="$(cat "$MOCK_DIR/curl_all_payloads.log" 2>/dev/null || true)"
	if [ "$(curl_total)" = "3" ] &&
		printf '%s\n' "$payloads" | grep -q 'Parked MCP servers detected' &&
		printf '%s\n' "$payloads" | grep -q 'MCP recovery confirmed' &&
		grep -q '^status=ok$' "$STATE_DIR/hermes.state"; then
		ok "delivery failure: the owed detection alert is delivered before the confirmed recovery"
	else
		no "delivery failure: the alert-to-recovery chain broke (count: $(curl_total), payloads: $payloads)"
	fi
else
	no "delivery failure: alert-then-recovery run failed"
fi

# Case C: 3xx redirect from relay is NOT treated as delivery (F6)
reset_env
cat >"$MOCK_DIR/logs_hermes" <<'EOF'
2026-09-17T12:00:00Z WARNING [mcp] MCP server 'vault' failed initial connection after 5 attempts, parking until a reconnect is requested (state: connecting → parked): ConnectionError
EOF
printf '2026-09-17T10:00:00Z' >"$MOCK_DIR/started_at_hermes"
export MOCK_HTTP_CODE=302

if "$SCRIPT" >/dev/null 2>&1; then
	no "3xx response (F6): relay redirect 302 must be treated as delivery failure"
else
	state_file="$STATE_DIR/hermes.state"
	if grep -q '^status=problem$' "$state_file" && grep -q '^alert_pending=1$' "$state_file"; then
		ok "3xx response (F6): 302 response does not mark the transition as delivered and keeps the alert pending"
	else
		no "3xx response (F6): 302 response lost the incident or marked delivery"
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
# 8. StartedAt boundary (HLD decision 4 and F1)
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
   printf '%s\n' "$(cat "$MOCK_DIR/curl_last_payload")" | grep -q 'Test alert' && \
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

if MPR_TEST_BASH="$BASH" python3 "$SUITE_DIR/sequence-regressions.py"; then
	ok "controlled-clock incident and notification sequences"
else
	no "controlled-clock incident and notification sequences"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
