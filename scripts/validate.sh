#!/usr/bin/env bash
# Static validation of the deployment bundle. Runs without a container.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/compose.yaml}"
# Mount sources must resolve inside this root. Overridable so a fixture run can
# point at a scratch directory, but never defaulted to something permissive.
ALLOWED_DATA_ROOT="${HERMES_ALLOWED_DATA_ROOT:-/opt/hermes}"
FORBID_JSON=""

failures=0

fail() {
	printf 'FAIL  %s\n' "$1" >&2
	failures=$((failures + 1))
}

pass() {
	printf 'ok    %s\n' "$1"
}

require_file() {
	[ -f "$COMPOSE_FILE" ] || {
		printf 'FAIL  compose file not found: %s\n' "$COMPOSE_FILE" >&2
		exit 1
	}
}

# Resolved document is the source of truth: a setting can arrive through
# defaults or an override file and never appear in the raw text.

# Structured view. Text greps cannot tell a mount target from a port target —
# both render as `target:` — so counts and lists are read from JSON.
render_json() {
	docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null
}

check_syntax() {
	if docker compose -f "$COMPOSE_FILE" config -q 2>/dev/null; then
		pass "compose syntax"
	else
		fail "compose syntax rejected by docker compose config"
		return 1
	fi
}

check_image_pinned() {
	local images
	images="$(printf '%s' "$1" | jq -r '.services[].image // empty')"
	[ -n "$images" ] || {
		fail "no image reference found"
		return
	}
	while IFS= read -r ref; do
		case "$ref" in
		*@sha256:*) pass "image pinned by digest: ${ref##*@}" ;;
		*) fail "image is not pinned by digest: $ref" ;;
		esac
		case "$ref" in
		*:latest | *:main) fail "moving tag used: $ref" ;;
		esac
	done <<<"$images"
}

# A jq filter that ERRORS must never be read as "setting absent": that turns a
# broken check into a silent pass. Errors are separated from empty results.
jq_probe() {
	local json="$1" filter="$2" out err_file rc
	err_file="$(mktemp)"
	out="$(printf '%s' "$json" | jq -r "$filter" 2>"$err_file")"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		printf 'JQ_ERROR %s' "$(tr '\n' ' ' <"$err_file")"
		rm -f "$err_file"
		return 0
	fi
	rm -f "$err_file"
	# jq -r renders JSON null as the four-character string "null"; an absent key
	# must read as empty, not as a present setting.
	[ "$out" = "null" ] && out=""
	printf '%s' "$out"
}

# Label and filter are separate arguments. The previous table packed both into
# one "filter|label" string and split on a literal pipe, which jq syntax uses
# heavily — a delimiter that cannot collide is worth more than a compact table.
forbid() {
	local label="$1" filter="$2" found
	found="$(jq_probe "$FORBID_JSON" "$filter")"
	case "$found" in
	JQ_ERROR*) fail "check for '$label' could not run: ${found#JQ_ERROR }" ;;
	"") pass "absent: $label" ;;
	*) fail "forbidden setting present: $label" ;;
	esac
}

check_forbidden() {
	FORBID_JSON="$1"
	forbid "published ports" '[.services[].ports // [] | length] | add // 0 | select(. > 0)'
	forbid "host or custom network mode" '.services[] | select(.network_mode != null) | .network_mode'
	forbid "privileged mode" '.services[] | select(.privileged == true) | "yes"'
	forbid "docker socket mount" '.services[].volumes // [] | .[] | select((.source // "") | test("docker\\.sock")) | .source'
	forbid "added capabilities" '.services[] | select((.cap_add // []) | length > 0) | "yes"'
	forbid "host pid namespace" '.services[] | select(.pid == "host") | "yes"'
	forbid "local build instead of official image" '.services[] | select(.build != null) | "yes"'
	forbid "external init breaking s6 supervision" '.services[] | select(.init == true) | "yes"'
	# Overriding the entrypoint bypasses the s6 dispatcher exactly as an external
	# init does; forbidding only one half of that rule protects nothing.
	forbid "entrypoint override bypassing the s6 dispatcher" '.services[] | select(.entrypoint != null) | "yes"'
	forbid "host ipc namespace" '.services[] | select(.ipc == "host") | "yes"'
	forbid "shared memory sizing without a confirmed browser requirement" '.services[] | select(.shm_size != null) | "yes"'
}

check_single_mount() {
	local count
	count="$(printf '%s' "$1" | jq '[.services[].volumes // [] | length] | add // 0')"
	if [ "$count" -eq 1 ]; then
		pass "exactly one mount"
	else
		fail "expected exactly one mount, found $count"
	fi
}

check_mount_target() {
	local target
	target="$(printf '%s' "$1" | jq -r '[.services[].volumes // [] | .[].target] | first // ""')"
	if [ "$target" = "/opt/data" ]; then
		pass "mount target is /opt/data"
	else
		fail "mount target is '$target', expected '/opt/data'"
	fi
}

# The mount SOURCE is operator-controlled through HERMES_DATA_DIR. Checking only
# the count and the target let `HERMES_DATA_DIR=/var/run` render a bind of the
# host runtime directory — including the docker socket — into the container while
# every check still reported a pass. The source is now checked directly.
is_inside() {
	local path="$1" root="${2%/}"
	[ "$path" = "$root" ] && return 0
	case "$path" in
	"$root"/*) return 0 ;;
	*) return 1 ;;
	esac
}

check_one_source() {
	local src="$1" norm

	case "$src" in
	/*) ;;
	*)
		fail "mount source is not an absolute path: '$src'"
		return
		;;
	esac

	# Trailing slashes would let "/var/run/" slip past an exact comparison.
	norm="${src%/}"
	[ -n "$norm" ] || norm="/"

	local bad
	for bad in / /bin /boot /dev /etc /home /lib /proc /root /run /sbin /sys /usr /var \
		/var/run /var/lib /var/lib/docker /run/docker.sock /var/run/docker.sock; do
		if [ "$norm" = "$bad" ]; then
			fail "mount source is a sensitive host path: '$src'"
			return
		fi
	done

	case "$norm" in
	*/docker.sock | */docker.sock/*)
		fail "mount source reaches the docker socket: '$src'"
		return
		;;
	esac

	if is_inside "$norm" "$ALLOWED_DATA_ROOT"; then
		pass "mount source inside the allowed data root: $src"
	else
		fail "mount source '$src' is outside the allowed data root '$ALLOWED_DATA_ROOT'"
	fi
}

check_mount_source() {
	local sources src
	sources="$(printf '%s' "$1" | jq -r '.services[].volumes // [] | .[].source // empty')"
	if [ -z "$sources" ]; then
		fail "no mount source found"
		return
	fi
	while IFS= read -r src; do
		[ -n "$src" ] && check_one_source "$src"
	done <<<"$sources"
}

# Every service must carry its own limits. The previous form collected values
# across all services, so one limited service made an unlimited sibling pass.
check_limits() {
	local json="$1" svc value
	local services
	services="$(printf '%s' "$json" | jq -r '.services | keys[]')"
	while IFS= read -r svc; do
		[ -n "$svc" ] || continue
		local -a required=(
			'memory limit|.services["SVC"].deploy.resources.limits.memory'
			'cpu limit|.services["SVC"].deploy.resources.limits.cpus'
			'log size bound|.services["SVC"].logging.options["max-size"]'
			'log file count bound|.services["SVC"].logging.options["max-file"]'
		)
		for entry in "${required[@]}"; do
			local label="${entry%%|*}" filter="${entry#*|}"
			filter="${filter//SVC/$svc}"
			value="$(jq_probe "$json" "$filter")"
			case "$value" in
			JQ_ERROR*) fail "$svc: check for '$label' could not run" ;;
			"") fail "$svc: $label missing" ;;
			*) pass "$svc: $label set: $value" ;;
			esac
		done
	done <<<"$services"
}

check_project_name() {
	local name
	name="$(printf '%s' "$1" | jq -r '.name // ""')"
	if [ "$name" = "hermes" ]; then
		pass "compose project name pinned to hermes"
	else
		fail "compose project name is '$name', expected 'hermes'"
	fi
}

# Production values must never reach the public bundle. Detects credential
# shapes, not the absence of a variable name.
check_no_production_values() {
	local -a patterns=(
		'sk-[A-Za-z0-9]{16,}'
		'[0-9]{8,10}:[A-Za-z0-9_-]{35}'
		'BEGIN [A-Z ]*PRIVATE KEY'
		'([0-9]{1,3}\.){3}[0-9]{1,3}'
	)
	local hit=0
	for pattern in "${patterns[@]}"; do
		if grep -qE "$pattern" "$COMPOSE_FILE"; then
			fail "possible production value in bundle (pattern: $pattern)"
			hit=1
		fi
	done
	# Must not be `[ ... ] && pass`: under set -e a false test would make this
	# function return non-zero and abort the run before the summary prints.
	if [ "$hit" -eq 0 ]; then
		pass "no credential or address material in bundle"
	fi
}

main() {
	require_file
	printf 'validating %s\n\n' "$COMPOSE_FILE"

	check_syntax || {
		printf '\n%d check(s) failed\n' "$failures" >&2
		exit 1
	}

	local json
	json="$(render_json)"
	[ -n "$json" ] || {
		fail "could not render compose document as json"
		printf '\n%d check(s) failed\n' "$failures" >&2
		exit 1
	}

	check_project_name "$json"
	check_image_pinned "$json"
	check_forbidden "$json"
	check_single_mount "$json"
	check_mount_target "$json"
	check_mount_source "$json"
	check_limits "$json"
	check_no_production_values

	printf '\n'
	if [ "$failures" -gt 0 ]; then
		printf '%d check(s) failed\n' "$failures" >&2
		exit 1
	fi
	printf 'all checks passed\n'
}

main "$@"
