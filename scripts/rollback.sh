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
READY_TIMEOUT="${HERMES_READY_TIMEOUT:-90}"
PROFILE="${HERMES_PROFILE:-default}"
CONTAINER="${HERMES_CONTAINER:-hermes}"

# shellcheck source=scripts/_lib.sh
. "$SCRIPT_DIR/_lib.sh"

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
# assertion in a comment. The rules live in data_inventory (_lib.sh) so the same
# definition can be exercised by the test suite without a live container.
inventory() {
  data_inventory "$DATA_DIR"
}

before_list="$(mktemp)"
after_list="$(mktemp)"

# The pre-rollback inventory is the only record of what existed before this
# operation. Deleting it unconditionally on exit meant that the one path where it
# matters most — an abort — destroyed the evidence along with everything else. It
# is preserved whenever the run does not end cleanly.
EVIDENCE_DIR="${HERMES_ROLLBACK_EVIDENCE_DIR:-${TMPDIR:-/tmp}}"
run_clean=0
keep_evidence() {
  if [ "$run_clean" = "0" ]; then
    local dest
    dest="$EVIDENCE_DIR/hermes-rollback-$(date -u +%Y%m%dT%H%M%SZ).$$"
    if mkdir -p "$dest" 2>/dev/null; then
      cp "$before_list" "$dest/inventory-before.txt" 2>/dev/null || true
      [ -s "$after_list" ] && cp "$after_list" "$dest/inventory-after.txt" 2>/dev/null
      printf 'inventory evidence preserved in %s\n' "$dest" >&2
    fi
  fi
  rm -f "$before_list" "$after_list"
}
trap keep_evidence EXIT

inventory > "$before_list"
before_count="$(wc -l < "$before_list" | tr -d ' ')"
log "data inventory before: $before_count files"

log "rolling back $SERVICE to $previous"

# The image is swapped through HERMES_IMAGE and everything else comes from
# compose.yaml. Rebuilding the run command by hand silently dropped settings
# the contract requires — the cpu limit went missing that way, and verify.sh
# caught a container running without it.
HERMES_IMAGE="$previous" docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$SERVICE" >&2

# Wait before inventorying, not only before verifying. Comparing a settled
# directory against a settled directory is what makes the no-loss claim mean
# something: sampling while the boot sequence is still writing compares two
# different moments and calls the difference data loss.
log "waiting up to ${READY_TIMEOUT}s for the supervised gateway to come up"
gateway_ready=1
wait_for_gateway "$CONTAINER" "$PROFILE" "$READY_TIMEOUT" || gateway_ready=0

# The data question is answered even when the gateway never came up. Aborting
# first left the operator — during an incident, holding a dead gateway — with no
# answer at all about whether the rollback had destroyed state, which is the more
# urgent of the two questions and the one they cannot reconstruct later.
if [ "$gateway_ready" = "0" ]; then
  log "gateway did not come up; checking the data directory anyway before reporting"
fi

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

# Only now, with the data question answered and reported, is the readiness
# failure fatal. The order is deliberate: liveness is recoverable, and a missing
# answer about state is not.
if [ "$gateway_ready" = "0" ]; then
  die "data is intact, but the rolled-back gateway did not come up within ${READY_TIMEOUT}s; investigate the gateway, do NOT restore state"
fi

# The verdict must be consumed, not suggested. A rollback that leaves a broken
# deployment behind has to exit non-zero, or the caller learns nothing.
log "rollback applied, verifying"
if "$SCRIPT_DIR/verify.sh"; then
  log "rollback verified"
  run_clean=1
else
  die "rollback completed but verification failed; the deployment is not healthy"
fi
