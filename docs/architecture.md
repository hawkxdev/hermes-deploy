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
- `/opt/hermes/data` contains mutable configuration, credentials, sessions, memories, skills, profiles, logs, uploads, and plugins.
- `/opt/backups/hermes` contains recovery data outside the deployment tree.

The deployment repository never synchronizes or replaces `/opt/hermes/data`.

## Pinned release

`compose.yaml` pins the official image by manifest digest. The digest corresponds to the signed upstream release tag `v2026.8.3` (Hermes Agent v0.20.0). Moving tags such as `latest` and `main` are never used as a source of desired state, and a version change is always a separate reviewed commit.

The image ENTRYPOINT is a dispatcher that execs the s6-overlay `/init` process as PID 1, which performs the root bootstrap, volume ownership fixes, and configuration migrations before supervised services start. The deployment therefore keeps the default entrypoint and does not introduce an external init process.

## Initial security boundary

The initial deployment uses one official image, one gateway container, one default profile, and one writable mount from `/opt/hermes/data` to `/opt/data`.

Published ports, the Docker socket, privileged mode, unrelated host mounts, custom images, sidecars, browser automation, MCP integrations, and unattended jobs are outside the initial scope.
