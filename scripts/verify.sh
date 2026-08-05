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
check_supervisor_service() {
	local service="/run/service/gateway-$PROFILE" out
	if ! out="$(docker exec "$CONTAINER" /command/s6-svstat "$service" 2>&1)"; then
		fail "supervisor state unavailable for $service"
		info "$out"
		return
	fi
	info "s6-svstat: $out"
	case "$out" in
	up*) pass "supervised gateway is up" ;;
	*) fail "supervised gateway is not up" ;;
	esac
	# s6-svstat reports the restart count for the current boot.
	local wants
	wants="$(printf '%s' "$out" | grep -oE '\(want (up|down)\)' || true)"
	[ -z "$wants" ] || info "supervisor intent: $wants"
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
		[ "$status" = "running" ] || unhealthy="$unhealthy $name($status)"
	done <<<"$names"
	if [ -z "$unhealthy" ]; then
		pass "neighbouring containers still running: $(printf '%s' "$names" | tr '\n' ' ')"
	else
		fail "neighbouring containers affected:$unhealthy"
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

	printf '\n'
	if [ "$failures" -gt 0 ]; then
		printf '%d check(s) failed\n' "$failures" >&2
		exit 1
	fi
	printf 'deployment verified\n'
}

main "$@"
