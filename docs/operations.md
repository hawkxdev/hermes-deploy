# Operations

## Compose bundle

`compose.yaml` declares one gateway service under the fixed Compose project name `hermes`, so service-scoped operations cannot reach neighboring projects on a shared host.

| Setting | Value |
|---|---|
| Image | Official image pinned by manifest digest |
| Data mount | Single bind mount to `/opt/data` |
| Published ports | None |
| Resource limits | Memory and CPU ceilings |
| Log rotation | Bounded size and file count |

`HERMES_UID`, `HERMES_GID`, and the host data directory are read from the environment with defaults. On a new host, the identifiers must match the owner of the host data directory.

`stop_grace_period` is explicit. A clean stop leaves its marker file behind, removes the SQLite WAL and SHM sidecars, and leaves every store ready for an integrity check.

## Lifecycle scripts

| Script | Purpose |
|---|---|
| `scripts/validate.sh` | Static checks of the bundle: digest pinning, project name, forbidden settings, mount boundary, limits, credential material |
| `scripts/backup.sh` | Archive of non-reproducible state outside the deployment tree, with checksum; excludes the package cache and stops the gateway briefly for consistency |
| `scripts/deploy.sh` | Validates, pulls the pinned image, records the outgoing image, recreates only the gateway service |
| `scripts/verify.sh` | Deployment verdict from the supervisor, not from container state alone |
| `scripts/rollback.sh` | Returns the recorded previous image and proves no data was lost |
| `scripts/restore.sh` | Destructive state restore behind an explicit confirmation gate; extracts to staging and swaps atomically |

Validation and verification write diagnostics to stderr. Backup writes only the archive path to stdout.

Checksums name the archive by its bare filename. Restore computes the hash of the selected archive and compares it directly with the recorded value.

### Why container state is not the verdict

The image entrypoint is a dispatcher: when it holds PID 1 it execs s6-overlay's `/init`, which performs the root bootstrap and then starts the gateway as a supervised service. The gateway can crash and restart in a loop while the container remains `Up`, so `docker ps` reports a healthy container over a broken deployment. `verify.sh` reads the supervisor directly with `s6-svstat` against the profile service slot and refuses to bless a deployment whose gateway is down.

The dispatcher has a second path, and it matters here. If something else already holds PID 1 (`docker run --init`, or a platform init that execs the image entrypoint as a child) it skips `/init` entirely and runs the agent directly, printing a warning that supervised services are unavailable in that runtime. The verdict described below then has nothing to read. The bundle therefore keeps the default entrypoint and never enables `init`, and `validate.sh` enforces both.

A single reading is not enough. A service crash-looping every few seconds still reads `up` in most samples, so the supervisor is sampled several times across a bounded window and the readings are compared. A changed pid between samples is unambiguous proof of a restart; uptime that fails to grow is the secondary signal. `up` alone is also not health: `up ... want down` means the supervisor has been told to stop the service, and `up ... paused` means it is frozen and processing nothing. Both fail the check.

`deploy.sh` and `rollback.sh` consume this verdict and exit non-zero with it. A verdict printed but not acted on is decoration.

### Mount sources are validated, not just targets

The data directory is operator-controlled through `HERMES_DATA_DIR`. Every mount source must be absolute, avoid sensitive host paths and Docker sockets, and resolve inside the allowed data root. Validation checks both the path as written and its resolved target.

### A symlinked data directory does not silently empty the backup

Backups follow a symlinked data directory and symlinked subdirectories so the archive contains their files rather than link placeholders. Source and archive completeness counts both include regular files only and exclude the reproducible package cache.

### Neighbours are not only containers

A shared host can run services under systemd rather than Docker, and a container-only sweep reports "neighbours are fine" while those services are down: the same blast radius, invisible to the verdict. Set `HERMES_NEIGHBOUR_UNITS` to a space-separated list of unit names where the deployment runs and `verify.sh` will check them too. It is empty by default because unit names are host topology and do not belong in a public bundle.

### Rollback boundary

Rollback swaps the image and nothing else: every other setting comes from `compose.yaml` through an image override, so a rollback cannot silently drop a resource limit or a logging bound. The data directory is inventoried before and after, and a file present before the rollback that is missing afterwards aborts the operation.

The inventory waits for the supervisor to report the gateway up before taking the second reading. Comparing a settled directory against a settled one is what makes the no-loss claim mean anything; sampling mid-boot compares two different moments and calls the difference data loss. Only top-level process `.pid` and `.lock` files, SQLite sidecars and the clean-shutdown marker are excluded as transient lifecycle bookkeeping.

Before replacement, rollback inventories the exact bundled skill files in the running image and excludes only their corresponding materialized paths under `skills/`. Those paths are image-owned code that a downgrade may legitimately remove; arbitrary custom skills absent from that exact list remain protected as durable state.

The gateway-lock rule is equally narrow: only direct `*.lock` children of `.local/state/hermes/gateway-locks/` are excluded because container recreation removes them and the compatible runtime recreates them on startup. Lock files in arbitrary nested directories, including dependency lockfiles inside skills or plugins, remain in the inventory, so their disappearance still aborts rollback.

Restoring state is deliberately not part of rollback. It overwrites state newer than the archive and lives behind its own confirmation in `restore.sh`, which also preserves the displaced directory instead of deleting it.

## Runtime paths

| Path | Purpose |
|---|---|
| `/opt/hermes/data` | Private mutable Hermes state |
| `/opt/backups/hermes` | Recovery data outside the deployment tree |

## Safety rules

- Do not store production credentials or runtime state in the deployment bundle.
- Do not synchronize, clean, or replace `/opt/hermes/data` during deployment.
- Do not expose API or dashboard ports in the Telegram-only deployment.
- Do not use host-wide Docker cleanup commands.
- Do not restore state as part of a routine image rollback.
- Do not operate on neighboring Compose projects.

## Configuration does not travel with the bundle

Hermes reads `config.yaml` from the data directory, and deployment never overwrites it. A supplied fail-closed template has no effect until it is copied into that directory. On first boot Hermes otherwise creates the file from the image's built-in example, which disables tool-loop hard stops and omits approvals.

Inspect the live file rather than assuming the supplied template is active.

## The reproducible package cache is not state

Hermes keeps its package-manager cache under `home/.cache` inside the data directory. Links in that cache are written in the container's path namespace, so a host-side backup sees them as broken. Backups exclude this reproducible cache while following every link outside it.

`backup.sh` therefore excludes exactly `home/.cache`. The same boundary is applied to both operations that define completeness: `find -L` prunes it from the source-file count, and `tar -h` excludes it from the archive. All links outside that cache are still followed, so a symlinked data directory or state subdirectory remains fully backed up.

For every archive, inspect its listing and checksum, compare the regular-file count with the source while excluding `home/.cache`, and confirm that `auth.json`, `.env`, `config.yaml`, the session store, `state.db`, `kanban.db`, and `cron/executions.db` are present before trusting it.
