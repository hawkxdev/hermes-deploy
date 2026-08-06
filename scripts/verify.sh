#!/usr/bin/env bash
# Supervisor-aware verification of a running deployment.
#
# `docker compose ps` and container state `running` are not evidence of health.
# Inside the official image s6-overlay is PID 1 and the gateway is a supervised
# service: it can crash and restart in a loop while the container stays up. The
# verdict therefore comes from the supervisor, not from Docker alone.
set -euo pipefail

CONTAINER="${HERMES_CONTAINER:-hermes}"
PROFILE="${HERMES_PROFILE:-default}"
DATA_TARGET="${HERMES_DATA_TARGET:-/opt/data}"
# Restarts observed by s6 above this count within one boot indicate a loop.
MAX_RESTARTS="${HERMES_MAX_RESTARTS:-3}"
# A crash loop is only visible over time, so the supervisor is sampled more than
# once. Defaults span roughly 12 seconds — long enough to catch a service that
# restarts every few seconds, short enough for an interactive check.
SUPERVISOR_SAMPLES="${HERMES_SUPERVISOR_SAMPLES:-4}"
SUPERVISOR_INTERVAL="${HERMES_SUPERVISOR_INTERVAL:-4}"
# Space-separated systemd units belonging to neighbouring services. Empty by
# default: unit names are private topology and do not belong in a public bundle,
# so the operator supplies them where the deployment actually runs.
NEIGHBOUR_UNITS="${HERMES_NEIGHBOUR_UNITS:-}"

failures=0
fail() {
	printf 'FAIL  %s\n' "$1" >&2
	failures=$((failures + 1))
}
pass() { printf 'ok    %s\n' "$1"; }
info() { printf '      %s\n' "$1"; }

check_container_exists() {
	if docker inspect "$CONTAINER" >/dev/null 2>&1; then
		pass "container exists: $CONTAINER"
		return 0
	fi
	fail "container not found: $CONTAINER"
	return 1
}

check_container_running() {
	local state
	state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER")"
	if [ "$state" = "running" ]; then
		pass "container state: running"
	else
		fail "container state: $state"
	fi
}

# Docker's own restart counter catches the container dying outright, which is a
# different failure from the gateway looping inside a healthy container.
check_container_not_restarting() {
	local count
	count="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER")"
	if [ "$count" -le "$MAX_RESTARTS" ]; then
		pass "container restart count: $count"
	else
		fail "container restarted $count times, above threshold $MAX_RESTARTS"
	fi
}

# /command is on PATH only for processes spawned by the supervision tree, so
# docker exec must call s6-svstat by absolute path.
#
# A single sample cannot tell a healthy service from one crash-looping every few
# seconds: most samples of a looping service still read "up". The uptime field is
# the discriminator — a service that keeps restarting never accumulates uptime —
# so the state is sampled repeatedly and the readings are compared.
#
# "up" alone is also not health: `up ... want down` means the supervisor has been
# told to stop it, and `up ... paused` means the process is frozen and processing
# nothing. Both must fail.
sample_supervisor() {
	docker exec "$CONTAINER" /command/s6-svstat "/run/service/gateway-$PROFILE" 2>&1
}

check_supervisor_service() {
	local service="/run/service/gateway-$PROFILE" out first_seconds last_seconds
	local i samples="" ups=0 pids=""

	if ! out="$(sample_supervisor)"; then
		fail "supervisor state unavailable for $service"
		info "$out"
		return
	fi

	for i in $(seq 1 "$SUPERVISOR_SAMPLES"); do
		out="$(sample_supervisor || true)"
		samples="$samples
  [$i] $out"
		case "$out" in
		up*) ups=$((ups + 1)) ;;
		esac
		# Uptime in seconds is the first number after the pid group.
		local secs pid
		secs="$(printf '%s' "$out" | sed -n 's/.*) \([0-9][0-9]*\) seconds.*/\1/p')"
		pid="$(printf '%s' "$out" | sed -n 's/.*(pid \([0-9][0-9]*\).*/\1/p')"
		[ -n "$pid" ] && pids="$pids$pid
"
		[ -n "$secs" ] || secs=-1
		[ "$i" -eq 1 ] && first_seconds="$secs"
		last_seconds="$secs"
		[ "$i" -lt "$SUPERVISOR_SAMPLES" ] && sleep "$SUPERVISOR_INTERVAL"
	done

	info "s6-svstat samples:$samples"

	if [ "$ups" -ne "$SUPERVISOR_SAMPLES" ]; then
		fail "supervised gateway was not up in $((SUPERVISOR_SAMPLES - ups)) of $SUPERVISOR_SAMPLES samples"
		return
	fi

	# A changed pid is unambiguous proof of a restart, and unlike uptime it cannot
	# be defeated by an unlucky sampling order: comparing only the first and last
	# uptime readings would call the sequence 0s, 3s, 1s, 2s "growing".
	local unique_pids
	unique_pids="$(printf '%s\n' "$pids" | grep -c . || true)"
	if [ "$(printf '%s\n' "$pids" | sort -u | grep -c . || true)" -gt 1 ]; then
		fail "supervised gateway restarted during the check: pid changed across samples ($(printf '%s' "$pids" | tr '\n' ' '))"
		return
	fi
	info "same pid across all $unique_pids samples, no restart observed"

	# Uptime must also grow: a service can keep its pid and still be wedged.
	if [ "$first_seconds" -ge 0 ] && [ "$last_seconds" -ge 0 ]; then
		if [ "$last_seconds" -lt "$first_seconds" ]; then
			fail "supervised gateway restarted during the check: uptime went ${first_seconds}s -> ${last_seconds}s"
			return
		fi
		info "uptime grew ${first_seconds}s -> ${last_seconds}s across the sample window"
	fi

	case "$out" in
	*"want down"*)
		fail "supervised gateway is up but the supervisor wants it down"
		return
		;;
	*paused*)
		fail "supervised gateway is paused and is processing nothing"
		return
		;;
	esac

	pass "supervised gateway is up and stable across $SUPERVISOR_SAMPLES samples"
}

check_manager_reported() {
	local out
	if out="$(docker exec "$CONTAINER" hermes status 2>&1)"; then
		if printf '%s' "$out" | grep -q 's6'; then
			pass "hermes status reports the s6 container supervisor"
		else
			fail "hermes status does not report an s6 manager"
			info "$out"
		fi
	else
		fail "hermes status failed"
		info "$out"
	fi
}

# The boot audit log is written once per boot; repeated boots in a short window
# are the signature of a restart loop that container state alone hides.
check_boot_log() {
	local out
	if out="$(docker exec "$CONTAINER" sh -c 'cat "${HERMES_HOME:-/opt/data}"/logs/container-boot.log 2>/dev/null | tail -20' 2>&1)"; then
		if [ -n "$out" ]; then
			pass "container boot log present"
		else
			info "container boot log is empty or absent"
		fi
	else
		info "container boot log unreadable"
	fi
}

check_no_published_ports() {
	local ports
	ports="$(docker inspect -f '{{json .NetworkSettings.Ports}}' "$CONTAINER")"
	if [ "$ports" = "{}" ] || [ "$ports" = "null" ]; then
		pass "no published ports"
	else
		fail "container publishes ports: $ports"
	fi
}

check_mount_boundary() {
	local mounts count
	mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CONTAINER")"
	count="$(printf '%s' "$mounts" | wc -w | tr -d ' ')"
	if [ "$count" -eq 1 ] && printf '%s' "$mounts" | grep -q "$DATA_TARGET"; then
		pass "single mount at $DATA_TARGET"
	else
		fail "unexpected mounts: $mounts"
	fi
}

check_no_docker_socket() {
	if docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$CONTAINER" | grep -q 'docker\.sock'; then
		fail "docker socket is mounted into the container"
	else
		pass "docker socket not mounted"
	fi
}

check_resource_limits() {
	local mem cpu
	mem="$(docker inspect -f '{{.HostConfig.Memory}}' "$CONTAINER")"
	cpu="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$CONTAINER")"
	if [ "$mem" != "0" ]; then
		pass "memory limit applied: $mem bytes"
	else
		fail "no memory limit applied"
	fi
	if [ "$cpu" != "0" ]; then
		pass "cpu limit applied: $cpu nanocpus"
	else
		fail "no cpu limit applied"
	fi
}

# A deployment that damages a neighbouring service is a failed deployment even
# if its own container is healthy.
check_neighbours_healthy() {
	local names unhealthy
	names="$(docker ps --format '{{.Names}}' | grep -vx "$CONTAINER" || true)"
	if [ -z "$names" ]; then
		info "no neighbouring containers running"
		return
	fi
	unhealthy=""
	while IFS= read -r name; do
		local status
		status="$(docker inspect -f '{{.State.Status}}' "$name")"
		# A neighbour that is running but failing its own healthcheck was damaged
		# just as surely as one that stopped; .State.Status alone hides that.
		health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name")"
		if [ "$status" != "running" ]; then
			unhealthy="$unhealthy $name($status)"
		elif [ "$health" = "unhealthy" ]; then
			unhealthy="$unhealthy $name(running/unhealthy)"
		fi
	done <<<"$names"
	if [ -z "$unhealthy" ]; then
		pass "neighbouring containers still running: $(printf '%s' "$names" | tr '\n' ' ')"
	else
		fail "neighbouring containers affected:$unhealthy"
	fi
}

# Not every neighbour is a container. A shared host can run services under
# systemd instead of Docker, and a container-only sweep reports "neighbours are
# fine" while those services are down — the same blast radius, invisible to the
# verdict. Memory pressure makes this concrete: with no swap configured, the
# kernel's OOM killer picks a victim across the whole host, not inside the
# container that caused it.
check_neighbour_units() {
	if [ -z "$NEIGHBOUR_UNITS" ]; then
		info "no neighbouring systemd units configured (set HERMES_NEIGHBOUR_UNITS)"
		return
	fi

	# Configured but uncheckable is a FAILURE, not a note. Treating it as a note
	# meant a host without systemctl on PATH blessed a deployment while the units
	# the operator explicitly asked about went unexamined.
	if ! command -v systemctl >/dev/null 2>&1; then
		fail "neighbouring units are configured but systemctl is unavailable; their state is unknown"
		return
	fi

	# Word splitting with globbing disabled. Unquoted expansion let a unit name
	# containing a glob be rewritten from the current directory's contents.
	local unit down="" checked=0
	set -f
	# shellcheck disable=SC2086
	set -- $NEIGHBOUR_UNITS
	set +f

	for unit in "$@"; do
		[ -n "$unit" ] || continue
		checked=$((checked + 1))
		# LoadState separates "you typed a name that does not exist" from "a real
		# neighbour is down". Both are failures, but an operator chasing a damaged
		# service must not be sent after a typo, nor reassured by one.
		local load state
		load="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
		if [ "$load" = "not-found" ]; then
			down="$down $unit(not-found: no such unit on this host)"
			continue
		fi
		if ! systemctl is-active --quiet "$unit"; then
			state="$(systemctl is-active "$unit" 2>/dev/null || true)"
			down="$down $unit(${state:-unknown})"
		fi
	done

	# A value of nothing but separators passed the emptiness test above, produced
	# zero words, called systemctl zero times and printed a pass — a green verdict
	# about neighbours nobody looked at.
	if [ "$checked" -eq 0 ]; then
		fail "HERMES_NEIGHBOUR_UNITS is set but contains no unit names; nothing was checked"
		return
	fi

	if [ -z "$down" ]; then
		pass "neighbouring systemd units still active ($checked checked)"
	else
		fail "neighbouring systemd units affected:$down"
	fi
}

main() {
	printf 'verifying deployment: container=%s profile=%s\n\n' "$CONTAINER" "$PROFILE"

	check_container_exists || {
		printf '\n%d check(s) failed\n' "$failures" >&2
		exit 1
	}
	check_container_running
	check_container_not_restarting
	check_no_published_ports
	check_mount_boundary
	check_no_docker_socket
	check_resource_limits
	check_supervisor_service
	check_manager_reported
	check_boot_log
	check_neighbours_healthy
	check_neighbour_units

	printf '\n'
	if [ "$failures" -gt 0 ]; then
		printf '%d check(s) failed\n' "$failures" >&2
		exit 1
	fi
	printf 'deployment verified\n'
}

# Run only when executed, not when sourced. The test suite sources this file to
# exercise individual checks against the REAL definitions; it previously scraped
# a function out with sed, which tested a copy and broke on any reindentation.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
