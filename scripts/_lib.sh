#!/usr/bin/env bash
# Shared helpers for the lifecycle scripts.
#
# This file exists because the same logic lived in two places and drifted. The
# readiness wait was added to deploy.sh and not to rollback.sh, so every rollback
# verified a gateway the supervisor had not registered yet and reported a healthy
# deployment as broken — during an incident, which is when a rollback runs and
# when a false alarm costs the most. One definition, two callers.
#
# Sourced, never executed: it sets no options and runs nothing on load.

# Wait until the supervisor reports the gateway up, bounded by a timeout.
#
# The image runs an ownership fix, a config migration and a skill sync before the
# gateway service starts, so the supervision tree does not exist for the first
# few seconds of any recreate. Verifying in that window fails for a reason that
# has nothing to do with the deployment's health.
#
# Returns 0 once the service reads "up", 1 on timeout. Deciding whether the
# gateway then STAYS up is verify.sh's job, not this function's.
wait_for_gateway() {
	local container="$1" profile="$2" timeout="$3"
	local waited=0 out last=""

	# A non-numeric timeout made `[ "$waited" -ge "$timeout" ]` fail with
	# "integer expression expected" on every iteration, so the bound never
	# triggered and the wait ran forever instead of erroring out.
	case "$timeout" in
	'' | *[!0-9]*)
		printf 'wait_for_gateway: timeout must be a whole number of seconds, got "%s"\n' "$timeout" >&2
		return 1
		;;
	esac

	# The last failure text is kept rather than discarded. Without it a stopped
	# container, an absent container, a missing s6 binary and a genuinely slow
	# boot all produced byte-identical silence for the full timeout, and the
	# operator — mid-incident — was told only that time ran out.
	while true; do
		out="$(docker exec "$container" /command/s6-svstat "/run/service/gateway-$profile" 2>&1)" || true
		case "$out" in
		up*)
			printf 'gateway reported up after %ss\n' "$waited" >&2
			return 0
			;;
		esac
		last="$out"
		if [ "$waited" -ge "$timeout" ]; then
			printf 'supervised gateway did not come up within %ss; last supervisor response: %s\n' \
				"$timeout" "$last" >&2
			return 1
		fi
		sleep 3
		waited=$((waited + 3))
	done
}

# List the files a rollback must still find afterwards.
#
# The invariant is "nothing disappeared", not "nothing changed": a running Hermes
# constantly rewrites its pid file, gateway state and logs, so demanding an
# identical directory would fail every real rollback.
#
# Three properties this function must hold, each learned from a defect:
#
# 1. It FOLLOWS SYMLINKS (`find -L`, resolved root). Without that, a data
#    directory that is a link — or merely contains one — inventoried as zero
#    files, and the caller compared empty against empty and printed "no data
#    lost" unconditionally. That is the loudest possible false green: it appears
#    precisely when everything is gone.
#
# 2. Its exclusions are ANCHORED to a path separator and scoped to the top level
#    where the transient files actually live. An unanchored `\.lock$` matched
#    `uv.lock` and `poetry.lock` inside skills and plugins — real user content,
#    silently exempted from the loss check. Excluded, with reasons:
#      <root>/*.pid, <root>/*.lock   process bookkeeping, recreated on each start
#      <root>/.clean_shutdown        lifecycle marker: written on a clean stop and
#                                    REMOVED on the next start, so a rollback that
#                                    inventories a stopped container and then a
#                                    started one would report success as loss
#      *.db-wal, *.db-shm            SQLite sidecars at any depth; their removal
#                                    means the database was checkpointed and
#                                    closed cleanly — evidence of a healthy stop
#
# 3. A FAILING `find` is an error, not an empty inventory. `2>/dev/null` plus a
#    `|| true` that covered only the grep turned an unreadable subdirectory into
#    a silent exit 1 with no output at all — under a bind mount owned by the
#    container's uid that is the first thing a non-root operator hits.
data_inventory() {
	local dir="$1" root out rc
	[ -d "$dir" ] || return 0

	root="$(cd "$dir" 2>/dev/null && pwd -P)" || root=""
	if [ -z "$root" ]; then
		printf 'data_inventory: cannot resolve %s\n' "$dir" >&2
		return 1
	fi

	out="$(find -L "$root" -type f 2>&1)"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		printf 'data_inventory: find failed over %s (inventory is NOT empty, it is unknown):\n%s\n' \
			"$root" "$out" >&2
		return 1
	fi

	# An empty result must stay empty: `printf '%s\n' ""` would emit one blank line
	# and the caller would count a file that does not exist.
	[ -n "$out" ] || return 0

	# The root goes into a regex, so its metacharacters are escaped. A path
	# containing a dot would otherwise match any character there — harmless in
	# practice, wrong in principle, and free to fix.
	local root_re
	# shellcheck disable=SC2016  # the backslash-ampersand is sed syntax, not a shell expansion
	root_re="$(printf '%s' "$root" | sed 's/[][\.*^$(){}?+|\/]/\\&/g')"

	# grep exits 1 when it filters everything out; an empty inventory is a valid
	# state, not an error, so that result is deliberately ignored here — but only
	# here, never for find above.
	printf '%s\n' "$out" |
		{ grep -vE "^${root_re}/[^/]*\.(pid|lock)$|^${root_re}/\.clean_shutdown$|\.db-(wal|shm)$" || true; } |
		sort
}
