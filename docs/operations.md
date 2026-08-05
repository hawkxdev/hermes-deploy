# Operations

## Current contract

The repository defines deployment boundaries, safe configuration templates, and a Compose bundle pinned to a signed upstream release digest. It does not yet provide lifecycle scripts, and the bundle has not been run against a live host.

## Compose bundle

`compose.yaml` declares one gateway service under the Compose project name `hermes`, so operations never depend on the checkout directory name and never reach neighboring projects on a shared host.

| Setting | Value |
|---|---|
| Image | Official image pinned by manifest digest |
| Data mount | Single bind mount to `/opt/data` |
| Published ports | None |
| Resource limits | Memory and CPU ceilings |
| Log rotation | Bounded size and file count |

`HERMES_UID`, `HERMES_GID`, and the host data directory are read from the environment with defaults. They must be set to values that match the owner of the host data directory before a real deployment; the shipped defaults are placeholders, not verified host values.

## Runtime paths

| Path | Purpose |
|---|---|
| `/opt/hermes/deploy` | Versioned deployment bundles |
| `/opt/hermes/data` | Private mutable Hermes state |
| `/opt/backups/hermes` | Recovery data outside the deployment tree |

## Safety rules

- Do not copy production credentials or runtime state into this repository.
- Do not synchronize, clean, or replace `/opt/hermes/data` during deployment.
- Do not expose API or dashboard ports in the initial Telegram-only deployment.
- Do not use host-wide Docker cleanup commands.
- Do not restore state as part of a routine image rollback.
- Do not operate on neighboring Compose projects.

Executable validation, backup, deployment, verification, restoration, and rollback procedures will be documented only after their scripts exist and have been verified on non-production fixtures.
