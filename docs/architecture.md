# Architecture

## Purpose

The bundle defines the desired state for one self-hosted Hermes Agent deployment based on the official Docker image.

## State boundaries

```text
compose.yaml
    |
    v
official Hermes Agent image
    |
    v
/opt/hermes/data

/opt/backups/hermes
```

- `compose.yaml` defines the gateway container and its runtime limits.
- `/opt/hermes/data` contains mutable configuration, credentials, sessions, memories, skills, profiles, logs, uploads, plugins, and the agent's package cache.
- `/opt/backups/hermes` contains recovery data outside the runtime state directory.

Deployment never synchronizes or replaces `/opt/hermes/data`.

Configuration templates take effect only after they are copied into the data directory. The package cache contains links expressed in the container's path namespace, so the backup contract excludes that reproducible cache while retaining every non-reproducible state path.

## Pinned release

`compose.yaml` pins the official image by manifest digest. The digest corresponds to signed release `v2026.8.3` (Hermes Agent v0.20.0). Moving tags are never used as desired state.

The image ENTRYPOINT is a dispatcher that execs the s6-overlay `/init` process as PID 1, which performs the root bootstrap, volume ownership fixes, and configuration migrations before supervised services start. The deployment therefore keeps the default entrypoint and does not introduce an external init process.

The dispatcher checks whether it is PID 1 and falls back to a direct bootstrap when it is not, which is what makes the rule above load-bearing rather than stylistic: under an external init the fallback runs the agent with no supervision tree, so the supervised service slot that the deployment verdict reads does not exist at all. Entrypoint overrides and `init` are rejected by validation for this reason.

## Security boundary

The deployment uses one official image, one gateway container, one default profile, and one writable mount from `/opt/hermes/data` to `/opt/data`.

Published ports, the Docker socket, privileged mode, unrelated host mounts, custom images, sidecars, browser automation, MCP integrations, and unattended jobs are excluded.
