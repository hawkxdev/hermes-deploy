#!/usr/bin/env bash
# Full backup of the Hermes data directory with a verified archive.
#
# The whole directory is archived, not a list of known files: Hermes owns
# sessions, memories, skills, profiles, logs, and plugins under the same root,
# and a selective backup silently drops whatever the next release adds.
#
# The archive is written outside the deployment tree so that cleaning or
# replacing the deployment directory can never destroy recovery data.
set -euo pipefail

DATA_DIR="${HERMES_DATA_DIR:-/opt/hermes/data}"
BACKUP_DIR="${HERMES_BACKUP_DIR:-/opt/backups/hermes}"
CONTAINER="${HERMES_CONTAINER:-hermes}"
# Controlled downtime is the v1 consistency contract: SQLite and file stores
# are not proven safe to copy while the gateway writes to them.
STOP_GATEWAY="${HERMES_BACKUP_STOP_GATEWAY:-1}"

log() { printf '%s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[ -d "$DATA_DIR" ] || die "data directory not found: $DATA_DIR"

# Symlinks are ordinary administration here — state moved to a larger volume, a
# link left behind — and `tar` archives the LINK rather than its target. That
# produced a 477-byte archive that passed the structure check, the checksum AND a
# full restore while holding no data at all.
#
# Resolving only the data directory ITSELF is not enough, and that half-measure is
# what a first attempt shipped: a symlinked SUBDIRECTORY (data/sessions -> /vol)
# reproduced the identical failure one level down, because `find -type f` does not
# follow links either, so the file count stayed low and the completeness gate was
# satisfied by three directory entries. Both ends of that gate must therefore
# traverse links: the archive is written with `-h` and every count below uses
# `find -L`.
resolved_dir() { (cd "$1" 2>/dev/null && pwd -P); }

real_data="$(resolved_dir "$DATA_DIR")" || true
[ -n "$real_data" ] || die "cannot resolve data directory: $DATA_DIR"
if [ "$real_data" != "$DATA_DIR" ]; then
	log "data directory resolves to $real_data"
fi
DATA_DIR="$real_data"

mkdir -p "$BACKUP_DIR" || die "cannot create backup directory: $BACKUP_DIR"

# Both sides are resolved before comparison. Comparing the raw strings let the
# SAME physical directory pass when spelled through a link — the archive then
# landed inside the tree it was archiving.
real_backup="$(resolved_dir "$BACKUP_DIR")" || true
[ -n "$real_backup" ] || die "cannot resolve backup directory: $BACKUP_DIR"
case "$real_backup" in
"$DATA_DIR" | "$DATA_DIR"/*) die "backup directory must not live inside the data directory (resolved: $real_backup inside $DATA_DIR)" ;;
esac

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$BACKUP_DIR/hermes-data-$stamp.tar.gz"

gateway_was_running=0
stop_gateway() {
	[ "$STOP_GATEWAY" = "1" ] || return 0
	# A stop that quietly does nothing degrades this into a hot backup while the
	# header of this file declares controlled downtime the v1 consistency
	# contract. A container renamed by Compose, a typo in HERMES_CONTAINER or a
	# missing docker binary all produced exactly that, silently. Say so loudly:
	# the operator can accept a hot copy, but must not be handed one unknowingly.
	if ! command -v docker >/dev/null 2>&1; then
		log "warning: docker not found, gateway NOT stopped; this is a HOT backup and consistency is not guaranteed"
		return 0
	fi
	if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
		log "stopping $CONTAINER for a consistent copy"
		docker stop "$CONTAINER" >/dev/null
		gateway_was_running=1
	else
		log "warning: container '$CONTAINER' is not running, nothing was stopped; if the gateway is running under another name this is a HOT backup"
	fi
}

start_gateway() {
	[ "$gateway_was_running" = "1" ] || return 0
	log "restarting $CONTAINER"
	docker start "$CONTAINER" >/dev/null
}
# The gateway must come back even if the archive step fails, and a failed run must
# not leave a plausible-looking .tar.gz with no checksum beside it: a directory
# listing then shows a file that reads as a backup and is not one.
archive_committed=0
cleanup() {
	if [ "$archive_committed" = "0" ] && [ -f "$archive" ]; then
		rm -f "$archive"
		log "removed incomplete archive: $archive"
	fi
	start_gateway
}
trap cleanup EXIT

stop_gateway

# Counted after the gateway stopped, so the number describes the same quiet
# directory that tar is about to read. `-L` because the archive follows links too:
# counting one way and archiving the other is precisely how an empty archive was
# certified as complete.
source_files="$(find -L "$DATA_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"

# Content pulled in from outside the data directory is not a failure — the volume
# it lives on is usually the point — but it changes what this archive contains and
# must not be silent.
report_external_links() {
	local link target
	while IFS= read -r link; do
		[ -n "$link" ] || continue
		target="$(resolved_dir "$link")" || target=""
		[ -n "$target" ] || continue
		case "$target" in
		"$DATA_DIR" | "$DATA_DIR"/*) ;;
		*) printf '  %s -> %s\n' "$link" "$target" >&2 ;;
		esac
	done
}

links="$(find "$DATA_DIR" -type l 2>/dev/null || true)"
if [ -n "$links" ]; then
	log "note: the data directory contains symlinks; the archive follows them:"
	printf '%s\n' "$links" | report_external_links
fi

log "archiving $DATA_DIR ($source_files files)"
# -h dereferences symlinks. Without it tar stores the link and drops everything
# behind it, which is the original defect and its one-level-down repeat.
tar -czhf "$archive" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")" ||
	die "tar failed; the archive is not trustworthy and was not recorded"

[ -s "$archive" ] || die "archive is empty: $archive"

log "verifying archive structure"
tar -tzf "$archive" >/dev/null || die "archive is not readable: $archive"

# Compare LIKE WITH LIKE: regular files in the archive against regular files on
# disk. The previous gate compared total entries against files, and directory
# entries alone can exceed the file count — on a realistic layout that slack was
# 54 entries, enough for every single file to vanish while the check still
# passed. Counting only regular files removes the slack entirely.
archived_files="$(tar -tzvf "$archive" | grep -c '^-' || true)"
[ "$archived_files" -gt 0 ] || die "archive contains no regular files: $archive"

if [ "$archived_files" -lt "$source_files" ]; then
	die "archive holds $archived_files files but the data directory has $source_files; content was dropped, refusing to record this as a backup"
fi

# The checksum must record a RELATIVE name. With an absolute path recorded,
# `shasum -c` re-hashes whatever sits at that path instead of the archive it was
# handed, so an archive moved offsite fails verification while a stale file at
# the original path passes it.
(
	cd "$BACKUP_DIR" || die "cannot enter backup directory"
	base="$(basename "$archive")"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$base" >"$base.sha256"
	else
		sha256sum "$base" >"$base.sha256"
	fi
)

# From here the archive is complete and checksummed, so the cleanup trap must
# stop treating it as debris.
archive_committed=1

log "backup complete"
log "  archive:  $archive"
log "  files:    $archived_files"
log "  checksum: $archive.sha256"

printf '%s\n' "$archive"
