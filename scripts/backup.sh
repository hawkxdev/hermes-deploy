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

case "$BACKUP_DIR" in
"$DATA_DIR" | "$DATA_DIR"/*) die "backup directory must not live inside the data directory" ;;
esac

mkdir -p "$BACKUP_DIR" || die "cannot create backup directory: $BACKUP_DIR"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$BACKUP_DIR/hermes-data-$stamp.tar.gz"

gateway_was_running=0
stop_gateway() {
	[ "$STOP_GATEWAY" = "1" ] || return 0
	if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
		log "stopping $CONTAINER for a consistent copy"
		docker stop "$CONTAINER" >/dev/null
		gateway_was_running=1
	fi
}

start_gateway() {
	[ "$gateway_was_running" = "1" ] || return 0
	log "restarting $CONTAINER"
	docker start "$CONTAINER" >/dev/null
}
# The gateway must come back even if the archive step fails.
trap start_gateway EXIT

stop_gateway

log "archiving $DATA_DIR"
tar -czf "$archive" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"

[ -s "$archive" ] || die "archive is empty: $archive"

log "verifying archive structure"
tar -tzf "$archive" >/dev/null || die "archive is not readable: $archive"

entries="$(tar -tzf "$archive" | wc -l | tr -d ' ')"
[ "$entries" -gt 0 ] || die "archive contains no entries: $archive"

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

log "backup complete"
log "  archive:  $archive"
log "  entries:  $entries"
log "  checksum: $archive.sha256"

printf '%s\n' "$archive"
