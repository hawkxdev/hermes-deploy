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

# Not every finding is a verdict. A note reports something the operator must know
# without failing a bundle that is legitimate.
note() {
	printf 'note  %s\n' "$1"
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
	local src="$1" norm resolved

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

	# EVERY check below runs against the RESOLVED path, never the spelling.
	# Reporting a symlink and then checking the link path was worse than useless:
	# '/var/run' is rejected when named directly, and was accepted with "all
	# checks passed" when reached through a link inside the allowed root — the
	# exact host-runtime bind, docker socket included, that these checks exist to
	# prevent. A symlink anywhere in the path defeated the blacklist, the socket
	# test and the allowed-root test at once.
	local spelled="$norm"
	if [ -e "$norm" ] || [ -L "$norm" ]; then
		resolved="$(cd "$norm" 2>/dev/null && pwd -P)" || resolved=""
		if [ -z "$resolved" ]; then
			fail "mount source exists but cannot be resolved (broken link or not a directory): '$src'"
			return
		fi
		if [ "$resolved" != "$norm" ]; then
			note "mount source '$src' resolves to '$resolved'; checks below apply to both spellings"
			norm="$resolved"
		fi
	else
		# Validation legitimately runs where the path does not exist yet — a
		# developer machine, a bundle checked before delivery. Say so, so that a
		# pass is not mistaken for a statement about the deployment host.
		note "mount source '$src' does not exist here; its target cannot be checked from this machine"
	fi

	# Both spellings are screened, and BOTH are required. Checking only the
	# resolved path silently disarmed this list wherever the system itself
	# relocates a sensitive directory — on macOS '/etc' resolves to '/private/etc'
	# and matched nothing. Checking only the spelled path is the hole this
	# resolution was introduced to close: a link inside the allowed root pointing
	# at '/var/run' passed every check. Neither alone is sufficient.
	local bad candidate
	for candidate in "$spelled" "$norm"; do
		for bad in / /bin /boot /dev /etc /home /lib /proc /root /run /sbin /sys /usr /var \
			/var/run /var/lib /var/lib/docker /run/docker.sock /var/run/docker.sock \
			/private/etc /private/var /private/var/run /private/var/lib; do
			if [ "$candidate" = "$bad" ]; then
				fail "mount source is a sensitive host path: '$src' (as '$candidate')"
				return
			fi
		done
		case "$candidate" in
		*/docker.sock | */docker.sock/*)
			fail "mount source reaches the docker socket: '$src' (as '$candidate')"
			return
			;;
		esac
	done

	# The allowed root is resolved too. Comparing a resolved source against an
	# unresolved root would reject a legitimate layout whenever the root itself is
	# reached through a link.
	local allowed_root="$ALLOWED_DATA_ROOT" allowed_resolved
	if [ -d "$allowed_root" ]; then
		allowed_resolved="$(cd "$allowed_root" 2>/dev/null && pwd -P)" || allowed_resolved=""
		[ -n "$allowed_resolved" ] && allowed_root="$allowed_resolved"
	fi

	if is_inside "$norm" "$allowed_root"; then
		pass "mount source inside the allowed data root: $norm"
	else
		fail "mount source '$src' resolves to '$norm', outside the allowed data root '$allowed_root'"
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
#
# The scan reads the whole publishable tree. Reading only the compose file made
# the verdict false in the most useful direction: it announced that the BUNDLE
# held no credential material while looking at a single file of it. A canary in
# config/config.example.yaml passed every check with exit 0 under exactly the
# line that claimed the bundle was clean.
credential_patterns() {
	printf '%s\n' \
		'sk-[A-Za-z0-9]{16,}' \
		'[0-9]{8,10}:[A-Za-z0-9_-]{35}' \
		'BEGIN [A-Z ]*PRIVATE KEY' \
		'([0-9]{1,3}\.){3}[0-9]{1,3}'
}

# Documentation ranges (RFC 5737) are safe by definition and are exactly what
# this repository uses in fixtures and operational examples. They are filtered
# per MATCH, never per line: discarding a whole line would hide a real address
# that happens to share it with a documentation one. Excluding whole FILES would
# be worse still — it is the same hole this scan exists to close.
DOC_ADDRESS='^(192\.0\.2|198\.51\.100|203\.0\.113)\.[0-9]{1,3}$'

# Emits `path:line` for every surviving match. The matched TEXT is never emitted:
# a scanner that prints the secret it found copies that secret into every log
# which stores the scanner's output.
scan_for_pattern() {
	local root="$1" pattern="$2"
	# `grep` exits 1 on no match, and under pipefail that would abort the whole
	# run inside the command substitution that collects these hits: an empty
	# result is the normal case here, not an error.
	{ grep -rEIon --exclude-dir=.git -e "$pattern" "$root" 2>/dev/null || true; } |
		while IFS= read -r hit; do
			local match="${hit#*:}"
			match="${match#*:}"
			printf '%s' "$match" | grep -qE "$DOC_ADDRESS" && continue
			printf '%s\n' "${hit%:"$match"}"
		done
}

scan_tree() {
	local root="$1" pattern hits place
	while IFS= read -r pattern; do
		hits="$(scan_for_pattern "$root" "$pattern")"
		[ -n "$hits" ] || continue
		while IFS= read -r place; do
			[ -n "$place" ] || continue
			fail "possible production value in bundle (pattern: $pattern) at $place"
		done <<<"$hits"
	done < <(credential_patterns)
}

# A detector nobody exercises is a detector nobody can trust: the bundle scan
# above reports "clean" both when the tree is clean and when the patterns stopped
# matching. Before any clean verdict, every pattern must find a freshly generated
# canary in a nested throwaway tree. The canary is random per run, so nothing can
# accommodate it by learning to ignore a fixed string.
check_detector_canary() {
	local dir key token pattern blind=""
	dir="$(mktemp -d)" || {
		fail "canary tree could not be created; the detector is unproven"
		return
	}
	mkdir -p "$dir/nested/deeper"
	# od, not `tr | head`: under pipefail the closed pipe of `head` fails the
	# whole pipeline and would abort the run inside a command substitution.
	key="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
	token="$(od -An -tx1 -N18 /dev/urandom | tr -d ' \n' | cut -c1-35)"
	{
		printf 'api_key: "sk-%s"\n' "$key"
		printf 'bot_token: "1234567890:%s"\n' "$token"
		# Assembled from fragments on purpose: written whole, these literals
		# would live in this file and the tree scan would report its own
		# scanner as a leak.
		printf -- '-----%s %s %s-----\n' 'BEGIN' 'OPENSSH PRIVATE' 'KEY'
		printf 'host: %s.%s.%s.%s\n' 10 11 12 13
	} >"$dir/nested/deeper/canary.yaml"

	while IFS= read -r pattern; do
		[ -n "$(scan_for_pattern "$dir" "$pattern")" ] || blind="$blind $pattern"
	done < <(credential_patterns)
	rm -rf "$dir"

	if [ -n "$blind" ]; then
		fail "detector canary was not found; these patterns are blind:$blind"
	else
		pass "detector canary found by every pattern"
	fi
}

check_no_production_values() {
	local before="$failures"
	scan_tree "$REPO_ROOT"
	# A compose file handed in from outside the tree — a fixture, a bundle checked
	# before delivery — is not reached by the tree walk and must be read too.
	case "$COMPOSE_FILE" in
	"$REPO_ROOT"/*) ;;
	*) scan_tree "$COMPOSE_FILE" ;;
	esac
	# Must not be `[ ... ] && pass`: under set -e a false test would make this
	# function return non-zero and abort the run before the summary prints.
	if [ "$failures" -eq "$before" ]; then
		pass "no credential or address material in the publishable tree"
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
	check_detector_canary
	check_no_production_values

	printf '\n'
	if [ "$failures" -gt 0 ]; then
		printf '%d check(s) failed\n' "$failures" >&2
		exit 1
	fi
	printf 'all checks passed\n'
}

main "$@"
