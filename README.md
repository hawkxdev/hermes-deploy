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

## Tech stack

- Docker Engine with Compose v2
- Bash 4+
- `jq`
- Standard userland: `tar`, `find`, `comm`, `awk`, `sed`, and either `shasum` or `sha256sum`

## Prerequisites

A host with Docker Engine and Compose v2, `jq`, `tar`, and a Bash 4+ userland. Roughly 4 GB of disk is required for the image.

## Quick start

Prepare the live files described in [Configuration](#configuration) before the first start.

Validate the Compose model:

```bash
docker compose config
```

Pull and start the pinned gateway image:

```bash
docker compose pull gateway
docker compose up -d gateway
docker compose ps gateway
```

## Configuration

Production values stay outside the bundle. Copy the templates to the host's private data directory and fill them in there:

- `.env.example` → `/opt/hermes/data/.env`
- `config/config.example.yaml` → `/opt/hermes/data/config.yaml`

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

## Layout

```text
compose.yaml              one gateway service, pinned by digest
.env.example              runtime environment template
config/                   fail-closed configuration template
docs/                     architecture, threat model, operations
```

## Sources and attribution

This repository does not vendor or fork Hermes Agent source code. The Compose baseline and runtime assumptions are derived from these public upstream sources:

- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- [Upstream Hermes Docker Compose file](https://github.com/NousResearch/hermes-agent/blob/main/docker-compose.yml)
- [Hermes Agent Docker guide](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- [just-containers/s6-overlay](https://github.com/just-containers/s6-overlay)

The lifecycle, validation, backup, restore and rollback controls are implemented in this repository.

## License

[MIT](LICENSE), matching upstream Hermes Agent.
