#!/usr/bin/env bash
# Watchdog for parked Hermes MCP OAuth servers.
#
# Inspects Hermes container logs for MCP OAuth lock freeze signatures
# within a rolling time window bounded by container start time, manages alert
# debouncing/reminders, and delivers alerts to Telegram via alert-relay.
#
# Recovery semantics: a clean window is NOT recovery. An incident stays open
# until the affected client proves health again — the gateway's own native
# revival event emitted after a successful keepalive on the parked session —
# inside the same container run, ordered after the failure it closes.
#
# Durable state (review RV1): the record carries the unresolved failures per
# affected server, the processed/revived watermark per server, the container
# run and gateway process binding, and undelivered notification obligations.
# The rolling window selects NEW evidence; it never defines incident memory.
# Park or revival lines that a server already emitted (at or before its
# watermark) are replays and are ignored.
#
# Notification obligations (review RV2): detection and recovery alerts are
# queued independently of log evidence. A failed delivery stays owed and is
# retried without requiring the same log line to remain in the window; the
# recovery message reports the time the proof was OBSERVED, not delivery time.
#
# Native envelope (review RV3): only the gateway's own revival warning counts.
# Server-controlled text forwarded through the gateway's log-forwarding
# envelope ("MCP server log [<server>]: ...") is never positive proof.
#
# This script is self-contained on purpose: the retained host playbook
# installs it as a single file (review RV4). Its service-slot resolution is
# kept aligned with _lib.sh supervisor_service_path by review; change both
# together.
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
# Positive same-session health signal: the gateway emits this warning after a
# successful keepalive on a previously parked session (tools/mcp_tool_health.py
# _mark_session_proven in the pinned image). It exists only for a session that
# actually parked and then answered again inside one gateway generation.
DEFAULT_REVIVAL_MARKERS="revived — session healthy again after parking"
WATCH_REVIVAL_MARKERS="${WATCH_REVIVAL_MARKERS:-$DEFAULT_REVIVAL_MARKERS}"
# Profile whose supervised gateway service proves the gateway process identity.
WATCH_PROFILE="${WATCH_PROFILE:-default}"

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
  RELAY_URL              URL of alert-relay endpoint (required, https:// or loopback http://)
  RELAY_TOKEN            Secret project token for alert-relay (required)
  WATCH_CONTAINERS       Space-separated list of container names (default: "hermes")
  WATCH_WINDOW           Log search window (e.g. "20m", "1200s", default: "20m")
  WATCH_REMIND_SECONDS   Interval between reminders while the incident stays open (default: 43200 = 12h)
  WATCH_MARKERS          Park failure signatures separated by newline or | (default: upstream MCP freeze signatures)
  WATCH_REVIVAL_MARKERS  Positive revival signatures separated by newline or | (default: the gateway's own revival warning)
  WATCH_PROFILE          Gateway profile whose supervised service proves the gateway process identity (default: "default")
  WATCH_STATE_DIR        Directory to store per-container state files (default: "/var/lib/hermes-mcp-watch")

Recovery semantics: a clean window is not recovery. An incident opens on a park
signature and stays open across clean windows, log failures and gateway or
container restarts, with the unresolved failures kept per affected server in
state. It closes only when the gateway's own native revival warnings close
every unresolved failure of the current gateway process inside the same
container run. Undelivered detection and recovery notifications stay owed
until the relay accepts them, regardless of the log window. Forwarded server
log text is never accepted as native health proof.
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

# Resolve the supervised service slot for a gateway profile from the image
# itself. Self-contained twin of supervisor_service_path in _lib.sh (review
# RV4: the installed watchdog is a single file); keep the two aligned.
#
# The image's own manager answers with its own profile validation and slot
# composition, so a release that moves the scandir cannot be misread. A
# profile is screened locally before it reaches the container (the image rule
# is [a-z0-9][a-z0-9_-]*), and an answer that is not a single absolute path,
# or that cannot be obtained at all, is an error rather than a default.
watch_service_slot() {
	local container="$1" profile="$2" out

	[ -n "$profile" ] || {
		printf 'watch_service_slot: gateway profile is empty\n' >&2
		return 1
	}
	if ! [[ "$profile" =~ ^[abcdefghijklmnopqrstuvwxyz0123456789][abcdefghijklmnopqrstuvwxyz0123456789_-]*$ ]]; then
		printf 'watch_service_slot: profile must match [a-z0-9][a-z0-9_-]*, got "%s"\n' "$profile" >&2
		return 1
	fi

	if ! out="$(docker exec -e HERMES_MPR_PROFILE="$profile" "$container" /bin/sh -c '
		cd /opt/hermes || exit 3
		exec /opt/hermes/.venv/bin/python - <<PYEOF
import os, sys
from hermes_cli.service_manager import S6ServiceManager
try:
    print(S6ServiceManager()._service_dir(os.environ["HERMES_MPR_PROFILE"]))
except Exception as exc:
    print("image rejected profile: %s" % exc, file=sys.stderr)
    sys.exit(4)
PYEOF
	' 2>&1)"; then
		printf 'watch_service_slot: image %s did not resolve the gateway service slot: %s\n' \
			"$container" "$out" >&2
		return 1
	fi

	case "$out" in
	/*) ;;
	*)
		printf 'watch_service_slot: image %s returned no absolute service slot (read: %s)\n' \
			"$container" "${out:-<nothing>}" >&2
		return 1
		;;
	esac

	printf '%s\n' "$out"
}

# Prove which gateway process is currently running inside a watched container:
# pid plus the process start timestamp derived from the supervisor's uptime
# reading. Empty output means identity could not be established, and every
# recovery decision fails closed on that (an unknown generation keeps the
# incident open; it is never read as proof of anything).
gateway_identity() {
	local container="$1" service out pid secs now
	service="$(watch_service_slot "$container" "$WATCH_PROFILE")" || return 1
	if ! out="$(docker exec "$container" /command/s6-svstat "$service" 2>/dev/null)"; then
		return 1
	fi
	case "$out" in
	up*) ;;
	*) return 1 ;;
	esac
	pid="$(printf '%s' "$out" | sed -n 's/.*(pid \([0-9][0-9]*\).*/\1/p')"
	secs="$(printf '%s' "$out" | sed -n 's/.*) \([0-9][0-9]*\) seconds.*/\1/p')"
	[ -n "$pid" ] && [ -n "$secs" ] || return 1
	now="$(get_now_ts)"
	printf '%s|%s\n' "$pid" "$(python3 -c "print(int($now - $secs))")"
}

# Classify the fetched log window against the durable episode record and
# return the state transition inputs.
#
# Eligibility floor: lines older than the current gateway process start belong
# to a previous generation and never enter the record. Replays: a park at or
# before its server's revived watermark was already processed and is ignored
# (review RV1c). Native envelope (review RV3): a revival counts only when its
# message is the gateway's own warning; text forwarded through the
# "MCP server log [<server>]: " envelope is server-controlled content and is
# never positive proof. Parks carry the same envelope check for symmetry of
# attribution, though only revival is trusted for recovery.
#
# A park without a usable timestamp or server name cannot be bound to a
# revival. Its unattributed flag persists after the log window expires.
process_events() {
	local logs_file="$1" markers_file="$2" revival_file="$3" min_ts="$4" affected_json="$5" resolved_json="$6"
	python3 - "$logs_file" "$markers_file" "$revival_file" "$min_ts" "$affected_json" "$resolved_json" <<'PYEOF'
import json
import re
import sys
from datetime import datetime, timezone

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:?\d{2})) ")
NAME_RE = re.compile(r"MCP server '([^']+)'")
FORWARDED_RE = re.compile(r"MCP server log \[")

def parse_log_ts(token):
    s = token.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s)
    try:
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except Exception:
        return None

def load_patterns(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return [line.strip() for line in f if line.strip()]

def to_float(raw, default=None):
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default

logs_path, markers_path, revival_path, min_raw, affected_raw, resolved_raw = sys.argv[1:7]
park_patterns = load_patterns(markers_path)
revival_patterns = load_patterns(revival_path)
min_ts = to_float(min_raw)
affected = json.loads(affected_raw) if affected_raw else {}
resolved = json.loads(resolved_raw) if resolved_raw else {}

park_total = 0
untimestamped_parks = 0
unnamed_parks = 0
unnamed_openers = 0
named_openers = 0
revival_closures = {}
revival_watermarks = {}

events = []
with open(logs_path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        is_park = any(p in line for p in park_patterns)
        if not is_park and not any(p in line for p in revival_patterns):
            continue
        m = TS_RE.match(line)
        ts = parse_log_ts(m.group(1)) if m else None
        # The forwarding envelope carries server-controlled text; it is never
        # the gateway's own health verdict, in either direction.
        forwarded = bool(FORWARDED_RE.search(line))
        nm = NAME_RE.search(line)
        name = nm.group(1) if nm else None
        eligible = ts is not None and (min_ts is None or ts >= min_ts)
        if is_park:
            park_total += 1
            if forwarded:
                continue
            if ts is None:
                untimestamped_parks += 1
            elif not eligible:
                pass  # previous gateway generation evidence: never anchors
            elif name is None:
                unnamed_parks += 1
                unnamed_openers = 1
            else:
                watermark = to_float(resolved.get(name), None)
                if watermark is not None and ts <= watermark:
                    continue  # replay of an already processed failure
                # Pass one: every eligible named park enters the unresolved
                # set before any revival is matched, so line order in the log
                # stream cannot decide the outcome.
                affected[name] = max(float(affected.get(name, 0.0)), float(ts))
                named_openers = 1
        else:
            if forwarded:
                continue  # server-controlled text is never native health proof
            events.append((name, ts))

# Pass two: match revivals against the complete unresolved set. The
# eligibility floor applies here too: a revival from a previous gateway
# generation never closes anything.
for name, ts in events:
    if ts is None or name is None:
        continue
    if min_ts is not None and ts < min_ts:
        continue
    watermark = to_float(resolved.get(name), None)
    if watermark is not None and ts <= watermark:
        continue  # replay of an already processed revival
    park_ts = to_float(affected.get(name), None)
    if park_ts is not None and ts >= park_ts:
        revival_closures[name] = ts
    else:
        revival_watermarks[name] = ts

print(json.dumps({
    "park_total": park_total,
    "untimestamped_parks": untimestamped_parks,
    "unnamed_parks": unnamed_parks,
    "unnamed_openers": unnamed_openers,
    "named_openers": named_openers,
    "affected": affected,
    "revival_closures": revival_closures,
    "revival_watermarks": revival_watermarks,
}))
PYEOF
}

# Temporary files for markers, log fetch and curl credentials config
MARKERS_TMP="$(mktemp)"
REVIVAL_TMP="$(mktemp)"
LOGS_OUT="$(mktemp)"
CURL_CONFIG="$(mktemp)"
chmod 0600 "$CURL_CONFIG"
printf 'header = "X-Project-Token: %s"\n' "$RELAY_TOKEN" >"$CURL_CONFIG"

trap 'rm -f "$MARKERS_TMP" "$REVIVAL_TMP" "$LOGS_OUT" "$LOGS_OUT.err" "$CURL_CONFIG"' EXIT

# Safely filter markers without failing under pipefail if empty
filtered_markers="$(printf '%s\n' "$WATCH_MARKERS" | tr '|' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true)"
[ -n "$filtered_markers" ] || die "WATCH_MARKERS is empty or contains no valid patterns"
printf '%s\n' "$filtered_markers" >"$MARKERS_TMP"

filtered_revivals="$(printf '%s\n' "$WATCH_REVIVAL_MARKERS" | tr '|' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true)"
[ -n "$filtered_revivals" ] || die "WATCH_REVIVAL_MARKERS is empty or contains no valid patterns"
printf '%s\n' "$filtered_revivals" >"$REVIVAL_TMP"

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
	test_message="[mcp-watch] Test alert: alert delivery is configured and working."
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

	# Check container existence and StartedAt
	started_at="$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null || true)"
	if [ -z "$started_at" ]; then
		log "warning: container '$container' inspect failed or container not found; skipping"
		continue
	fi
	# Stable container identity, best effort: it distinguishes a recreated
	# container from a restarted one when combined with the run start time.
	container_id="$(docker inspect -f '{{.Id}}' "$container" 2>/dev/null || true)"

	# Boundary check: effective since is max(now - window, StartedAt)
	effective_since="$(get_effective_since "$WATCH_WINDOW" "$started_at")"

	# Prove the current gateway process identity: pid plus the supervisor's
	# uptime-derived start timestamp. Empty means identity could not be
	# established: the incident then stays open as an explicit unknown and no
	# revival is processed, but owed notifications are still delivered below.
	gw_pid=""
	gw_start_ts=""
	if [ -n "$container_id" ] && identity="$(gateway_identity "$container")"; then
		gw_pid="${identity%%|*}"
		gw_start_ts="${identity#*|}"
	fi

	# Fetch timestamped logs since the effective boundary. Container stdout and
	# stderr are both kept (park tracebacks ride on stderr); a fetch failure is
	# an unknown outcome and is never read as a clean window.
	logs_ok=0
	if docker logs --timestamps --since "$effective_since" "$container" >"$LOGS_OUT" 2>"$LOGS_OUT.err"; then
		logs_ok=1
		cat "$LOGS_OUT.err" >>"$LOGS_OUT"
	fi

	# Read previous state
	state_file="$WATCH_STATE_DIR/${container}.state"
	prev_status="ok"
	prev_alert_ts=0
	prev_alert_pending=0
	prev_recovery_pending=0
	prev_recovery_ts=""
	prev_incident_ts=""
	prev_run_started_at=""
	prev_gateway_pid=""
	prev_container_id=""
	prev_unattributed=0
	prev_affected="{}"
	prev_resolved="{}"

	if [ -f "$state_file" ]; then
		while IFS='=' read -r key val || [ -n "$key" ]; do
			case "$key" in
			status) prev_status="$val" ;;
			last_alert_ts) prev_alert_ts="$val" ;;
			alert_pending) prev_alert_pending="$val" ;;
			pending_recovery) prev_recovery_pending="$val" ;;
			pending_recovery_ts) prev_recovery_ts="$val" ;;
			incident_ts) prev_incident_ts="$val" ;;
			run_started_at) prev_run_started_at="$val" ;;
			gateway_pid) prev_gateway_pid="$val" ;;
			container_id) prev_container_id="$val" ;;
			unattributed) prev_unattributed="$val" ;;
			affected) prev_affected="$val" ;;
			resolved) prev_resolved="$val" ;;
			esac
		done <"$state_file"
	fi

	# The episode record carried forward. Defined before any transition path so
	# every state write below keeps the record consistent.
	affected_val="$prev_affected"
	resolved_val="$prev_resolved"
	incident_ts_val="$prev_incident_ts"
	run_started_val="$prev_run_started_at"
	gateway_pid_val="$prev_gateway_pid"
	container_id_val="$prev_container_id"
	unattributed_val="$prev_unattributed"
	alert_pending_val="$prev_alert_pending"
	recovery_pending_val="$prev_recovery_pending"
	recovery_ts_val="$prev_recovery_ts"
	alert_ts_val="$prev_alert_ts"

	# One state writer for the open-incident paths. Detection, evidence and
	# delivery bookkeeping are persisted independently: a failed alert never
	# erases a detected incident, and a failed recovery never erases proven
	# health (review RV2). Dry run never writes.
	write_problem_state() {
		[ "$DRY_RUN" -eq 0 ] || return 0
		tmp_state="$(mktemp "$WATCH_STATE_DIR/state.XXXXXX")"
		printf 'status=problem\nlast_alert_ts=%s\nalert_pending=%s\npending_recovery=%s\npending_recovery_ts=%s\nincident_ts=%s\nrun_started_at=%s\ngateway_pid=%s\ncontainer_id=%s\naffected=%s\nresolved=%s\nunattributed=%s\n' \
			"$alert_ts_val" "$alert_pending_val" "$recovery_pending_val" "$recovery_ts_val" \
			"$incident_ts_val" "$run_started_val" "$gateway_pid_val" "$container_id_val" \
			"$affected_val" "$resolved_val" "$unattributed_val" >"$tmp_state"
		mv -f "$tmp_state" "$state_file"
	}

	write_ok_state() {
		[ "$DRY_RUN" -eq 0 ] || return 0
		tmp_state="$(mktemp "$WATCH_STATE_DIR/state.XXXXXX")"
		printf 'status=ok\nlast_alert_ts=%s\nalert_pending=0\npending_recovery=0\nresolved=%s\n' \
			"$alert_ts_val" "$resolved_val" >"$tmp_state"
		mv -f "$tmp_state" "$state_file"
	}

	# Delivery obligations are transport facts, independent of log evidence
	# (review RV2). Detection is retried before recovery so ordering survives
	# any number of failed runs; a recovery message reports the OBSERVED proof
	# time stored with the obligation, never the delivery time.
	deliver_detections() {
		[ "$alert_pending_val" = "1" ] || return 0
		[ "$detection_attempted" -eq 0 ] || return 1
		msg="[${container}] Parked MCP servers detected: signature found in the container log."
		if [ "$DRY_RUN" -eq 1 ]; then
			log "dry-run: [${container}] pending detection alert retry suppressed"
			return 0
		fi
		detection_attempted=1
		if send_alert "$msg"; then
			alert_pending_val=0
			prev_alert_ts="$now_ts"
			alert_ts_val="$now_ts"
			write_problem_state
			log "[${container}] pending detection alert delivered on retry"
		else
			log "error: [${container}] pending detection alert delivery failed; incident stays open"
			run_failed=1
			return 1
		fi
	}

	deliver_recovery() {
		[ "$recovery_pending_val" = "1" ] || return 0
		local observed_iso
		observed_iso="$(python3 -c 'import sys
from datetime import datetime, timezone
print(datetime.fromtimestamp(float(sys.argv[1]), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "${recovery_ts_val:-$now_ts}")"
		msg="[${container}] MCP recovery confirmed at ${observed_iso}: revival proof closed all parked servers (same-session positive signal)."
		if [ "$DRY_RUN" -eq 1 ]; then
			log "dry-run: [${container}] pending recovery notification retry suppressed"
			return 0
		fi
		if send_alert "$msg"; then
			recovery_pending_val=0
			recovered_this_run=1
			prev_alert_ts="$now_ts"
			alert_ts_val="$now_ts"
			write_ok_state
			log "[${container}] pending recovery notification delivered (proof observed at ${observed_iso})"
		else
			log "error: [${container}] pending recovery notification delivery failed; obligation kept"
			run_failed=1
			return 1
		fi
	}

	# Retry detection before recovery. Recovery waits until newer log evidence
	# has been examined so a fresh failure can supersede its queued proof.
	recovered_this_run=0
	detection_attempted=0
	deliver_detections || true

	# Reminder cadence for an open incident (truthful wording, review RV7: a
	# reminder reports an unresolved episode; it does not claim a fresh
	# detection). Anchor refreshes are persisted even when debounced.
	reminder_send() {
		local elapsed=$((now_ts - prev_alert_ts))
		local record_changed=0
		if [ "$alert_pending_val" = "1" ]; then
			write_problem_state
			return 0
		fi
		if [ "$incident_ts_val" != "$prev_incident_ts" ] || [ "$run_started_val" != "$prev_run_started_at" ] ||
			[ "$gateway_pid_val" != "$prev_gateway_pid" ] || [ "$container_id_val" != "$prev_container_id" ] ||
			[ "$affected_val" != "$prev_affected" ] || [ "$resolved_val" != "$prev_resolved" ] ||
			[ "$unattributed_val" != "$prev_unattributed" ]; then
			record_changed=1
		fi
		if [ "$elapsed" -ge "$WATCH_REMIND_SECONDS" ]; then
			msg="[${container}] MCP park incident remains open: unresolved, awaiting positive recovery proof; reminder."
			if [ "$DRY_RUN" -eq 1 ]; then
				log "dry-run: [${container}] transition problem -> problem (reminder suppressed, elapsed ${elapsed}s)"
			else
				if send_alert "$msg"; then
					prev_alert_ts="$now_ts"
					alert_ts_val="$now_ts"
					write_problem_state
					log "[${container}] reminder delivered (elapsed ${elapsed}s)"
				else
					log "error: [${container}] failed to deliver reminder; last_alert_ts not updated"
					run_failed=1
				fi
			fi
		elif [ "$record_changed" -eq 1 ]; then
			write_problem_state
			log "[${container}] incident record persisted (reminder debounced, ${elapsed}s < ${WATCH_REMIND_SECONDS}s)"
		else
			log "[${container}] incident remains open; reminder debounced (${elapsed}s < ${WATCH_REMIND_SECONDS}s)"
		fi
	}

	if [ "$logs_ok" -eq 0 ]; then
		if deliver_detections && deliver_recovery && [ "$recovered_this_run" -eq 1 ]; then
			log "[${container}] transition problem -> ok (previously observed recovery delivered)"
			continue
		fi
		# Unknown outcome: log access failed, so neither failure nor recovery can
		# be claimed from evidence. Owed deliveries were already attempted above.
		if [ "$prev_status" = "problem" ]; then
			log "warning: [${container}] log read failed; incident preserved without a recovery verdict"
			reminder_send
		else
			log "warning: [${container}] log read failed; no verdict this run"
		fi
		continue
	fi

	# Eligibility floor: log lines older than the current gateway process start
	# belong to a previous generation and never enter the record.
	min_ts="$gw_start_ts"
	[ -n "$min_ts" ] || min_ts=0

	analysis="$(process_events "$LOGS_OUT" "$MARKERS_TMP" "$REVIVAL_TMP" "$min_ts" "$affected_val" "$resolved_val")"
	# Fail-safe defaults before parsing: an empty or malformed analysis
	# degrades to "no proof" and is handled as an unknown outcome below.
	park_total=0
	untimestamped_parks=0
	unnamed_parks=0
	unnamed_openers=0
	named_openers=0
	revival_closures='{}'
	revival_watermarks='{}'
	if [ -z "$analysis" ]; then
		if [ "$prev_status" = "problem" ]; then
			log "warning: [${container}] log analysis failed; incident preserved without a recovery verdict"
			reminder_send
		else
			log "warning: [${container}] log analysis failed; no verdict this run"
		fi
		continue
	fi
	# One interpreter spawn parses the JSON into shell assignments; JSON values
	# are single-quoted so eval cannot word-split them.
	eval "$(printf '%s' "$analysis" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("park_total", "untimestamped_parks", "unnamed_parks", "unnamed_openers", "named_openers"):
    print(f"{k}={int(d[k])}")
affected_val = json.dumps(d["affected"], sort_keys=True)
print("affected_val=" + repr(affected_val))
for k in ("revival_closures", "revival_watermarks"):
    print("%s=%s" % (k, repr(json.dumps(d[k], sort_keys=True))))
')"

	if [ "$unnamed_parks" -gt 0 ] || [ "$untimestamped_parks" -gt 0 ]; then
		unattributed_val=1
		if [ "$recovery_pending_val" = "1" ]; then
			recovery_pending_val=0
			recovery_ts_val=""
			alert_pending_val=1
			write_problem_state
			deliver_detections || true
		fi
	fi

	# Apply revival closures and watermarks. A closure removes the server from
	# the unresolved set and advances its watermark, so a replayed window can
	# never close or re-open it again (reviews RV1c, RV2). Revivals are only
	# processed when the gateway identity is establishable; an unknown
	# generation keeps every verdict open.
	if [ "$gw_pid" != "" ]; then
		merged="$(printf '%s' "$resolved_val" "$revival_closures" "$revival_watermarks" | python3 -c '
import json, sys
resolved = json.loads(sys.argv[1] or "{}")
for source in sys.argv[2:4]:
    for name, ts in json.loads(source or "{}").items():
        resolved[name] = max(float(resolved.get(name, 0.0)), float(ts))
print(json.dumps(resolved, sort_keys=True))
' "$resolved_val" "$revival_closures" "$revival_watermarks")"
		affected_val="$(printf '%s' "$affected_val" "$revival_closures" | python3 -c '
import json, sys
affected = json.loads(sys.argv[1] or "{}")
for name in json.loads(sys.argv[2] or "{}"):
    affected.pop(name, None)
print(json.dumps(affected, sort_keys=True))
' "$affected_val" "$revival_closures")"
		resolved_val="$merged"
	fi

	# Any new evidence refreshes the record's generation binding to what is
	# actually running right now; unresolved servers stay unresolved across a
	# generation change (their old sessions died unproven).
	if [ "$park_total" -gt 0 ] || [ "$revival_closures" != "{}" ] || [ "$revival_watermarks" != "{}" ]; then
		run_started_val="$started_at"
		gateway_pid_val="$gw_pid"
		container_id_val="$container_id"
	fi

	# A park accepted NEWER than an undelivered recovery proof supersedes that
	# proof: the server failed again after it, so the stale recovery message
	# must not go out and the new failure needs its own detection alert.
	if [ "$recovery_pending_val" = "1" ] && [ "$affected_val" != "{}" ]; then
		supersede="$(printf '%s' "$affected_val" "$recovery_ts_val" | python3 -c '
import json, sys
affected = json.loads(sys.argv[1] or "{}")
try:
    obs = float(sys.argv[2])
except (TypeError, ValueError):
    obs = float("-inf")
newer = [n for n, t in affected.items() if float(t) > obs]
print("1" if newer else "0")
' "$affected_val" "$recovery_ts_val")"
		if [ "$supersede" = "1" ]; then
			recovery_pending_val=0
			recovery_ts_val=""
			alert_pending_val=1
			write_problem_state
			deliver_detections || true
			log "[${container}] a newer failure supersedes the undelivered recovery proof; a fresh detection alert is owed"
		fi
	fi
	if [ "$recovery_pending_val" = "1" ] && [ "$affected_val" = "{}" ] && [ "$unattributed_val" -eq 0 ] &&
		[ "$unnamed_parks" -eq 0 ] && [ "$untimestamped_parks" -eq 0 ]; then
		if deliver_detections && deliver_recovery && [ "$recovered_this_run" -eq 1 ]; then
			log "[${container}] transition problem -> ok (queued recovery delivered)"
			continue
		fi
	fi

	# Detection: any accepted (named, unattributable or untimestamped) park
	# opens the episode, evaluated before closures mutate the record.
	new_park_evidence=0
	if [ "$unnamed_openers" -eq 1 ] || [ "$named_openers" -eq 1 ] || [ "$untimestamped_parks" -gt 0 ]; then
		if [ "$prev_status" != "problem" ]; then
			new_park_evidence=1
		fi
	fi

	if [ "$prev_status" != "problem" ]; then
		if [ "$new_park_evidence" -eq 1 ]; then
			# Transition: ok -> problem. Detection is persisted BEFORE the
			# delivery attempt, so a failed alert cannot erase the incident.
			anchor="$(printf '%s' "$affected_val" | python3 -c '
import json, sys
vals = [float(v) for v in json.load(sys.stdin).values()]
print(max(vals) if vals else "")')"
			[ -n "$anchor" ] || anchor="$now_ts"
			incident_ts_val="$anchor"
			run_started_val="$started_at"
			gateway_pid_val="$gw_pid"
			container_id_val="$container_id"
			alert_pending_val=1
			write_problem_state
			msg="[${container}] Parked MCP servers detected: signature found in the container log."
			if [ "$DRY_RUN" -eq 1 ]; then
				log "dry-run: [${container}] transition ok -> problem (alert suppressed)"
			else
				if send_alert "$msg"; then
					alert_pending_val=0
					prev_alert_ts="$now_ts"
					alert_ts_val="$now_ts"
					write_problem_state
					log "[${container}] transition ok -> problem (alert delivered)"
				else
					log "error: [${container}] failed to deliver alert; incident persisted with a pending alert"
					run_failed=1
				fi
			fi
			# A proof already present in this same window closes the episode
			# immediately: queue it behind the detection obligation so the
			# closed-by-evidence state is never lost to the open-path continue
			# (review RV2).
			if [ "$affected_val" = "{}" ] && [ "$unattributed_val" -eq 0 ] && [ "$unnamed_parks" -eq 0 ] && [ "$untimestamped_parks" -eq 0 ] &&
				[ "$revival_closures" != "{}" ]; then
				recovery_pending_val=1
				recovery_ts_val="$now_ts"
				if [ "$DRY_RUN" -eq 1 ]; then
					log "dry-run: [${container}] immediate revival-confirmed recovery suppressed"
				elif [ "$alert_pending_val" != "1" ] && deliver_recovery; then
					log "[${container}] transition problem -> ok (revival-confirmed recovery delivered)"
				else
					# Detection still owed, or delivery failed: the obligation
					# stays queued and is retried on a later run (review RV2).
					write_problem_state
					log "[${container}] recovery notification queued behind detection delivery"
				fi
			fi
		else
			if [ "$revival_closures" != "{}" ] || [ "$revival_watermarks" != "{}" ]; then
				log "[${container}] ok (revival events without an open incident are informational)"
			else
				log "[${container}] ok (clean log)"
			fi
		fi
		continue
	fi

	# Incident open from here; the record was seeded from state above.

	if [ -z "$gw_pid" ]; then
		# Identity unavailable (supervisor slot unreadable, service down, foreign
		# container): recovery cannot be proven, and that is an explicit unknown.
		log "warning: [${container}] gateway identity unavailable; recovery cannot be proven, incident preserved"
		reminder_send
		continue
	fi

	# Episode closure: every durable unresolved failure is closed by native
	# same-server revival evidence, and nothing unattributable denies it.
	all_clear=0
	if [ "$affected_val" = "{}" ] && [ "$unattributed_val" -eq 0 ] && [ "$unnamed_parks" -eq 0 ] && [ "$untimestamped_parks" -eq 0 ] &&
		[ "$revival_closures" != "{}" ]; then
		all_clear=1
	fi

	if [ "$all_clear" -eq 1 ]; then
		# The proof is queued with its observation time; delivery may happen
		# now or, if it fails, on any later run without the log line (RV2).
		# Ordering: an undelivered detection alert goes out first.
		recovery_pending_val=1
		recovery_ts_val="$now_ts"
		affected_val="{}"
		if [ "$DRY_RUN" -eq 1 ]; then
			log "dry-run: [${container}] transition problem -> ok (revival-confirmed recovery suppressed)"
		else
			if deliver_detections && deliver_recovery; then
				log "[${container}] transition problem -> ok (revival-confirmed recovery delivered)"
			else
				write_problem_state
				log "error: [${container}] recovery notification not delivered; obligation kept for retry"
				run_failed=1
			fi
		fi
	else
		reminder_send
	fi
done

if [ "$run_failed" -ne 0 ]; then
	exit 1
fi
