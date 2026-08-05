#!/usr/bin/env bash
# Static validation of the deployment bundle. Runs without a container.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/compose.yaml}"

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

check_forbidden() {
	local json="$1" label found
	# Each entry is "jq-filter|label". The filter returns a non-empty result
	# when the forbidden setting is present in any service.
	local -a forbidden=(
		'[.services[].ports // [] | length] | add // 0 | select(. > 0)|published ports'
		'.services[] | select(.network_mode != null) | .network_mode|host or custom network mode'
		'.services[] | select(.privileged == true) | "yes"|privileged mode'
		'.services[].volumes // [] | .[] | select(.source // "" | test("docker\\.sock")) | .source|docker socket mount'
		'.services[] | select((.cap_add // []) | length > 0) | "yes"|added capabilities'
		'.services[] | select(.pid == "host") | "yes"|host pid namespace'
		'.services[] | select(.build != null) | "yes"|local build instead of official image'
		'.services[] | select(.init == true) | "yes"|external init breaking s6 supervision'
	)
	for entry in "${forbidden[@]}"; do
		label="${entry##*|}"
		found="$(printf '%s' "$json" | jq -r "${entry%|*}" 2>/dev/null || true)"
		if [ -n "$found" ]; then
			fail "forbidden setting present: $label"
		else
			pass "absent: $label"
		fi
	done
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

check_limits() {
	local json="$1" value
	local -a required=(
		'.services[].deploy.resources.limits.memory|memory limit'
		'.services[].deploy.resources.limits.cpus|cpu limit'
		'.services[].logging.options["max-size"]|log size bound'
		'.services[].logging.options["max-file"]|log file count bound'
	)
	for entry in "${required[@]}"; do
		value="$(printf '%s' "$json" | jq -r "${entry%|*} // empty" 2>/dev/null || true)"
		if [ -n "$value" ]; then
			pass "${entry##*|} set: $value"
		else
			fail "${entry##*|} missing"
		fi
	done
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
