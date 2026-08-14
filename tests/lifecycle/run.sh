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

# The spelling must not decide the verdict. A symlink inside the allowed root
# pointing at a sensitive path defeated the blacklist, the socket test and the
# allowed-root test at once: the very path rejected above was accepted with
# "all checks passed" when reached through a link.
rm -rf "$WORK/evil"; mkdir -p "$WORK/evil"
ln -s /var/run "$WORK/evil/data"
if out="$(env -u HERMES_IMAGE HERMES_DATA_DIR="$WORK/evil/data" \
	HERMES_ALLOWED_DATA_ROOT="$WORK/evil" "$SCRIPTS/validate.sh" 2>&1)"; then
	no "a symlink to a sensitive host path passed validation"
elif printf '%s' "$out" | grep -qE "sensitive host path|docker socket|outside the allowed data root"; then
	ok "a symlink to a sensitive host path is rejected on its resolved target"
else
	no "symlinked sensitive source rejected for the wrong reason"
fi

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

# A symlinked data directory is ordinary administration — state moved to a larger
# volume, a link left behind. tar archives the LINK, so this produced a 477-byte
# archive with a single entry that passed the structure check, the checksum and a
# full restore while containing no data whatsoever.
rm -rf "$WORK/sym"; mkdir -p "$WORK/sym/store/nested" "$WORK/sym/home"
printf 'one\n' >"$WORK/sym/store/one.txt"
printf 'two\n' >"$WORK/sym/store/nested/two.txt"
printf 'three\n' >"$WORK/sym/store/three.txt"
ln -s "$WORK/sym/store" "$WORK/sym/home/data"
sym_archive="$(HERMES_DATA_DIR="$WORK/sym/home/data" HERMES_BACKUP_DIR="$WORK/sym/bk" \
	HERMES_BACKUP_STOP_GATEWAY=0 "$SCRIPTS/backup.sh" 2>/dev/null)"
if [ -z "$sym_archive" ] || [ ! -f "$sym_archive" ]; then
	no "backup produced no archive for a symlinked data directory"
else
	sym_files="$(tar -tzf "$sym_archive" | grep -vc '/$')"
	if [ "$sym_files" -ge 3 ]; then
		ok "backup through a symlink archives the target's contents ($sym_files files)"
	else
		no "backup through a symlink archived $sym_files files, expected the 3 real ones"
	fi
fi

# A symlinked SUBDIRECTORY is the same administrative act one level down, and it
# reproduced the identical empty-archive failure after the root-only fix shipped:
# find without -L reported one file, the archive held three directory entries,
# and the completeness gate was satisfied while 50 session files were missing.
rm -rf "$WORK/sub"; mkdir -p "$WORK/sub/data" "$WORK/sub/vol/sessions" "$WORK/sub/bk"
printf 'memory\n' >"$WORK/sub/data/MEMORY.md"
for i in $(seq 1 12); do printf 'session %s\n' "$i" >"$WORK/sub/vol/sessions/s$i.json"; done
ln -s "$WORK/sub/vol/sessions" "$WORK/sub/data/sessions"
sub_archive="$(HERMES_DATA_DIR="$WORK/sub/data" HERMES_BACKUP_DIR="$WORK/sub/bk" \
	HERMES_BACKUP_STOP_GATEWAY=0 "$SCRIPTS/backup.sh" 2>/dev/null)"
if [ -n "$sub_archive" ] && [ "$(tar -tzf "$sub_archive" | grep -c 'sessions/s')" -eq 12 ]; then
	ok "backup follows a symlinked subdirectory and archives its files"
else
	no "backup dropped the contents of a symlinked subdirectory"
fi

# Hermes' package cache is reproducible and may contain symlinks written in the
# container's path namespace. They are broken from the host, where backup.sh
# runs. The cache must not make the state backup fail, while files beside it
# remain part of the archive.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache/data/home/.cache/uv/wheels" "$WORK/cache/data/sessions" "$WORK/cache/bk"
printf 'profile\n' >"$WORK/cache/data/home/profile.txt"
printf 'session\n' >"$WORK/cache/data/sessions/s1.json"
ln -s /opt/data/home/.cache/uv/archive.whl "$WORK/cache/data/home/.cache/uv/wheels/container-link"
cache_archive="$(HERMES_DATA_DIR="$WORK/cache/data" HERMES_BACKUP_DIR="$WORK/cache/bk" \
	HERMES_BACKUP_STOP_GATEWAY=0 "$SCRIPTS/backup.sh" 2>/dev/null)"
if [ -n "$cache_archive" ] && [ -f "$cache_archive" ] &&
	tar -tzf "$cache_archive" | grep -q 'data/home/profile.txt' &&
	tar -tzf "$cache_archive" | grep -q 'data/sessions/s1.json' &&
	! tar -tzf "$cache_archive" | grep -q 'data/home/.cache'; then
	ok "backup excludes a broken package cache without dropping state"
else
	no "broken package cache prevented backup or state was dropped"
fi

# The round trip must survive the symlink under the SAME environment used to take
# the backup — no rename escape hatch. Forcing that hatch previously replaced the
# link with a real directory and orphaned the volume holding the state.
rm -rf "$WORK/rtsym"; mkdir -p "$WORK/rtsym/store/nested" "$WORK/rtsym/home" "$WORK/rtsym/bk"
printf 'one\n' >"$WORK/rtsym/store/one.txt"
printf 'two\n' >"$WORK/rtsym/store/nested/two.txt"
ln -s "$WORK/rtsym/store" "$WORK/rtsym/home/data"
rtsym_archive="$(HERMES_DATA_DIR="$WORK/rtsym/home/data" HERMES_BACKUP_DIR="$WORK/rtsym/bk" \
	HERMES_BACKUP_STOP_GATEWAY=0 "$SCRIPTS/backup.sh" 2>/dev/null)"
rm -f "$WORK/rtsym/store/one.txt"
if HERMES_RESTORE_CONFIRM=yes HERMES_DATA_DIR="$WORK/rtsym/home/data" \
	"$SCRIPTS/restore.sh" "$rtsym_archive" >/dev/null 2>&1 &&
	[ -L "$WORK/rtsym/home/data" ] && [ -f "$WORK/rtsym/store/one.txt" ]; then
	ok "restore into a symlinked path works without a rename override and keeps the link"
else
	no "restore into a symlinked path failed or destroyed the link"
fi

# The backup directory must be rejected however it is spelled. Comparing raw
# strings let the same physical directory through when named via the link, and
# the archive landed inside the tree it was archiving.
rm -rf "$WORK/bkin"; mkdir -p "$WORK/bkin/store/bk" "$WORK/bkin/home"
printf 'x\n' >"$WORK/bkin/store/f.txt"
ln -s "$WORK/bkin/store" "$WORK/bkin/home/data"
if HERMES_DATA_DIR="$WORK/bkin/home/data" HERMES_BACKUP_DIR="$WORK/bkin/home/data/bk" \
	HERMES_BACKUP_STOP_GATEWAY=0 "$SCRIPTS/backup.sh" >/dev/null 2>&1; then
	no "backup directory inside the data directory was accepted when spelled via a link"
else
	ok "backup directory inside the data directory is rejected however it is spelled"
fi

# "Not empty" was far too weak a bar: one entry for a directory of hundreds of
# files passed. The count comparison is what closes that gap.
rm -rf "$WORK/short"; mkdir -p "$WORK/short/data"
for i in 1 2 3 4 5; do printf 'x\n' >"$WORK/short/data/f$i.txt"; done
short_archive="$(HERMES_DATA_DIR="$WORK/short/data" HERMES_BACKUP_DIR="$WORK/short/bk" \
	HERMES_BACKUP_STOP_GATEWAY=0 "$SCRIPTS/backup.sh" 2>/dev/null)"
if [ -n "$short_archive" ] && [ "$(tar -tzf "$short_archive" | grep -vc '/$')" -eq 5 ]; then
	ok "backup archives every file of an honest directory"
else
	no "backup dropped files from an honest directory"
fi

# The rollback invariant must ignore the clean-shutdown marker. Hermes writes it
# when it stops and removes it on the next start, so a rollback that inventories
# a stopped container and then a started one would report success as data loss.
# shellcheck source=scripts/_lib.sh
. "$SCRIPTS/_lib.sh"
rm -rf "$WORK/inv"; mkdir -p "$WORK/inv/sessions"
printf 'keep\n' >"$WORK/inv/state.db"
printf 'keep\n' >"$WORK/inv/sessions/s.json"
: >"$WORK/inv/.clean_shutdown"
: >"$WORK/inv/gateway.pid"
: >"$WORK/inv/state.db-wal"
inv_before="$(data_inventory "$WORK/inv")"
rm -f "$WORK/inv/.clean_shutdown" "$WORK/inv/state.db-wal"
inv_after="$(data_inventory "$WORK/inv")"
if [ "$inv_before" = "$inv_after" ]; then
	ok "inventory ignores the clean-shutdown marker and sqlite sidecars"
else
	no "inventory would report a normal restart as data loss"
fi

# The same inventory must still catch a genuine loss, or the exclusion above
# would have bought safety by going blind.
rm -f "$WORK/inv/sessions/s.json"
if [ -n "$(comm -23 <(printf '%s\n' "$inv_after") <(data_inventory "$WORK/inv"))" ]; then
	ok "inventory still detects a real file disappearing"
else
	no "inventory no longer detects real data loss"
fi

# The inventory must see through a symlinked root. Returning zero lines made the
# caller compare empty against empty and print "no data lost" unconditionally —
# a false green that appears exactly when everything is gone.
rm -rf "$WORK/invsym"; mkdir -p "$WORK/invsym/store/sessions" "$WORK/invsym/home"
for i in 1 2 3; do printf 'x\n' >"$WORK/invsym/store/sessions/s$i.json"; done
printf 'x\n' >"$WORK/invsym/store/state.db"
ln -s "$WORK/invsym/store" "$WORK/invsym/home/data"
if [ "$(data_inventory "$WORK/invsym/home/data" | wc -l | tr -d ' ')" -eq 4 ]; then
	ok "inventory follows a symlinked data root"
else
	no "inventory sees nothing through a symlinked root, so no-data-lost would be vacuous"
fi

# Exclusions must be anchored. An unanchored \.lock$ exempted uv.lock and
# poetry.lock inside skills and plugins — real user content — from the loss check.
rm -rf "$WORK/lock"; mkdir -p "$WORK/lock/skills/tool"
printf 'x\n' >"$WORK/lock/skills/tool/uv.lock"
printf 'x\n' >"$WORK/lock/skills/tool/poetry.lock"
printf 'x\n' >"$WORK/lock/state.db"
: >"$WORK/lock/auth.lock"
: >"$WORK/lock/gateway.pid"
inv_lock="$(data_inventory "$WORK/lock")"
if printf '%s\n' "$inv_lock" | grep -q 'skills/tool/uv.lock' &&
	printf '%s\n' "$inv_lock" | grep -q 'skills/tool/poetry.lock' &&
	! printf '%s\n' "$inv_lock" | grep -q '/auth.lock' &&
	! printf '%s\n' "$inv_lock" | grep -q '/gateway.pid'; then
	ok "inventory keeps nested lock files and drops only top-level bookkeeping"
else
	no "inventory exclusions still swallow legitimate nested files"
fi

# Hermes also writes process-scoped Telegram gateway locks below its XDG state
# directory. Container recreation removes them, and the next compatible runtime
# recreates them; unlike arbitrary nested lock files, this exact directory is
# lifecycle bookkeeping rather than user state.
mkdir -p "$WORK/lock/.local/state/hermes/gateway-locks"
printf 'runtime\n' >"$WORK/lock/.local/state/hermes/gateway-locks/telegram-bot-token-test.lock"
inv_gateway_lock="$(data_inventory "$WORK/lock")"
if ! printf '%s\n' "$inv_gateway_lock" |
	grep -q '/\.local/state/hermes/gateway-locks/telegram-bot-token-test\.lock$'; then
	ok "inventory ignores Hermes gateway runtime locks"
else
	no "inventory treats a Hermes gateway runtime lock as durable state"
fi

# Bundled skills are code materialized into the data directory at boot. A
# downgrade may legitimately remove a file introduced by the newer image, but a
# neighbouring custom skill is still user state and must remain protected.
rm -rf "$WORK/invskills"; mkdir -p "$WORK/invskills/skills/builtin" "$WORK/invskills/skills/custom"
invskills_root="$(cd "$WORK/invskills" && pwd -P)"
builtin_skill="$invskills_root/skills/builtin/from-image.py"
custom_skill="$invskills_root/skills/custom/user.py"
printf 'image\n' >"$builtin_skill"
printf 'user\n' >"$custom_skill"
printf '%s\n' "$builtin_skill" >"$WORK/image-owned-skills.txt"
inv_skills_before="$(data_inventory "$WORK/invskills" "$WORK/image-owned-skills.txt")"
rm -f "$builtin_skill" "$custom_skill"
inv_skills_missing="$(
	comm -23 \
		<(printf '%s\n' "$inv_skills_before") \
		<(data_inventory "$WORK/invskills" "$WORK/image-owned-skills.txt")
)"
if [ "$inv_skills_missing" = "$custom_skill" ]; then
	ok "inventory ignores image-owned skill churn but still detects custom skill loss"
else
	no "inventory cannot distinguish image-owned skills from custom state"
fi

# Valid empty inventories must also survive the caller's production `set -e`.
# A standalone assignment whose grep returns 1 exits rollback before its explicit
# status handling can translate "everything filtered" into success.
rm -rf "$WORK/errexit-transient" "$WORK/errexit-image"
mkdir -p "$WORK/errexit-transient" "$WORK/errexit-image/skills/builtin"
: >"$WORK/errexit-transient/gateway.pid"
errexit_image_root="$(cd "$WORK/errexit-image" && pwd -P)"
printf 'image\n' >"$errexit_image_root/skills/builtin/from-image.py"
printf '%s\n' "$errexit_image_root/skills/builtin/from-image.py" >"$WORK/errexit-ignore.txt"
if errexit_result="$(
	bash -c '
		set -euo pipefail
		. "$1"
		data_inventory "$2" >/dev/null
		data_inventory "$3" "$4" >/dev/null
		printf passed
	' bash "$SCRIPTS/_lib.sh" "$WORK/errexit-transient" "$WORK/errexit-image" "$WORK/errexit-ignore.txt"
)"; then
	if [ "$errexit_result" = "passed" ]; then
		ok "empty inventory filters remain successful under errexit"
	else
		no "errexit inventory probe completed without its sentinel"
	fi
else
	no "valid empty inventory aborts a caller running with errexit"
fi

# Exit 1 from grep means every path was intentionally ignored; exit 2 means the
# ignore list could not be read. Treating both as an empty inventory is a false
# green at the exact point rollback is trying to prove no state disappeared.
if [ "$(id -u)" -eq 0 ]; then
	skip "unreadable image-owned list case: running as root, permissions do not apply"
else
	printf 'user\n' >"$custom_skill"
	printf '%s\n' "$builtin_skill" >"$WORK/unreadable-image-owned.txt"
	chmod 000 "$WORK/unreadable-image-owned.txt"
	if data_inventory "$WORK/invskills" "$WORK/unreadable-image-owned.txt" >/dev/null 2>&1; then
		no "inventory hides an unreadable image-owned list as an empty success"
	else
		ok "inventory fails closed when the image-owned list cannot be read"
	fi
	chmod 600 "$WORK/unreadable-image-owned.txt"
	rm -f "$custom_skill"
fi

# A find that fails is an unknown inventory, not an empty one. Silently treating
# it as empty turned an unreadable subdirectory into an exit with no output at all.
if [ "$(id -u)" -eq 0 ]; then
	skip "unreadable subdirectory case: running as root, permissions do not apply"
else
	rm -rf "$WORK/unread"; mkdir -p "$WORK/unread/secret"
	printf 'x\n' >"$WORK/unread/state.db"
	printf 'x\n' >"$WORK/unread/secret/hidden.txt"
	chmod 000 "$WORK/unread/secret"
	if out="$(data_inventory "$WORK/unread" 2>&1)"; then
		no "inventory reported success over an unreadable subdirectory"
	elif printf '%s' "$out" | grep -q 'find failed'; then
		ok "inventory reports an unreadable subdirectory instead of returning empty"
	else
		no "inventory failed over an unreadable subdirectory without saying why"
	fi
	chmod 755 "$WORK/unread/secret"
fi

# Neighbours that are not containers. A shared host can run services under systemd,
# which a container-only sweep reports as "neighbours fine" while they are down.
# systemctl is stubbed so the logic is exercised on any platform — otherwise this
# check would ship having never run at all on a developer machine.
# Unit names here are deliberately generic: this repository is public and real
# neighbour names are host topology.
rm -rf "$WORK/fakebin"; mkdir -p "$WORK/fakebin"
cat >"$WORK/fakebin/systemctl" <<'FAKE'
#!/bin/sh
# Stub: a unit whose name contains "down" is inactive, one containing "ghost"
# does not exist on the host, everything else is active.
if [ "$1" = "show" ]; then
	unit="$4"
	case "$unit" in *ghost*) echo "not-found" ;; *) echo "loaded" ;; esac
	exit 0
fi
quiet=0
for a in "$@"; do [ "$a" = "--quiet" ] && quiet=1; done
unit=""
for a in "$@"; do case "$a" in --*|is-active) ;; *) unit="$a";; esac; done
case "$unit" in
  *down*|*ghost*) [ "$quiet" = 1 ] && exit 3; echo inactive; exit 3 ;;
  *)              [ "$quiet" = 1 ] && exit 0; echo active;   exit 0 ;;
esac
FAKE
chmod +x "$WORK/fakebin/systemctl"

# The REAL function is sourced from verify.sh, not scraped out of it: a copy
# extracted by sed tests something the deployment never runs and breaks on any
# reindentation.
units_harness() {
	local units="$1" stub_path="${2:-$WORK/fakebin:$PATH}"
	PATH="$stub_path" HERMES_NEIGHBOUR_UNITS="$units" bash -c '
		. "$1" 2>/dev/null
		failures=0
		fail() { failures=$((failures+1)); printf "FAIL %s\n" "$1"; }
		pass() { printf "ok %s\n" "$1"; }
		info() { printf "info %s\n" "$1"; }
		NEIGHBOUR_UNITS="${HERMES_NEIGHBOUR_UNITS:-}"
		check_neighbour_units >/dev/null 2>&1
		exit $failures
	' _ "$SCRIPTS/verify.sh"
}

if units_harness "unit-a.service unit-b.service"; then
	ok "neighbouring units check passes when every unit is active"
else
	no "neighbouring units check failed on healthy units"
fi

if units_harness "unit-a.service is-down.service"; then
	no "neighbouring units check passed while a unit was inactive"
else
	ok "neighbouring units check fails when a unit is inactive"
fi

# A value of nothing but separators passed the emptiness test, produced zero
# words, called systemctl zero times and reported a pass — a green verdict about
# neighbours nobody looked at.
if units_harness "   "; then
	no "whitespace-only unit list produced a pass with nothing checked"
else
	ok "whitespace-only unit list fails instead of passing vacuously"
fi

# A typo must not be indistinguishable from a genuinely damaged neighbour.
if units_harness "ghost-unit.service"; then
	no "a unit that does not exist on the host was reported as fine"
else
	ok "a nonexistent unit is reported, not silently accepted"
fi

# Configured but uncheckable is a failure: otherwise a host without systemctl
# blesses a deployment while the named units go unexamined.
#
# The PATH here holds bash and nothing else. Pointing it at a nonexistent
# directory also "failed" — but because bash itself could not be found, so the
# test passed without ever reaching the code it claims to check.
rm -rf "$WORK/nosystemd"; mkdir -p "$WORK/nosystemd"
ln -s "$(command -v bash)" "$WORK/nosystemd/bash"
if units_harness "unit-a.service" "$WORK/nosystemd"; then
	no "configured units passed while systemctl was unavailable"
else
	ok "configured units fail when systemctl is unavailable"
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
