#!/usr/bin/env bash
# Lifecycle test suite.
#
# Static cases run anywhere. Runtime cases need the pinned image locally and
# are skipped without it, so a missing image reports as skipped rather than as
# a pass. Everything runs against a synthetic data directory; no production
# values and no server access.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts"
WORK="$(mktemp -d)"
FIXTURES="$WORK/bundles"
export HERMES_DATA_DIR="$WORK/data"
export HERMES_BACKUP_DIR="$WORK/backups"

mkdir -p "$FIXTURES" "$HERMES_DATA_DIR" "$HERMES_BACKUP_DIR"
trap 'rm -rf "$WORK"' EXIT

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

# A bundle that must be rejected. Green here means validate.sh discriminates;
# a suite where every corrupted bundle passes proves nothing.
expect_rejected() {
	local name="$1" file="$2"
	if COMPOSE_FILE="$file" "$SCRIPTS/validate.sh" >/dev/null 2>&1; then
		no "$name: corrupted bundle was accepted"
	else
		ok "$name: rejected"
	fi
}

make_bundle() {
	local name="$1" filter="$2"
	local out="$FIXTURES/$name.yaml"
	eval "$filter" <"$REPO_ROOT/compose.yaml" >"$out"
	printf '%s' "$out"
}

printf '== static cases ==\n'

if "$SCRIPTS/validate.sh" >/dev/null 2>&1; then
	ok "current bundle passes validation"
else
	no "current bundle fails its own validation"
fi

expect_rejected "floating tag" \
	"$(make_bundle floating-tag "sed 's|image: .*|image: nousresearch/hermes-agent:latest|'")"

expect_rejected "published ports" \
	"$(make_bundle with-ports "awk '/restart: unless-stopped/{print; print \"    ports:\"; print \"      - \\\"8642:8642\\\"\"; next}1'")"

expect_rejected "host network" \
	"$(make_bundle host-network "awk '/restart: unless-stopped/{print; print \"    network_mode: host\"; next}1'")"

expect_rejected "privileged mode" \
	"$(make_bundle privileged "awk '/restart: unless-stopped/{print; print \"    privileged: true\"; next}1'")"

expect_rejected "external init" \
	"$(make_bundle external-init "awk '/restart: unless-stopped/{print; print \"    init: true\"; next}1'")"

expect_rejected "wrong mount target" \
	"$(make_bundle wrong-target "sed 's|:/opt/data|:/opt/wrong|'")"

expect_rejected "wrong project name" \
	"$(make_bundle wrong-name "sed 's|^name: hermes$|name: something-else|'")"

expect_rejected "leaked address" \
	"$(make_bundle leaked-ip "sed 's|- HERMES_GID=\${HERMES_GID:-10000}|- HERMES_GID=\${HERMES_GID:-10000}\\n      - VPS_HOST=203.0.113.10|'")"

if HERMES_DATA_DIR=/nonexistent "$SCRIPTS/backup.sh" >/dev/null 2>&1; then
	no "backup accepted a missing data directory"
else
	ok "backup rejects a missing data directory"
fi

printf 'seed\n' >"$HERMES_DATA_DIR/seed.txt"
archive="$("$SCRIPTS/backup.sh" 2>/dev/null)"
if [ -f "$archive" ]; then
	ok "backup produced an archive on stdout"
else
	no "backup did not return a usable archive path"
fi

if [ -f "$archive.sha256" ]; then
	ok "backup wrote a checksum"
else
	no "backup wrote no checksum"
fi

if "$SCRIPTS/restore.sh" "$archive" >/dev/null 2>&1; then
	no "restore ran without confirmation"
else
	if [ -f "$HERMES_DATA_DIR/seed.txt" ]; then
		ok "restore refuses without confirmation and touches nothing"
	else
		no "restore modified data while refusing"
	fi
fi

printf '\n== runtime cases ==\n'

IMAGE="$(sed -n 's/.*\(nousresearch\/hermes-agent@sha256:[0-9a-f]*\).*/\1/p' "$REPO_ROOT/compose.yaml" | head -1)"
if [ -z "$IMAGE" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	skip "runtime cases: pinned image not present locally"
else
	export HERMES_CONTAINER="hermes-lifecycle-test"

	if HERMES_CONTAINER="definitely-absent-container" "$SCRIPTS/verify.sh" >/dev/null 2>&1; then
		no "verify passed with no container present"
	else
		ok "verify fails when the container is absent"
	fi

	skip "deploy/verify/rollback against a live container: run manually, they mutate local docker state"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
