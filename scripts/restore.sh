#!/usr/bin/env bash
# Restore the Hermes data directory from a verified archive.
#
# This is a destructive operation with its own permission gate, deliberately
# separate from image rollback: restoring overwrites state that is newer than
# the archive, including sessions and memories created since the backup.
#
# Requires HERMES_RESTORE_CONFIRM=yes. Without it the script inspects the
# archive and exits non-zero without touching anything.
set -euo pipefail

ARCHIVE="${1:-}"
DATA_DIR="${HERMES_DATA_DIR:-/opt/hermes/data}"
CONTAINER="${HERMES_CONTAINER:-hermes}"
CONFIRM="${HERMES_RESTORE_CONFIRM:-no}"

log() { printf '%s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[ -n "$ARCHIVE" ] || die "usage: restore.sh <archive.tar.gz>"
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"

log "verifying archive"
tar -tzf "$ARCHIVE" >/dev/null 2>&1 || die "archive is unreadable or corrupt: $ARCHIVE"

# Never delegate path resolution to `shasum -c`: it hashes the path recorded in
# the checksum file, not the archive passed in. A valid but unrelated archive
# then verifies against a stale neighbour and gets extracted over live state.
# The hash of THIS file is computed here and compared as a string.
hash_of() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		sha256sum "$1" | awk '{print $1}'
	fi
}

if [ -f "$ARCHIVE.sha256" ]; then
	recorded="$(awk '{print $1; exit}' "$ARCHIVE.sha256")"
	actual="$(hash_of "$ARCHIVE")"
	[ -n "$recorded" ] || die "checksum file carries no hash: $ARCHIVE.sha256"
	if [ "$recorded" != "$actual" ]; then
		printf 'error: checksum mismatch for %s\n  recorded: %s\n  actual:   %s\n' \
			"$ARCHIVE" "$recorded" "$actual" >&2
		exit 1
	fi
	log "checksum verified against the archive itself"
elif [ "${HERMES_RESTORE_ALLOW_UNVERIFIED:-no}" = "yes" ]; then
	log "warning: no checksum file, proceeding because HERMES_RESTORE_ALLOW_UNVERIFIED=yes"
else
	die "no checksum file next to $ARCHIVE; set HERMES_RESTORE_ALLOW_UNVERIFIED=yes to restore without integrity proof"
fi

entries="$(tar -tzf "$ARCHIVE" | wc -l | tr -d ' ')"
log "archive contains $entries entries"

if [ "$CONFIRM" != "yes" ]; then
	printf '\n' >&2
	printf 'restore would overwrite: %s\n' "$DATA_DIR" >&2
	printf 'state newer than the archive would be lost, including sessions and memories\n' >&2
	printf 'set HERMES_RESTORE_CONFIRM=yes to proceed\n' >&2
	exit 1
fi

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
	log "stopping $CONTAINER before restore"
	docker stop "$CONTAINER" >/dev/null
fi

# Extraction happens in a staging directory beside the target, never straight
# over it. Extracting in place used the archive's OWN root name, so restoring
# into a directory with a different basename silently overwrote a live sibling
# and then reported failure — the operator was told nothing happened while state
# was already replaced.
staging="$(dirname "$DATA_DIR")/.hermes-restore.$$"
rm -rf "$staging"
mkdir -p "$staging" || die "cannot create staging directory: $staging"
cleanup_staging() { rm -rf "$staging"; }
trap cleanup_staging EXIT

log "extracting into staging"
tar -xzf "$ARCHIVE" -C "$staging" || die "extraction failed, nothing was replaced"

# The archive must contain exactly one top-level directory; anything else means
# this is not a Hermes data archive and must not reach the target path.
roots="$(find "$staging" -mindepth 1 -maxdepth 1)"
root_count="$(printf '%s\n' "$roots" | grep -c . || true)"
[ "$root_count" -eq 1 ] || die "archive has $root_count top-level entries, expected exactly 1; nothing was replaced"
extracted="$roots"
[ -d "$extracted" ] || die "archive top-level entry is not a directory; nothing was replaced"

expected="$(basename "$DATA_DIR")"
actual="$(basename "$extracted")"
if [ "$actual" != "$expected" ]; then
	if [ "${HERMES_RESTORE_ALLOW_RENAME:-no}" != "yes" ]; then
		die "archive root is '$actual' but the target is '$expected'; set HERMES_RESTORE_ALLOW_RENAME=yes to restore it under the target name. Nothing was replaced"
	fi
	log "archive root '$actual' will be restored as '$expected'"
fi

# Only now, with a fully extracted and validated tree in hand, is the live
# directory displaced. It is kept, not deleted: if the archive turns out to be
# the wrong one, the only copy of current state must still exist.
displaced=""
if [ -d "$DATA_DIR" ]; then
	displaced="$DATA_DIR.replaced.$(date -u +%Y%m%dT%H%M%SZ)"
	log "moving current data aside to $displaced"
	mv "$DATA_DIR" "$displaced" || die "cannot displace current data, nothing was replaced"
fi

if ! mv "$extracted" "$DATA_DIR"; then
	if [ -n "$displaced" ]; then
		log "swap failed, putting the original data back"
		mv "$displaced" "$DATA_DIR"
	fi
	die "could not move the restored tree into place"
fi

[ -d "$DATA_DIR" ] || die "restore did not produce $DATA_DIR"

log "restore complete"
log "  restored: $DATA_DIR"
log "  previous state kept at: ${displaced:-none}"
log "start the gateway explicitly after reviewing the restored state"
