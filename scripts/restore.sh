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

if [ -f "$ARCHIVE.sha256" ]; then
	if command -v shasum >/dev/null 2>&1; then
		(cd "$(dirname "$ARCHIVE")" && shasum -a 256 -c "$(basename "$ARCHIVE").sha256" >/dev/null) ||
			die "checksum mismatch for $ARCHIVE"
	else
		(cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" >/dev/null) ||
			die "checksum mismatch for $ARCHIVE"
	fi
	log "checksum verified"
else
	log "warning: no checksum file next to the archive"
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

# The displaced directory is kept, not deleted: if the archive turns out to be
# the wrong one, the only copy of current state must still exist.
if [ -d "$DATA_DIR" ]; then
	displaced="$DATA_DIR.replaced.$(date -u +%Y%m%dT%H%M%SZ)"
	log "moving current data aside to $displaced"
	mv "$DATA_DIR" "$displaced"
fi

log "restoring into $DATA_DIR"
mkdir -p "$(dirname "$DATA_DIR")"
tar -xzf "$ARCHIVE" -C "$(dirname "$DATA_DIR")"

[ -d "$DATA_DIR" ] || die "restore did not produce $DATA_DIR"

log "restore complete"
log "  restored: $DATA_DIR"
log "  previous state kept at: ${displaced:-none}"
log "start the gateway explicitly after reviewing the restored state"
