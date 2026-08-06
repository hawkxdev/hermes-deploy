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

# A corrupted bundle must be rejected FOR THE STATED REASON. Asserting only a
# non-zero exit code lets a bundle that is merely malformed YAML pass a test
# named after a security check that never ran.
#
# The environment is scrubbed too: an inherited HERMES_IMAGE or HERMES_DATA_DIR
# from the caller's shell silently changes what the validator sees, which turned
# most of these cases into false greens.
expect_rejected() {
	local name="$1" file="$2" pattern="$3" out rc
	out="$(env -u HERMES_IMAGE -u HERMES_DATA_DIR -u HERMES_ALLOWED_DATA_ROOT \
		COMPOSE_FILE="$file" "$SCRIPTS/validate.sh" 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		no "$name: corrupted bundle was accepted"
		return
	fi
	if printf '%s' "$out" | grep -qE "$pattern"; then
		ok "$name: rejected for the stated reason"
	else
		no "$name: rejected, but not for the stated reason (expected /$pattern/)"
		printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/        /' >&2
	fi
}

make_bundle() {
	local name="$1" filter="$2"
	local out="$FIXTURES/$name.yaml"
	eval "$filter" <"$REPO_ROOT/compose.yaml" >"$out"
	printf '%s' "$out"
}

printf '== static cases ==\n'

# Deliberately scrubbed: the suite exports a scratch HERMES_DATA_DIR for the
# other cases, and the shipped bundle must be judged on its own defaults.
if env -u HERMES_DATA_DIR -u HERMES_ALLOWED_DATA_ROOT -u HERMES_IMAGE \
	"$SCRIPTS/validate.sh" >/dev/null 2>&1; then
	ok "current bundle passes validation on its shipped defaults"
else
	no "current bundle fails its own validation"
fi

expect_rejected "floating tag" \
	"$(make_bundle floating-tag "sed 's|image: .*|image: nousresearch/hermes-agent:latest|'")" \
	"not pinned by digest|moving tag"

expect_rejected "published ports" \
	"$(make_bundle with-ports "awk '/restart: unless-stopped/{print; print \"    ports:\"; print \"      - \\\"8642:8642\\\"\"; next}1'")" \
	"published ports"

expect_rejected "host network" \
	"$(make_bundle host-network "awk '/restart: unless-stopped/{print; print \"    network_mode: host\"; next}1'")" \
	"network mode"

expect_rejected "privileged mode" \
	"$(make_bundle privileged "awk '/restart: unless-stopped/{print; print \"    privileged: true\"; next}1'")" \
	"privileged mode"

expect_rejected "external init" \
	"$(make_bundle external-init "awk '/restart: unless-stopped/{print; print \"    init: true\"; next}1'")" \
	"external init"

expect_rejected "wrong mount target" \
	"$(make_bundle wrong-target "sed 's|:/opt/data|:/opt/wrong|'")" \
	"mount target"

expect_rejected "wrong project name" \
	"$(make_bundle wrong-name "sed 's|^name: hermes$|name: something-else|'")" \
	"project name"

expect_rejected "leaked address" \
	"$(make_bundle leaked-ip "sed 's|- HERMES_GID=\${HERMES_GID:-10000}|- HERMES_GID=\${HERMES_GID:-10000}\\n      - VPS_HOST=203.0.113.10|'")" \
	"production value"

expect_rejected "entrypoint override" \
	"$(make_bundle entrypoint-override "awk '/restart: unless-stopped/{print; print \"    entrypoint: /bin/sh\"; next}1'")" \
	"entrypoint override"

expect_rejected "shm_size without browser scope" \
	"$(make_bundle shm "awk '/restart: unless-stopped/{print; print \"    shm_size: 1gb\"; next}1'")" \
	"shared memory sizing"

# The mount SOURCE is operator-controlled. These cases exist because checking
# only the count and the target let a bind of the host runtime directory —
# docker socket included — pass every check with exit 0.
for bad_source in / /var/run /etc /var/lib/docker; do
	if out="$(env -u HERMES_IMAGE HERMES_DATA_DIR="$bad_source" "$SCRIPTS/validate.sh" 2>&1)"; then
		no "mount source $bad_source was accepted"
	elif printf '%s' "$out" | grep -qE "sensitive host path|outside the allowed data root|docker socket"; then
		ok "mount source $bad_source rejected"
	else
		no "mount source $bad_source rejected for the wrong reason"
	fi
done

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

# The checksum gate must verify THIS archive, not whatever file sits at the path
# recorded inside the checksum file.
mkdir -p "$WORK/other/data" "$WORK/off"
printf 'foreign\n' >"$WORK/other/data/seed.txt"
tar -czf "$WORK/off/$(basename "$archive")" -C "$WORK/other" data
cp "$archive.sha256" "$WORK/off/"
if HERMES_RESTORE_CONFIRM=yes "$SCRIPTS/restore.sh" "$WORK/off/$(basename "$archive")" >/dev/null 2>&1; then
	no "restore accepted an archive whose checksum does not match"
elif grep -q seed "$HERMES_DATA_DIR/seed.txt" 2>/dev/null; then
	ok "restore rejects a mismatched archive and leaves live data intact"
else
	no "restore rejected the archive but live data changed"
fi

# A round trip must return every file.
rm -rf "$WORK/rt"; mkdir -p "$WORK/rt/data/nested"
printf 'a\n' >"$WORK/rt/data/one.txt"; printf 'b\n' >"$WORK/rt/data/nested/two.txt"
rt_archive="$(HERMES_DATA_DIR="$WORK/rt/data" HERMES_BACKUP_DIR="$WORK/rt/bk" HERMES_BACKUP_STOP_GATEWAY=0 "$SCRIPTS/backup.sh" 2>/dev/null)"
rm -rf "$WORK/rt/data"
if HERMES_RESTORE_CONFIRM=yes HERMES_DATA_DIR="$WORK/rt/data" "$SCRIPTS/restore.sh" "$rt_archive" >/dev/null 2>&1 &&
	[ -f "$WORK/rt/data/one.txt" ] && [ -f "$WORK/rt/data/nested/two.txt" ]; then
	ok "backup and restore round trip preserves nested files"
else
	no "round trip lost files"
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
