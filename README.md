# Hermes Deploy

Secure, reproducible Docker deployment and operations toolkit for [Hermes Agent](https://github.com/NousResearch/hermes-agent) on a self-hosted VPS.

This repository is not a fork of Hermes. Hermes ships as an official Docker image; what lives here is the desired runtime state and the lifecycle around it: a Compose service pinned to a signed release digest, and scripts that validate, deploy, verify, back up, roll back and restore it without ever touching the agent's own data.

It is built for the case where the host is shared: the agent runs beside unrelated services that must not be disturbed, so every default is closed and every claim is checked rather than assumed.

## Status

**The bundle runs a live deployment that answers its user.** The gateway came up under supervision, neighbouring services were untouched, a backup was taken and restored into a separate directory with database integrity confirmed on the restored copy. A provider and a messaging platform are configured: plain and tool-using requests both complete, the allowlist rejects an unknown sender at the platform adapter before the model is reached, and a session survives a controlled restart with its history intact.

The resource limits, UID/GID values and shutdown window in `compose.yaml` rest on a read-only audit of that host and on measured timings rather than on placeholders, and the first boot confirmed the UID/GID prediction by assigning ownership exactly as expected. Those numbers are host-specific: re-derive them anywhere else.

The source contract excludes the reproducible `home/.cache` package cache from both the archive and its completeness count, while continuing to follow links everywhere else. This corrected path is covered by a synthetic broken-link fixture but has not yet been rolled out and verified on the live deployment; until then that host still needs the manual procedure in [docs/operations.md](docs/operations.md).

## Design

Three ideas do most of the work.

**The image is pinned by manifest digest, never by tag.** `latest` and `main` move under you; a digest tied to a signed release is the only reference that describes the same bytes tomorrow. Changing versions is a separate, reviewed commit.

**The deployment verdict comes from the supervisor, not from Docker.** The image entrypoint is a dispatcher that takes PID 1 and execs s6-overlay's `/init`, so the gateway runs as a supervised service. It can crash and restart in a loop while the container stays `Up`, so `docker ps` will happily report health over a broken deployment. `verify.sh` samples the supervisor across a window and treats a changed pid as proof of a restart. `up ... want down` and `up ... paused` fail too: being up is not the same as working.

That supervision exists only while the dispatcher actually gets PID 1. Under `docker run --init`, or on a platform whose own init claims PID 1, the dispatcher falls back to a path with no supervised services at all, and every check described here loses its subject. This is why the bundle never overrides the entrypoint and never enables `init`.

**Rollback replaces code, never state.** It swaps only the image and takes every other setting from `compose.yaml`, so it cannot silently drop a resource limit. The data directory is inventoried before and after, and a durable file that disappears aborts the operation. Restoring state is a separate destructive command behind its own confirmation.

Full reasoning lives in [docs/architecture.md](docs/architecture.md), [docs/threat-model.md](docs/threat-model.md) and [docs/operations.md](docs/operations.md).

## What the initial scope excludes

No published ports, no Docker socket, no privileged mode, no host network, no broad host mounts, no dashboard, no API server, no browser automation, no MCP, no cron, and no custom image. Messaging is outbound only. These are enforced by `validate.sh`, not merely documented.

## Tech stack

- [Docker Engine](https://docs.docker.com/engine/) with [Compose v2](https://docs.docker.com/compose/): `docker compose config --format json` is required
- [Bash](https://www.gnu.org/software/bash/) 4+: all scripts run under `set -euo pipefail`
- [jq](https://jqlang.github.io/jq/): the Compose document is inspected structurally, never by grepping text
- [ShellCheck](https://www.shellcheck.net/): for development, run via container, no local install needed
- Standard userland: `tar`, `find`, `comm`, `awk`, `sed`, and either `shasum` or `sha256sum`

## Prerequisites

A host with Docker Engine and Compose v2, `jq`, and a Bash 4+ userland. Roughly 4 GB of disk for the image. No root-owned daemon access is required beyond what Docker itself needs.

## Quick start

```bash
git clone https://github.com/hawkxdev/hermes-deploy.git
cd hermes-deploy
```

Validate the bundle before anything else. This is the gate the deploy path depends on:

```bash
scripts/validate.sh
```

Deploy, which validates, pulls the pinned digest, waits for the gateway to come up and then verifies it:

```bash
scripts/deploy.sh
```

Ask for a verdict at any time:

```bash
scripts/verify.sh
```

Back up the data directory before a version change:

```bash
scripts/backup.sh
```

Return to the previously recorded image:

```bash
scripts/rollback.sh
```

`backup.sh` prints the archive path on stdout and its diagnostics on stderr, so it composes in a pipeline. Every script exits non-zero when its contract is violated.

## Configuration

Production values never live in this repository. Copy the templates to the host's private data directory and fill them in there:

- `.env.example` → `/opt/hermes/data/.env`
- `config/config.example.yaml` → `/opt/hermes/data/config.yaml`

The shipped config template is fail-closed: manual approvals, `cron_mode: deny`, tool-loop hard stops, and write approval for both memory and skills.

**Copying it is a required step, not a convenience.** Hermes reads its configuration from the data directory, which the deployment never writes to. On first boot the agent creates that file itself by copying the image's built-in example, and that example ships with tool-loop hard stops disabled, no `approvals` section at all, and no write approval. Copy the template before the first start and read the live file afterwards to confirm what is actually in effect: the template's presence in this repository proves nothing about the running agent.

The provider login command rewrites the same file. It preserves the rest of the document and replaces only the `model` section, so the fail-closed keys survive — but only if they were there to begin with.

Script behaviour is controlled by environment variables, all with defaults:

| Variable | Default | Purpose |
|---|---|---|
| `HERMES_DATA_DIR` | `/opt/hermes/data` | Host directory holding all mutable agent state |
| `HERMES_ALLOWED_DATA_ROOT` | `/opt/hermes` | Mount sources must resolve inside this root |
| `HERMES_BACKUP_DIR` | `/opt/backups/hermes` | Archive destination, kept outside the deployment tree |
| `HERMES_IMAGE` | pinned digest | Image override; rollback uses it, deployment should not |
| `HERMES_UID` / `HERMES_GID` | `10000` | Remapped to the owner of the data directory |
| `HERMES_CONTAINER` | `hermes` | Container name |
| `HERMES_PROFILE` | `default` | Profile whose supervised service is checked |
| `HERMES_SUPERVISOR_SAMPLES` | `4` | Supervisor readings taken per verification |
| `HERMES_SUPERVISOR_INTERVAL` | `4` | Seconds between those readings |
| `HERMES_READY_TIMEOUT` | `90` | How long deployment waits for the gateway to come up |
| `HERMES_BACKUP_STOP_GATEWAY` | `1` | Brief controlled downtime for a consistent archive |
| `HERMES_SERVICE` | `gateway` | Compose service acted upon |
| `HERMES_DATA_TARGET` | `/opt/data` | Mount target inside the container |
| `HERMES_NEIGHBOUR_UNITS` | empty | Space-separated systemd units verified as unaffected; empty by default because unit names are host topology |
| `HERMES_MAX_RESTARTS` | `3` | Container restart count above which verification fails |
| `HERMES_PREVIOUS_IMAGE_FILE` | `.previous-image` | Where deployment records the outgoing image for rollback |
| `HERMES_ROLLBACK_EVIDENCE_DIR` | `$TMPDIR` | Where rollback keeps the before/after data inventories |
| `HERMES_RESTORE_CONFIRM` | `no` | Must be `yes` before a restore overwrites anything |
| `HERMES_RESTORE_ALLOW_UNVERIFIED` | `no` | Must be `yes` to restore an archive with no checksum file beside it |
| `HERMES_RESTORE_ALLOW_RENAME` | `no` | Must be `yes` when the archive root name differs from the target directory name |

## Testing

```bash
tests/lifecycle/run.sh
```

The suite asserts that each corrupted bundle is rejected **for the stated reason**, not merely with a non-zero exit code. A test that passes because the fixture was malformed YAML proves nothing about the check it is named after. It scrubs inherited environment variables for the same reason. Runtime cases are skipped, not passed, when the pinned image is absent locally.

Lint the scripts without installing anything:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable scripts/*.sh tests/lifecycle/run.sh
```

## Layout

```text
compose.yaml              one gateway service, pinned by digest
config/                   fail-closed configuration template
docs/                     architecture, threat model, operations
scripts/                  validate, backup, deploy, verify, rollback, restore
tests/lifecycle/          suite proving the scripts reject what they must
```

## Author

[hawkxdev](https://github.com/hawkxdev)

## License

[MIT](LICENSE), matching upstream Hermes Agent.
