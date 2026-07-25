# Operations

## Current contract

The repository currently defines deployment boundaries and safe configuration templates. It does not yet provide a runnable Compose bundle or lifecycle scripts.

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
