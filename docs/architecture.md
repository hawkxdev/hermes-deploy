# Architecture

## Purpose

The bundle defines the desired state for one or more isolated Hermes Agent deployments based on the same official Docker image and versioned lifecycle controls.

## Instance topology

```text
shared Hermes Deploy bundle
    |
    +-- instance alpha
    |      host environment
    |          |
    |          v
    |      deploy user -> forced adapter -> gateway wrapper -> gateway core
    |                                                   |
    |                                                   v
    |                                      Compose project and container
    |                                                   |
    |                                                   v
    |                                      data and backup directories
    |
    +-- instance beta
           host environment
               |
               v
           deploy user -> forced adapter -> gateway wrapper -> gateway core
                                                        |
                                                        v
                                           Compose project and container
                                                        |
                                                        v
                                           data and backup directories
```

Each instance name defines a control-plane namespace. The default name `hermes` preserves the existing paths and identities; another valid name derives a different deployment user, home directory, wrapper, gateway core, forced-command adapter, host environment, repository mirror and lock file.

`ci-deploy-gateway.sh` remains byte-identical across installations and is installed as a separate root-owned core for each instance. A generated wrapper verifies the host environment's file type, owner, permissions, shell syntax and instance identity before sourcing it, then exports that instance's deployment root, repository mirror, lock file and host environment before executing the core. The forced-command adapter derives the wrapper path from its own installed filename, so it does not depend on environment variables surviving `sudo`.

## State boundaries

- `compose.yaml` defines one gateway container per instance and its runtime limits.
- `HERMES_PROJECT` and `HERMES_CONTAINER` identify the instance in Docker and must match the name passed to the bootstrap command.
- `HERMES_DATA_DIR` contains that instance's mutable configuration, credentials, sessions, memories, skills, profiles, logs, uploads, plugins, and package cache.
- `HERMES_BACKUP_DIR` contains that instance's recovery data outside its runtime state directory.

Instances do not share data or backup directories. Deployment never synchronizes or replaces an instance's data directory.

Configuration templates take effect only after they are copied into the data directory. The package cache contains links expressed in the container's path namespace, so the backup contract excludes that reproducible cache while retaining every non-reproducible state path.

## Pinned release

`compose.yaml` pins the official image by manifest digest. The digest corresponds to signed release `v2026.8.3` (Hermes Agent v0.20.0). Moving tags are never used as desired state.

The image ENTRYPOINT is a dispatcher that execs the s6-overlay `/init` process as PID 1, which performs the root bootstrap, volume ownership fixes, and configuration migrations before supervised services start. The deployment therefore keeps the default entrypoint and does not introduce an external init process.

The dispatcher checks whether it is PID 1 and falls back to a direct bootstrap when it is not, which is what makes the rule above load-bearing rather than stylistic: under an external init the fallback runs the agent with no supervision tree, so the supervised service slot that the deployment verdict reads does not exist at all. Entrypoint overrides and `init` are rejected by validation for this reason.

## Security boundary

Each instance uses one official image, one gateway container, one default profile, and one writable mount from its private data directory to `/opt/data`. Multiple instances reuse the versioned bundle but not their container identity, control plane, mutable state, credentials, repository mirror or deployment lock.

Published ports, the Docker socket, privileged mode, unrelated host mounts, custom images, sidecars, browser automation, MCP integrations, and unattended jobs are excluded.
