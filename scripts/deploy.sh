#!/usr/bin/env bash
# Activate the deployment bundle locally.
#
# Validation runs first and a failure stops the deployment: a bundle that
# breaks a security boundary must never reach a running container.
#
# Only the gateway service is recreated. Host-wide cleanup, image pruning and
# commands against neighbouring Compose projects are never issued.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/compose.yaml}"
SERVICE="${HERMES_SERVICE:-gateway}"

# shellcheck source=scripts/_lib.sh
. "$SCRIPT_DIR/_lib.sh"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

log "validating bundle"
# The output is captured rather than discarded. Silencing stdout hid the
# validator's notes — including "this mount source resolves somewhere else" —
# from the one person who needed them, at the one moment they mattered.
validate_out="$(COMPOSE_FILE="$COMPOSE_FILE" "$SCRIPT_DIR/validate.sh" 2>&1)" || {
	printf '%s\n' "$validate_out" >&2
	die "validation failed, deployment aborted"
}
printf '%s\n' "$validate_out" | grep '^note' >&2 || true
log "validation passed"

digest="$(docker compose -f "$COMPOSE_FILE" config --format json | jq -r '.services[].image' | head -1)"
case "$digest" in
  *@sha256:*) ;;
  *) die "refusing to deploy an image that is not pinned by digest: $digest" ;;
esac

log "pulling $digest"
docker compose -f "$COMPOSE_FILE" pull "$SERVICE"

# Record the digest currently in service before replacing it, so rollback has a
# target that came from observed state rather than from a guess.
container="$(docker compose -f "$COMPOSE_FILE" ps -q "$SERVICE" 2>/dev/null || true)"
if [ -n "$container" ]; then
  # .Image is the local image ID, which is not a pullable reference. Rollback
  # needs a repo@sha256 form, so resolve the repo digest of that image.
  image_id="$(docker inspect -f '{{.Image}}' "$container")"
  previous="$(docker inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$image_id" 2>/dev/null || true)"
  if [ -n "$previous" ]; then
    printf '%s\n' "$previous" > "$REPO_ROOT/.previous-image"
    log "previous image recorded: $previous"
  else
    log "warning: running image has no repo digest, rollback target not recorded"
  fi
fi

log "recreating service $SERVICE"
docker compose -f "$COMPOSE_FILE" up -d --no-deps "$SERVICE"

# Wait for the supervisor before judging health; see wait_for_gateway in _lib.sh
# for why an immediate verification is a false failure.
READY_TIMEOUT="${HERMES_READY_TIMEOUT:-90}"
PROFILE="${HERMES_PROFILE:-default}"
CONTAINER="${HERMES_CONTAINER:-hermes}"
log "waiting up to ${READY_TIMEOUT}s for the supervised gateway to come up"
wait_for_gateway "$CONTAINER" "$PROFILE" "$READY_TIMEOUT" || die "supervised gateway did not come up within ${READY_TIMEOUT}s"

# Verification is the gate, not a suggestion in a log line. Deploy exits with the
# verdict so that any caller — a human, a later script, a CI job — sees failure.
log "deployment applied, verifying"
if "$SCRIPT_DIR/verify.sh"; then
  log "deployment verified"
else
  die "deployment applied but verification failed; roll back or investigate before proceeding"
fi
