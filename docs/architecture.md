# Architecture

## Purpose

This repository describes the public desired state for one self-hosted Hermes Agent deployment based on the official Docker image.

## State boundaries

```text
Git repository
    |
    v
/opt/hermes/deploy
    |
    v
official Hermes Agent image
    |
    v
/opt/hermes/data

/opt/backups/hermes
```

- The Git repository owns versioned deployment files and safe templates.
- `/opt/hermes/deploy` contains immutable deployment bundles.
- `/opt/hermes/data` contains mutable configuration, credentials, sessions, memories, skills, profiles, logs, uploads, plugins, and the agent's own package cache.
- `/opt/backups/hermes` contains recovery data outside the deployment tree.

The deployment repository never synchronizes or replaces `/opt/hermes/data`.

That boundary has two consequences worth stating explicitly. Configuration templates shipped here take effect only after someone copies them into the data directory; until then the agent runs on a configuration it generated for itself. And the package cache the agent writes there carries links expressed in the container's path namespace, which a host-side backup cannot resolve. The backup contract excludes that reproducible cache while retaining every non-reproducible state path.

## Pinned release

`compose.yaml` pins the official image by manifest digest. The digest corresponds to the signed upstream release tag `v2026.8.3` (Hermes Agent v0.20.0). Moving tags such as `latest` and `main` are never used as a source of desired state, and a version change is always a separate reviewed commit.

The image ENTRYPOINT is a dispatcher that execs the s6-overlay `/init` process as PID 1, which performs the root bootstrap, volume ownership fixes, and configuration migrations before supervised services start. The deployment therefore keeps the default entrypoint and does not introduce an external init process.

The dispatcher checks whether it is PID 1 and falls back to a direct bootstrap when it is not, which is what makes the rule above load-bearing rather than stylistic: under an external init the fallback runs the agent with no supervision tree, so the supervised service slot that the deployment verdict reads does not exist at all. Entrypoint overrides and `init` are rejected by validation for this reason.

## Initial security boundary

The initial deployment uses one official image, one gateway container, one default profile, and one writable mount from `/opt/hermes/data` to `/opt/data`.

Published ports, the Docker socket, privileged mode, unrelated host mounts, custom images, sidecars, browser automation, MCP integrations, and unattended jobs are outside the initial scope.
