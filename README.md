# Hermes Deploy

Secure, reproducible Docker deployment and operations toolkit for Hermes Agent on a self-hosted VPS.

The bundle defines the desired runtime state around the official Hermes image: a Compose service pinned to a signed release digest, safe configuration defaults, and lifecycle controls that preserve the agent's mutable data.

It is built for the case where the host is shared: the agent runs beside unrelated services that must not be disturbed, so every default is closed and every claim is checked rather than assumed.

## Design

Three ideas do most of the work.

**The image is pinned by manifest digest, never by tag.** Moving tags can identify different bytes over time; a signed release digest remains stable. Version changes therefore update the digest explicitly.

**The deployment verdict comes from the supervisor, not from Docker.** The image entrypoint is a dispatcher that takes PID 1 and execs s6-overlay's `/init`, so the gateway runs as a supervised service. It can crash and restart in a loop while the container stays `Up`, so container state alone is not a health verdict. Supervisor readings are sampled across a window; a changed pid, `want down`, or `paused` state fails verification.

That supervision exists only while the dispatcher actually gets PID 1. Under `docker run --init`, or on a platform whose own init claims PID 1, the dispatcher falls back to a path with no supervised services at all, and every check described here loses its subject. This is why the bundle never overrides the entrypoint and never enables `init`.

**Rollback replaces code, never state.** It swaps only the image and takes every other setting from `compose.yaml`, so it cannot silently drop a resource limit. The data directory is inventoried before and after, and a durable file that disappears aborts the operation. Restoring state is a separate destructive command behind its own confirmation.

Full reasoning lives in [docs/architecture.md](docs/architecture.md), [docs/threat-model.md](docs/threat-model.md) and [docs/operations.md](docs/operations.md).

## Scope exclusions

No published ports, no Docker socket, no privileged mode, no host network, no broad host mounts, no dashboard, no API server, no browser automation, no MCP, no cron, and no custom image. Messaging is outbound only. Bundle validation enforces these exclusions.

## Delivery

CI validates the bundle and lifecycle contract on every pull request and push to `main` without production access. Production deployment is manual, bound to the exact current `main` commit, and gated by the protected `production` environment.

The root-owned gateway backs up state before activation and verifies the supervisor after deployment. See [docs/operations.md](docs/operations.md) for the operator workflow, least-privilege boundary, failure semantics, rollback, and restore.

## Tech stack

- [Docker Engine](https://docs.docker.com/engine/) with [Docker Compose v2](https://docs.docker.com/compose/)
- [GNU Bash 4+](https://www.gnu.org/software/bash/)
- [jq](https://jqlang.org/)
- Standard userland: `tar`, `find`, `comm`, `awk`, `sed`, and either `shasum` or `sha256sum`

## Prerequisites

- Git
- Docker Engine with Compose v2
- Bash 4+, `jq`, and `tar`
- Approximately 4 GB of free disk space for the image
- Root or sudo access to create private runtime and backup directories

## Installation

Clone the repository and enter it:

```bash
git clone https://github.com/hawkxdev/hermes-deploy.git
cd hermes-deploy
```

Create the private runtime directories and install the fail-closed templates:

```bash
sudo install -d -o 10000 -g 10000 -m 700 /opt/hermes/data
sudo install -d -o root -g root -m 700 /opt/backups/hermes
sudo install -o 10000 -g 10000 -m 600 .env.example /opt/hermes/data/.env
sudo install -o 10000 -g 10000 -m 640 config/config.example.yaml /opt/hermes/data/config.yaml
sudoedit /opt/hermes/data/.env
```

Validate the rendered Compose model, pull the pinned image, and start the gateway:

```bash
docker compose config -q
docker compose pull gateway
docker compose up -d gateway
docker compose ps gateway
```

## Configuration

Production values stay outside the bundle. Copy the templates to the host's private data directory and fill them in there:

- `.env.example` → `/opt/hermes/data/.env`
- `config/config.example.yaml` → `/opt/hermes/data/config.yaml`

Base and optional runtime fields come from `.env.example`:

| Variable | Purpose |
|---|---|
| `GATEWAY_ALLOW_ALL_USERS` | Keep `false`; broad access is outside the deployment contract |
| `TELEGRAM_BOT_TOKEN` | Token of the dedicated Hermes bot; keep outside Git |
| `TELEGRAM_ALLOWED_USERS` | Private Telegram user allowlist |
| `TAVILY_API_KEY` | Optional Tavily search/extract credential |
| `EXA_API_KEY` | Optional Exa search/extract credential |
| `PARALLEL_API_KEY` | Optional Parallel search/extract credential |
| `PARALLEL_SEARCH_MODE` | Parallel mode; template pins the adapter default `agentic` |

The shipped config template is fail-closed: manual approvals, `cron_mode: deny`, tool-loop hard stops, and write approval for both memory and skills.

**Copying it is required.** Hermes reads its configuration from the data directory, which deployment does not overwrite. On first boot the agent creates that file from the image's built-in example; the built-in example disables tool-loop hard stops and omits approvals. Copy the supplied template before the first start and inspect the live file afterwards.

The provider login command rewrites the same file. It preserves the rest of the document and replaces only the `model` section, so the fail-closed keys survive — but only if they were there to begin with.

Runtime behaviour is controlled by environment variables:

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

## Operations

Validate the public bundle without changing runtime state:

```bash
bash scripts/validate.sh
```

Create a verified, owner-only backup with controlled gateway downtime:

```bash
sudo bash scripts/backup.sh
```

Verify the running deployment through the supervisor and configured neighbours:

```bash
sudo bash scripts/verify.sh
```

Rollback and state restore have different safety boundaries. Follow [docs/operations.md](docs/operations.md) instead of running either from an abbreviated example.

## Testing

Run the local validation and contract suites:

```bash
bash scripts/validate.sh
bash tests/lifecycle/run.sh
bash tests/cicd/run.sh
```

The lifecycle suite reports runtime cases as skipped when the pinned image is not available locally; CI pulls the pinned image and requires those cases to run.

## Layout

- `compose.yaml`, `.env.example`, and `config/` define the pinned runtime and its fail-closed templates.
- `../.github/workflows/` contains unprivileged CI and the approval-gated manual production workflow.
- `scripts/` contains the lifecycle controls, one-time host bootstrap, forced-command adapter, and root-owned deployment gateway.
- `tests/` covers lifecycle behaviour and the CI/CD contract with isolated fixtures.
- `docs/` explains the architecture, threat model, and operations.

## Sources and attribution

This repository does not vendor or fork Hermes Agent source code. The Compose baseline and runtime assumptions are derived from these public upstream sources:

- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- [Upstream Hermes Docker Compose file](https://github.com/NousResearch/hermes-agent/blob/main/docker-compose.yml)
- [Hermes Agent Docker guide](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- [just-containers/s6-overlay](https://github.com/just-containers/s6-overlay)

The lifecycle, validation, backup, restore and rollback controls are implemented in this repository.

## Contributing

Open a focused pull request against `main`. Run all commands in [Testing](#testing) first; the protected branch requires the lifecycle check and does not allow direct or force pushes.

## Author

[Sergey Sokolkin](https://github.com/hawkxdev)

## License

[MIT](LICENSE), matching upstream Hermes Agent.
