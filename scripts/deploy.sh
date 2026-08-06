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

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

log "validating bundle"
COMPOSE_FILE="$COMPOSE_FILE" "$SCRIPT_DIR/validate.sh" >/dev/null || die "validation failed, deployment aborted"
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

# The first boot runs an ownership fix, config migration and skill sync before
# the gateway starts, so verifying immediately reports a false failure on every
# fresh deployment. Wait for the supervisor to report the service up, bounded, and
# let verification judge whether it then STAYS up.
READY_TIMEOUT="${HERMES_READY_TIMEOUT:-90}"
PROFILE="${HERMES_PROFILE:-default}"
CONTAINER="${HERMES_CONTAINER:-hermes}"
log "waiting up to ${READY_TIMEOUT}s for the supervised gateway to come up"
waited=0
until docker exec "$CONTAINER" /command/s6-svstat "/run/service/gateway-$PROFILE" 2>/dev/null | grep -q '^up'; do
  if [ "$waited" -ge "$READY_TIMEOUT" ]; then
    die "supervised gateway did not come up within ${READY_TIMEOUT}s"
  fi
  sleep 3
  waited=$((waited + 3))
done
log "gateway reported up after ${waited}s"

# Verification is the gate, not a suggestion in a log line. Deploy exits with the
# verdict so that any caller — a human, a later script, a CI job — sees failure.
log "deployment applied, verifying"
if "$SCRIPT_DIR/verify.sh"; then
  log "deployment verified"
else
  die "deployment applied but verification failed; roll back or investigate before proceeding"
fi
