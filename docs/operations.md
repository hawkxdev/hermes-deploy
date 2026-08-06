# Operations

## Current contract

The repository defines deployment boundaries, safe configuration templates, a Compose bundle pinned to a signed upstream release digest, and the lifecycle scripts that validate, deploy, verify, back up, roll back and restore it. The bundle has not been run against a live host.

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

## Lifecycle scripts

| Script | Purpose |
|---|---|
| `scripts/validate.sh` | Static checks of the bundle: digest pinning, project name, forbidden settings, mount boundary, limits, credential material |
| `scripts/backup.sh` | Full archive of the data directory outside the deployment tree, with checksum; stops the gateway briefly for consistency |
| `scripts/deploy.sh` | Validates, pulls the pinned image, records the outgoing image, recreates only the gateway service |
| `scripts/verify.sh` | Deployment verdict from the supervisor, not from container state alone |
| `scripts/rollback.sh` | Returns the recorded previous image and proves no data was lost |
| `scripts/restore.sh` | Destructive state restore behind an explicit confirmation gate; extracts to staging and swaps atomically |

Validation and verification write diagnostics to stderr; `backup.sh` prints the archive path on stdout so it can be consumed by a pipeline.

Checksums are recorded under the archive's bare filename, never an absolute path, and `restore.sh` computes the hash of the archive it was handed and compares it as a string. Delegating to `shasum -c` verified whatever file sat at the recorded path instead, which both rejected a valid archive moved offsite and blessed an unrelated one.

### Why container state is not the verdict

Inside the official image s6-overlay is PID 1 and the gateway is a supervised service. The gateway can crash and restart in a loop while the container remains `Up`, so `docker ps` reports a healthy container over a broken deployment. `verify.sh` reads the supervisor directly with `s6-svstat` against the profile service slot and refuses to bless a deployment whose gateway is down.

A single reading is not enough. A service crash-looping every few seconds still reads `up` in most samples, so the supervisor is sampled several times across a bounded window and the readings are compared. A changed pid between samples is unambiguous proof of a restart; uptime that fails to grow is the secondary signal. `up` alone is also not health: `up ... want down` means the supervisor has been told to stop the service, and `up ... paused` means it is frozen and processing nothing. Both fail the check.

`deploy.sh` and `rollback.sh` consume this verdict and exit non-zero with it. A verdict printed but not acted on is decoration.

### Mount sources are validated, not just targets

The data directory is operator-controlled through `HERMES_DATA_DIR`. Validating only the mount count and its target left `HERMES_DATA_DIR=/var/run` rendering a bind of the host runtime directory — the docker socket included — while every check still reported a pass. `validate.sh` now checks each mount source directly: it must be absolute, must not be a sensitive host path, must not reach a docker socket, and must live inside the allowed data root.

### Rollback boundary

Rollback swaps the image and nothing else: every other setting comes from `compose.yaml` through an image override, so a rollback cannot silently drop a resource limit or a logging bound. The data directory is inventoried before and after, and a file present before the rollback that is missing afterwards aborts the operation. Process bookkeeping and SQLite sidecar files are excluded from that inventory because their removal is evidence of a clean shutdown, not of data loss.

Restoring state is deliberately not part of rollback. It overwrites state newer than the archive and lives behind its own confirmation in `restore.sh`, which also preserves the displaced directory instead of deleting it.

### Running the tests

```bash
tests/lifecycle/run.sh
```

Static cases run anywhere. Runtime cases are skipped when the pinned image is not present locally, so a missing image reports as skipped rather than as a pass.

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

Procedures are documented above only for scripts that exist and have been exercised on non-production fixtures. Nothing here has yet run against a live host.
