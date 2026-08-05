#!/usr/bin/env bash
# Return the deployment to the previously recorded image.
#
# Rollback replaces code, never state. The data directory is left untouched and
# is checksummed before and after to prove it. Restoring state is a separate
# destructive operation with its own gate: see restore.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/compose.yaml}"
SERVICE="${HERMES_SERVICE:-gateway}"
DATA_DIR="${HERMES_DATA_DIR:-/opt/hermes/data}"
PREVIOUS_FILE="${HERMES_PREVIOUS_IMAGE_FILE:-$REPO_ROOT/.previous-image}"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$PREVIOUS_FILE" ] || die "no recorded previous image at $PREVIOUS_FILE"
previous="$(cat "$PREVIOUS_FILE")"
[ -n "$previous" ] || die "recorded previous image is empty"

case "$previous" in
  *@sha256:*) ;;
  *) die "refusing to roll back to an image that is not pinned by digest: $previous" ;;
esac

# Inventory the data directory so the no-state-loss claim is evidence, not an
# assertion in a comment.
#
# The invariant is "nothing disappeared", not "nothing changed": a running
# Hermes constantly rewrites its pid file, gateway state and logs, so demanding
# an identical directory would fail every real rollback. What must never happen
# is a file present before the rollback going missing after it.
# Transient files are excluded by design, and the exclusion list is short and
# justified rather than convenient:
#   *.pid, *.lock       process bookkeeping, recreated on every start
#   *-wal, *-shm        SQLite sidecars; their disappearance means the database
#                       was checkpointed and closed cleanly, which is evidence
#                       of a healthy shutdown, not of data loss
# Anything else vanishing is treated as data loss and stops the rollback.
inventory() {
  [ -d "$DATA_DIR" ] || return 0
  find "$DATA_DIR" -type f 2>/dev/null |
    grep -vE '\.(pid|lock)$|-(wal|shm)$' |
    sort
}

before_list="$(mktemp)"
after_list="$(mktemp)"
trap 'rm -f "$before_list" "$after_list"' EXIT

inventory > "$before_list"
before_count="$(wc -l < "$before_list" | tr -d ' ')"
log "data inventory before: $before_count files"

log "rolling back $SERVICE to $previous"

# The image is swapped through HERMES_IMAGE and everything else comes from
# compose.yaml. Rebuilding the run command by hand silently dropped settings
# the contract requires — the cpu limit went missing that way, and verify.sh
# caught a container running without it.
HERMES_IMAGE="$previous" docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$SERVICE" >&2

inventory > "$after_list"
after_count="$(wc -l < "$after_list" | tr -d ' ')"
log "data inventory after:  $after_count files"

[ -d "$DATA_DIR" ] || die "data directory disappeared during rollback"

missing="$(comm -23 "$before_list" "$after_list")"
if [ -n "$missing" ]; then
  printf 'error: rollback removed files from the data directory:\n%s\n' "$missing" >&2
  exit 1
fi
log "no data lost: every file present before the rollback is still present"

log "rollback applied, run verify.sh for the verdict"
