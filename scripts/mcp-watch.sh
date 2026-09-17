#!/usr/bin/env bash
# Watchdog for parked Hermes MCP OAuth servers.
#
# Inspects Hermes container logs for MCP OAuth lock freeze signatures
# within a rolling time window bounded by container start time, manages alert
# debouncing/reminders, and delivers alerts to Telegram via alert-relay.
set -euo pipefail
umask 077

log() { printf '%s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Ensure python3 is available for robust time, URL, and JSON operations across macOS and Linux.
command -v python3 >/dev/null 2>&1 || die "python3 is required but not found in PATH"

# Default configuration
RELAY_URL="${RELAY_URL:-}"
RELAY_TOKEN="${RELAY_TOKEN:-}"
WATCH_CONTAINERS="${WATCH_CONTAINERS:-hermes}"
WATCH_WINDOW="${WATCH_WINDOW:-20m}"
WATCH_REMIND_SECONDS="${WATCH_REMIND_SECONDS:-43200}"
WATCH_STATE_DIR="${WATCH_STATE_DIR:-/var/lib/hermes-mcp-watch}"
DEFAULT_MARKERS="parking until a reconnect is requested
The current task is not holding this lock"
WATCH_MARKERS="${WATCH_MARKERS:-$DEFAULT_MARKERS}"

DRY_RUN=0
TEST_ALERT=0

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--test-alert)
		TEST_ALERT=1
		shift
		;;
	-h | --help)
		cat <<'EOF'
Usage: mcp-watch.sh [OPTIONS]

Options:
  --dry-run     Check logs and evaluate state transitions without sending alerts or writing state.
  --test-alert  Send a test alert through alert-relay to verify delivery; state is not touched.
  -h, --help    Show this help message.

Environment variables:
  RELAY_URL             URL of alert-relay endpoint (required, https:// or loopback http://)
  RELAY_TOKEN           Secret project token for alert-relay (required)
  WATCH_CONTAINERS      Space-separated list of container names (default: "hermes")
  WATCH_WINDOW          Log search window (e.g. "20m", "1200s", default: "20m")
  WATCH_REMIND_SECONDS  Interval between reminders if problem persists (default: 43200 = 12h)
  WATCH_MARKERS         Error signatures separated by newline or | (default: upstream MCP freeze signatures)
  WATCH_STATE_DIR       Directory to store per-container state files (default: "/var/lib/hermes-mcp-watch")
EOF
		exit 0
		;;
	*)
		die "unknown option: $1 (see --help)"
		;;
	esac
done

# Fail-fast validation of required variables
[ -n "$RELAY_TOKEN" ] || die "RELAY_TOKEN is required and cannot be empty"
[ -n "$RELAY_URL" ] || die "RELAY_URL is required and cannot be empty"

sanitize_url() {
	local raw="$1"
	python3 -c '
import sys
from urllib.parse import urlparse
try:
    u = urlparse(sys.argv[1])
    host = u.hostname or ""
    try:
        port = u.port
    except ValueError:
        port = None
    if port:
        host = f"{host}:{port}"
    clean = u._replace(netloc=host).geturl()
    print(clean if clean else "<invalid URL>")
except Exception:
    print("<invalid URL>")
' "$raw"
}

# Strictly validate RELAY_URL scheme and host (https or loopback http)
if ! python3 -c '
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
if u.scheme == "https" and bool(u.netloc):
    sys.exit(0)
if u.scheme == "http" and (u.hostname in ("localhost", "::1") or (u.hostname or "").startswith("127.")):
    sys.exit(0)
sys.exit(1)
' "$RELAY_URL"; then
	die "RELAY_URL must use https or loopback http (localhost, ::1, or a 127.x address), got: $(sanitize_url "$RELAY_URL")"
fi

instance_desc() {
	local c="$1"
	case "$c" in
	hermes) printf 'личный экземпляр' ;;
	*) printf 'экземпляр %s' "$c" ;;
	esac
}

get_now_ts() {
	python3 -c 'import time; print(int(time.time()))'
}

get_effective_since() {
	local window="$1" started_at="$2"
	python3 -c '
import re, sys
from datetime import datetime, timezone, timedelta

def parse_window(w_str):
    s = w_str.strip()
    if s.endswith("m"):
        return int(s[:-1]) * 60
    elif s.endswith("s"):
        return int(s[:-1])
    elif s.endswith("h"):
        return int(s[:-1]) * 3600
    else:
        return int(s) * 60

def parse_iso(ts_str):
    if not ts_str:
        return None
    s = ts_str.strip()
    if s.startswith("0001-01-01"):
        return None
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s)
    try:
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt
    except Exception:
        sys.stderr.write(f"warning: cannot parse StartedAt \x27{ts_str}\x27; window boundary disabled\n")
        return None

window_sec = parse_window(sys.argv[1])
started_str = sys.argv[2] if len(sys.argv) > 2 else ""

now = datetime.now(timezone.utc)
window_since = now - timedelta(seconds=window_sec)
started_dt = parse_iso(started_str)

if started_dt is not None and started_dt > window_since:
    effective = started_dt
else:
    effective = window_since

print(effective.strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$window" "$started_at"
}

# Temporary files for markers and curl credentials config
MARKERS_TMP="$(mktemp)"
CURL_CONFIG="$(mktemp)"
chmod 0600 "$CURL_CONFIG"
printf 'header = "X-Project-Token: %s"\n' "$RELAY_TOKEN" >"$CURL_CONFIG"

trap 'rm -f "$MARKERS_TMP" "$CURL_CONFIG"' EXIT

# Safely filter markers without failing under pipefail if empty
filtered_markers="$(printf '%s\n' "$WATCH_MARKERS" | tr '|' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true)"
[ -n "$filtered_markers" ] || die "WATCH_MARKERS is empty or contains no valid patterns"
printf '%s\n' "$filtered_markers" >"$MARKERS_TMP"

send_alert() {
	local message="$1"
	local payload curl_out curl_rc http_code

	payload="$(python3 -c 'import json, sys; print(json.dumps({"text": sys.argv[1]}, ensure_ascii=False))' "$message")"

	set +e
	curl_out="$(curl --config "$CURL_CONFIG" \
		--silent --show-error --fail \
		--connect-timeout 10 \
		--max-time 15 \
		-H "Content-Type: application/json" \
		-X POST \
		--data "$payload" \
		--write-out '\n%{http_code}' \
		"$RELAY_URL" 2>&1)"
	curl_rc=$?
	set -e

	if [ "$curl_rc" -ne 0 ]; then
		# Never output the token or secrets
		log "failed to deliver alert to $(sanitize_url "$RELAY_URL"): $curl_out"
		return 1
	fi

	http_code="$(printf '%s\n' "$curl_out" | tail -n 1)"
	case "$http_code" in
	2[0-9][0-9])
		return 0
		;;
	*)
		log "failed to deliver alert to $(sanitize_url "$RELAY_URL"): unexpected HTTP status $http_code"
		return 1
		;;
	esac
}

# Handle --test-alert mode: send test message and exit
if [ "$TEST_ALERT" -eq 1 ]; then
	test_message="[mcp-watch] Тестовое оповещение сторожа MCP. Канал доставки настроен корректно."
	if send_alert "$test_message"; then
		log "test alert sent successfully to $(sanitize_url "$RELAY_URL")"
		exit 0
	else
		die "failed to send test alert"
	fi
fi

# Prepare state directory with owner-only permissions unless dry run
if [ "$DRY_RUN" -eq 0 ]; then
	mkdir -p "$WATCH_STATE_DIR"
	chmod 0700 "$WATCH_STATE_DIR"
fi

now_ts="$(get_now_ts)"
run_failed=0

for container in $WATCH_CONTAINERS; do
	desc="$(instance_desc "$container")"

	# Check container existence and StartedAt
	started_at="$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null || true)"
	if [ -z "$started_at" ]; then
		log "warning: container '$container' inspect failed or container not found; skipping"
		continue
	fi

	# Boundary check: effective since is max(now - window, StartedAt)
	effective_since="$(get_effective_since "$WATCH_WINDOW" "$started_at")"

	# Fetch logs since effective timestamp
	container_logs="$(docker logs --since "$effective_since" "$container" 2>&1 || true)"

	# Match against markers
	matched="$(printf '%s\n' "$container_logs" | grep -F -f "$MARKERS_TMP" || true)"
	if [ -n "$matched" ]; then
		has_problem=1
	else
		has_problem=0
	fi

	# Read previous state
	state_file="$WATCH_STATE_DIR/${container}.state"
	prev_status="ok"
	prev_alert_ts=0

	if [ -f "$state_file" ]; then
		while IFS='=' read -r key val || [ -n "$key" ]; do
			case "$key" in
			status) prev_status="$val" ;;
			last_alert_ts) prev_alert_ts="$val" ;;
			esac
		done <"$state_file"
	fi

	if [ "$has_problem" -eq 1 ]; then
		if [ "$prev_status" = "ok" ]; then
			# Transition: ok -> problem (Alert)
			msg="[${container}] Зафиксирована парковка MCP-серверов (${desc}): обнаружен маркер в логе."
			if [ "$DRY_RUN" -eq 1 ]; then
				log "dry-run: [${container}] transition ok -> problem (alert suppressed)"
			else
				if send_alert "$msg"; then
					tmp_state="$(mktemp "$WATCH_STATE_DIR/state.XXXXXX")"
					printf 'status=problem\nlast_alert_ts=%s\n' "$now_ts" >"$tmp_state"
					mv -f "$tmp_state" "$state_file"
					log "[${container}] transition ok -> problem (alert delivered)"
				else
					log "error: [${container}] failed to deliver alert; state not updated"
					run_failed=1
				fi
			fi
		else
			# Transition: problem -> problem (Debounce / Reminder)
			elapsed=$((now_ts - prev_alert_ts))
			if [ "$elapsed" -ge "$WATCH_REMIND_SECONDS" ]; then
				msg="[${container}] Напоминание: продолжается парковка MCP-серверов (${desc})."
				if [ "$DRY_RUN" -eq 1 ]; then
					log "dry-run: [${container}] transition problem -> problem (reminder suppressed, elapsed ${elapsed}s)"
				else
					if send_alert "$msg"; then
						tmp_state="$(mktemp "$WATCH_STATE_DIR/state.XXXXXX")"
						printf 'status=problem\nlast_alert_ts=%s\n' "$now_ts" >"$tmp_state"
						mv -f "$tmp_state" "$state_file"
						log "[${container}] reminder delivered (elapsed ${elapsed}s)"
					else
						log "error: [${container}] failed to deliver reminder; last_alert_ts not updated"
						run_failed=1
					fi
				fi
			else
				log "[${container}] problem persists; reminder debounced (${elapsed}s < ${WATCH_REMIND_SECONDS}s)"
			fi
		fi
	else
		if [ "$prev_status" = "problem" ]; then
			# Transition: problem -> ok (Recovery / Отбой)
			msg="[${container}] Отбой: маркеры парковки MCP-серверов (${desc}) больше не фиксируются."
			if [ "$DRY_RUN" -eq 1 ]; then
				log "dry-run: [${container}] transition problem -> ok (recovery suppressed)"
			else
				if send_alert "$msg"; then
					tmp_state="$(mktemp "$WATCH_STATE_DIR/state.XXXXXX")"
					printf 'status=ok\nlast_alert_ts=0\n' >"$tmp_state"
					mv -f "$tmp_state" "$state_file"
					log "[${container}] transition problem -> ok (recovery delivered)"
				else
					log "error: [${container}] failed to deliver recovery alert; state remains problem"
					run_failed=1
				fi
			fi
		else
			log "[${container}] ok (clean log)"
		fi
	fi
done

if [ "$run_failed" -ne 0 ]; then
	exit 1
fi
