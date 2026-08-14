# Operations

## Current contract

The repository defines deployment boundaries, safe configuration templates, a Compose bundle pinned to a signed upstream release digest, and the lifecycle scripts that validate, deploy, verify, back up, roll back and restore it.

The bundle has been run against a live host: validation passed on the server, the gateway came up under supervision and stayed up across two independent sampling windows, neighbouring containers and systemd units were unaffected, and a backup was restored into a separate directory with the SQLite stores confirmed intact on the restored copy.

A provider and a messaging platform are configured on that host. Plain and tool-using requests both complete, a dangerous command waits for approval instead of running, the allowlist rejects an unknown sender at the platform adapter before the agent or the provider is reached, and a session survives a controlled restart with its identifier and history intact.

## Compose bundle

`compose.yaml` declares one gateway service under the Compose project name `hermes`, so operations never depend on the checkout directory name and never reach neighboring projects on a shared host.

| Setting | Value |
|---|---|
| Image | Official image pinned by manifest digest |
| Data mount | Single bind mount to `/opt/data` |
| Published ports | None |
| Resource limits | Memory and CPU ceilings |
| Log rotation | Bounded size and file count |

`HERMES_UID`, `HERMES_GID`, and the host data directory are read from the environment with defaults. On any new host they must match the owner of the host data directory. On the target host a read-only audit found those ids unused and the data directory empty, predicting that first boot would assign ownership to them; the deployment confirmed it. That confirmation is host-specific and does not transfer.

`stop_grace_period` is stated rather than left to Docker's default. Measured shutdown stays in the low single-digit seconds, both on an almost empty data directory and on one populated by a first boot, leaving the declared window with a multiple of headroom. Shutdown grows with state, and being killed mid-checkpoint is precisely the failure the backup contract cannot absorb, so the window is deliberately generous. A clean stop leaves its marker file behind and removes the SQLite WAL and SHM sidecars; all stores pass `integrity_check` afterwards.

## Lifecycle scripts

| Script | Purpose |
|---|---|
| `scripts/validate.sh` | Static checks of the bundle: digest pinning, project name, forbidden settings, mount boundary, limits, credential material |
| `scripts/backup.sh` | Archive of non-reproducible state outside the deployment tree, with checksum; excludes the package cache and stops the gateway briefly for consistency |
| `scripts/deploy.sh` | Validates, pulls the pinned image, records the outgoing image, recreates only the gateway service |
| `scripts/verify.sh` | Deployment verdict from the supervisor, not from container state alone |
| `scripts/rollback.sh` | Returns the recorded previous image and proves no data was lost |
| `scripts/restore.sh` | Destructive state restore behind an explicit confirmation gate; extracts to staging and swaps atomically |

Validation and verification write diagnostics to stderr; `backup.sh` prints the archive path on stdout so it can be consumed by a pipeline.

Checksums are recorded under the archive's bare filename, never an absolute path, and `restore.sh` computes the hash of the archive it was handed and compares it as a string. Delegating to `shasum -c` verified whatever file sat at the recorded path instead, which both rejected a valid archive moved offsite and blessed an unrelated one.

### Why container state is not the verdict

The image entrypoint is a dispatcher: when it holds PID 1 it execs s6-overlay's `/init`, which performs the root bootstrap and then starts the gateway as a supervised service. The gateway can crash and restart in a loop while the container remains `Up`, so `docker ps` reports a healthy container over a broken deployment. `verify.sh` reads the supervisor directly with `s6-svstat` against the profile service slot and refuses to bless a deployment whose gateway is down.

The dispatcher has a second path, and it matters here. If something else already holds PID 1 (`docker run --init`, or a platform init that execs the image entrypoint as a child) it skips `/init` entirely and runs the agent directly, printing a warning that supervised services are unavailable in that runtime. The verdict described below then has nothing to read. The bundle therefore keeps the default entrypoint and never enables `init`, and `validate.sh` enforces both.

A single reading is not enough. A service crash-looping every few seconds still reads `up` in most samples, so the supervisor is sampled several times across a bounded window and the readings are compared. A changed pid between samples is unambiguous proof of a restart; uptime that fails to grow is the secondary signal. `up` alone is also not health: `up ... want down` means the supervisor has been told to stop the service, and `up ... paused` means it is frozen and processing nothing. Both fail the check.

`deploy.sh` and `rollback.sh` consume this verdict and exit non-zero with it. A verdict printed but not acted on is decoration.

### Mount sources are validated, not just targets

The data directory is operator-controlled through `HERMES_DATA_DIR`. Validating only the mount count and its target left `HERMES_DATA_DIR=/var/run` rendering a bind of the host runtime directory (the docker socket included) while every check still reported a pass. `validate.sh` now checks each mount source directly: it must be absolute, must not be a sensitive host path, must not reach a docker socket, and must live inside the allowed data root.

### A symlinked data directory does not silently empty the backup

Moving state to a larger volume and leaving a symlink behind is ordinary administration. `tar` archives the link itself rather than its target, which produced a few-hundred-byte archive holding a single entry, and it passed the structure check, the checksum and a full restore while containing no data at all. The operator was left with no backup and nothing indicating it.

Resolving the data directory alone did not fix this, and that half-measure is worth recording: a symlinked *subdirectory* reproduced the identical failure one level down, because `find` does not follow links either, so the file count stayed low and the completeness gate was satisfied by three directory entries. Both ends now traverse links (the archive is written with `tar -h`, every count uses `find -L`), and `restore.sh` resolves the target too, so an archive taken through a link restores under the same environment that produced it and the link itself survives.

The completeness gate compares **regular files in the archive against regular files on disk**. Comparing total entries against files looked equivalent and was not: directory entries alone can exceed the file count, and on a realistic layout that slack was large enough for every file to be missing while the check still passed.

`validate.sh` screens the mount source under **both** spellings, the path as written and the path it resolves to. Checking only what was written let a link inside the allowed root reach `/var/run`, the host runtime directory with the docker socket included, and still report `all checks passed`. Checking only the resolved path is equally unsafe: where the system relocates a sensitive directory, the blacklist stops matching.

### Neighbours are not only containers

A shared host can run services under systemd rather than Docker, and a container-only sweep reports "neighbours are fine" while those services are down: the same blast radius, invisible to the verdict. Set `HERMES_NEIGHBOUR_UNITS` to a space-separated list of unit names where the deployment runs and `verify.sh` will check them too. It is empty by default because unit names are host topology and do not belong in a public bundle.

### Rollback boundary

Rollback swaps the image and nothing else: every other setting comes from `compose.yaml` through an image override, so a rollback cannot silently drop a resource limit or a logging bound. The data directory is inventoried before and after, and a file present before the rollback that is missing afterwards aborts the operation.

The inventory waits for the supervisor to report the gateway up before taking the second reading. Comparing a settled directory against a settled one is what makes the no-loss claim mean anything; sampling mid-boot compares two different moments and calls the difference data loss. Process bookkeeping, SQLite sidecars and the clean-shutdown marker are excluded, because their removal is evidence of a clean stop followed by a normal start rather than of data loss. A rollback inventories a stopped container and then a started one, so the marker would otherwise report every successful rollback as a failure.

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

Procedures are documented above only for scripts that exist. Every one of them has been exercised on non-production fixtures, and the validate, deploy, verify and restore paths have additionally been run against a live host. Rollback has been exercised on fixtures only: at the time of the first deployment there was no previous image to return to. For `backup.sh` against a live host see the limitation below.

## Configuration does not travel with the bundle

Hermes reads `config.yaml` from the data directory, and the deployment never writes there — that boundary is deliberate and protects state from delivery. The consequence is easy to miss: a fail-closed template sitting in this repository has no effect on a running agent until someone copies it across. On first boot Hermes creates the file itself from the image's built-in example, which disables tool-loop hard stops and omits approvals entirely.

Verify the live file rather than the template. A deployment can be entirely correct by every check in `validate.sh` and still run an agent with no guardrails, because the guardrails live in a file the checks do not reach.

## The reproducible package cache is not state

Hermes keeps its package-manager cache under `home/.cache` inside the data directory. Links in that cache are written in the container's path namespace, so a host-side backup sees them as broken. Following them with `tar -h` aborts the archive; storing them without `-h` would reopen the older defect where a link replaces the state behind it.

`backup.sh` therefore excludes exactly `home/.cache`. The same boundary is applied to both operations that define completeness: `find -L` prunes it from the source-file count, and `tar -h` excludes it from the archive. All links outside that cache are still followed, so a symlinked data directory or state subdirectory remains fully backed up.

The regression fixture contains a broken container-path link inside the cache plus real files under both `home` and `sessions`. The backup must succeed, omit the cache, and preserve both state files.

The corrected source contract has not yet been rolled out to the live deployment. Until that release is delivered and a standard backup is verified there, use the previously proven manual procedure:

```bash
docker compose stop gateway
tar -czhf "$ARCHIVE" -C /opt/hermes --exclude="data/home/.cache" data
docker compose start gateway
tar -tzvf "$ARCHIVE" | grep -c '^-'
find -L /opt/hermes/data -path /opt/hermes/data/home/.cache -prune -o -type f -print | wc -l
```

The two counts must match, allowing for the clean-shutdown marker present in the archive but removed on restart. Confirm that `auth.json`, `.env`, `config.yaml` and the session store are inside the archive before trusting it.
