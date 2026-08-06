# Hermes Deploy

Secure, reproducible Docker deployment and operations toolkit for [Hermes Agent](https://github.com/NousResearch/hermes-agent) on a self-hosted VPS.

This repository is not a fork of Hermes. Hermes ships as an official Docker image; what lives here is the desired runtime state and the lifecycle around it — a Compose service pinned to a signed release digest, and scripts that validate, deploy, verify, back up, roll back and restore it without ever touching the agent's own data.

It is built for the case where the host is shared: the agent runs beside unrelated services that must not be disturbed, so every default is closed and every claim is checked rather than assumed.

## Status

The bundle and its lifecycle are exercised locally against synthetic data. **Nothing here has yet run against a live host.** Resource limits and UID/GID values in `compose.yaml` are deliberate placeholders pending an audit of the target machine. Treat this as a working toolkit under review, not as a turnkey deployment.

## Design

Three ideas do most of the work.

**The image is pinned by manifest digest, never by tag.** `latest` and `main` move under you; a digest tied to a signed release is the only reference that describes the same bytes tomorrow. Changing versions is a separate, reviewed commit.

**The deployment verdict comes from the supervisor, not from Docker.** Inside the official image, s6-overlay is PID 1 and the gateway is a supervised service. It can crash and restart in a loop while the container stays `Up`, so `docker ps` will happily report health over a broken deployment. `verify.sh` samples the supervisor across a window and treats a changed pid as proof of a restart. `up ... want down` and `up ... paused` fail too — being up is not the same as working.

**Rollback replaces code, never state.** It swaps only the image and takes every other setting from `compose.yaml`, so it cannot silently drop a resource limit. The data directory is inventoried before and after, and a durable file that disappears aborts the operation. Restoring state is a separate destructive command behind its own confirmation.

Full reasoning lives in [docs/architecture.md](docs/architecture.md), [docs/threat-model.md](docs/threat-model.md) and [docs/operations.md](docs/operations.md).

## What the initial scope excludes

No published ports, no Docker socket, no privileged mode, no host network, no broad host mounts, no dashboard, no API server, no browser automation, no MCP, no cron, and no custom image. Messaging is outbound only. These are enforced by `validate.sh`, not merely documented.

## Tech stack

- [Docker Engine](https://docs.docker.com/engine/) with [Compose v2](https://docs.docker.com/compose/) — `docker compose config --format json` is required
- [Bash](https://www.gnu.org/software/bash/) 4+ — all scripts run under `set -euo pipefail`
- [jq](https://jqlang.github.io/jq/) — the Compose document is inspected structurally, never by grepping text
- [ShellCheck](https://www.shellcheck.net/) — for development; run via container, no local install needed
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
| `HERMES_RESTORE_CONFIRM` | `no` | Must be `yes` before a restore overwrites anything |

## Testing

```bash
tests/lifecycle/run.sh
```

The suite asserts that each corrupted bundle is rejected **for the stated reason**, not merely with a non-zero exit code — a test that passes because the fixture was malformed YAML proves nothing about the check it is named after. It scrubs inherited environment variables for the same reason. Runtime cases are skipped, not passed, when the pinned image is absent locally.

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
