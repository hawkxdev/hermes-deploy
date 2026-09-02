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

## GitHub delivery

CI runs on every pull request and push to `main` with read-only repository permission. It validates workflow syntax, the CI/CD contract fixtures, shell scripts, and lifecycle behaviour against the pinned runtime image. CI does not use the protected production environment, production secrets, or the deployment gateway.

Production delivery is a separate, manually dispatched workflow. Its preflight runs before the production job and has no production credentials. The deploy job is bound to the protected `production` environment, so its secrets are released only after the required approval.

### Manual production deployment

1. In GitHub Actions, open `Deploy production`.
2. Choose `main` and select **Run workflow**. Any other branch is rejected.
3. Wait for `Validate deployment revision` to pass. This checks the exact commit selected by the dispatch and exercises the delivery contract without production access.
4. Review the pending `production` environment deployment and approve or reject it under the repository's environment policy. This approval is the production safety gate.
5. Treat only a completed workflow whose deployment verdict is `success` as deployed. Approval, activation, and a container reported as `Up` are not success verdicts by themselves.

The gateway fetches `main` again immediately before staging and requires the requested full commit to equal its current tip. If `main` moved after dispatch, the request fails rather than deploying a stale or different revision.

### Least-privilege host gateway

The one-time bootstrap installs a locked deployment identity, a forced-command adapter, a root-owned gateway and environment, and private state roots. The identity has no interactive command surface or direct Docker, state, or backup access. Its key can invoke only the adapter's literal deployment command, and sudo permits only the exact gateway invocation.

The gateway accepts no command-line arguments and reads one bounded request containing the exact commit. It serializes deployments, validates the fetched Git tree, stages immutable code, creates and verifies a state backup, and only then replaces the `current` symlink atomically. The activated release runs deployment and a separate supervisor-based verification. Release retention runs only after all stages succeed.

### Failure semantics

- A CI or preflight failure reaches neither production secrets nor the host gateway.
- A validation or backup failure happens before activation, so the current release remains selected.
- A deployment or independent verification failure triggers automatic recovery. The gateway restores the previous code, rolls back the image when it changed, and independently verifies the recovered release. The workflow still fails so the failed delivery cannot be mistaken for success.
- If automatic recovery cannot be verified, the workflow reports that manual recovery is required.
- Failed paths do not prune old releases. Retention is success-only.

A normal successful delivery exercises validation, backup, deployment, and verification. Rollback is a conditional failure path; success does not imply that it ran.

## Lifecycle scripts

| Script | Purpose |
|---|---|
| `scripts/validate.sh` | Static checks of the bundle: digest pinning, project name, forbidden settings, mount boundary, limits, and a credential scan of the whole delivered tree proven against a per-run canary |
| `scripts/backup.sh` | Owner-only archive of non-reproducible state outside the deployment tree, with checksum; excludes the package cache and refuses to record a backup whose gateway stop could not be proven |
| `scripts/deploy.sh` | Validates, pulls the pinned image, records the outgoing image, recreates only the gateway service |
| `scripts/verify.sh` | Deployment verdict from the supervisor, not from container state alone |
| `scripts/rollback.sh` | Returns the recorded previous image and proves no data was lost |
| `scripts/restore.sh` | Destructive state restore behind an explicit confirmation gate; extracts to staging and swaps atomically |

Validation and verification write diagnostics to stderr. Backup writes only the archive path to stdout.

Checksums name the archive by its bare filename. Restore computes the hash of the selected archive and compares it directly with the recorded value.

Backup sets its own `umask 077`; archive, checksum sidecar, and a newly created backup directory are owner-only even when the caller uses a permissive umask.

### Why container state is not the verdict

The image entrypoint is a dispatcher: when it holds PID 1 it execs s6-overlay's `/init`, which performs the root bootstrap and then starts the gateway as a supervised service. The gateway can crash and restart in a loop while the container remains `Up`, so `docker ps` reports a healthy container over a broken deployment. `verify.sh` reads the supervisor directly with `s6-svstat` against the profile service slot and refuses to bless a deployment whose gateway is down.

The dispatcher has a second path, and it matters here. If something else already holds PID 1 (`docker run --init`, or a platform init that execs the image entrypoint as a child) it skips `/init` entirely and runs the agent directly, printing a warning that supervised services are unavailable in that runtime. The verdict described below then has nothing to read. The bundle therefore keeps the default entrypoint and never enables `init`, and `validate.sh` enforces both.

A single reading is not enough. A service crash-looping every few seconds still reads `up` in most samples, so the supervisor is sampled several times across a bounded window and the readings are compared. A changed pid between samples is unambiguous proof of a restart; uptime that fails to grow is the secondary signal. `up` alone is also not health: `up ... want down` means the supervisor has been told to stop the service, and `up ... paused` means it is frozen and processing nothing. Both fail the check.

`deploy.sh` and `rollback.sh` consume this verdict and exit non-zero with it. A verdict printed but not acted on is decoration.

### The credential scan reads the tree, and proves itself first

The bundle is more than its compose file. A scan of `compose.yaml` alone reported that no credential or address material was present in the *bundle* while reading a single file of it, and a canary in `config/config.example.yaml` passed with exit 0 under exactly that line. `validate.sh` now scans every file of the delivered tree and reports `path:line` for each hit, never the matched text: a scanner that prints what it found copies the secret into every log that keeps its output.

Documentation addresses (RFC 5737 ranges) are exempt, filtered per match rather than per line so that a real address sharing a line with a documentation one is still reported. Whole files are never excluded; that is the same hole in a different place.

A clean report is ambiguous by construction — patterns that stopped matching look exactly like a clean tree — so before any clean verdict every pattern must find a freshly generated canary in a nested throwaway directory. A blind pattern fails the run instead of blessing it. The canary is random per run, so nothing can accommodate it by learning to ignore a fixed string.

### Mount sources are validated, not just targets

The data directory is operator-controlled through `HERMES_DATA_DIR`. Every mount source must be absolute, avoid sensitive host paths and Docker sockets, and resolve inside the allowed data root. Validation checks both the path as written and its resolved target.

### A symlinked data directory does not silently empty the backup

Backups follow a symlinked data directory and symlinked subdirectories so the archive contains their files rather than link placeholders. Source and archive completeness counts both include regular files only and exclude the reproducible package cache.

### Neighbours are declared, not discovered

A sweep built from `docker ps` sees only what is running, which is precisely the wrong input for the question being asked. A neighbour this deployment stopped drops out of the listing, the check examines whatever survived and reports success; with every neighbour down the listing is empty and the verdict says nothing happened at all. Set `HERMES_NEIGHBOUR_CONTAINERS` to the space-separated names expected on the host and `verify.sh` inspects each one by name, so a stopped or missing container is a failure rather than an absence. A declared list that cannot be checked — no `docker`, or nothing but separators — is also a failure. The running-container sweep remains as a weaker second layer for undeclared neighbours.

### Neighbours are not only containers

A shared host can run services under systemd rather than Docker, and a container-only sweep reports "neighbours are fine" while those services are down: the same blast radius, invisible to the verdict. Set `HERMES_NEIGHBOUR_UNITS` to a space-separated list of unit names where the deployment runs and `verify.sh` will check them too. It is empty by default because unit names are host topology and do not belong in a public bundle.

Both lists are empty in the bundle because those names are host topology, and both are required values of the host environment where deployment actually runs: the bootstrap and the deploy gateway refuse an environment that omits either.

The same holds for `HERMES_REPO_URL`. It used to fall back to a literal inside the gateway, which is precisely what a deleted or renamed public repository looks like from the host: the default kept pointing somewhere plausible, and the failure surfaced as a fetch error rather than as a configuration one. The host now states the contour it deploys from, and the environment is validated before anything reaches the network, so a misconfigured host fails before the first fetch.

### A backup is consistent or it is refused

Controlled downtime is the consistency contract of `backup.sh`, so the stop is proven rather than attempted. A container name that matches nothing, a docker binary that is absent or unable to answer, and a stop that fails all end the run instead of producing an archive: each of them used to warn on stderr and then write an archive, a checksum and exit 0, which is indistinguishable from a consistent copy in the only place anyone looks later. A container that already exists but is not running is a quiet directory and proceeds normally.

`HERMES_BACKUP_STOP_GATEWAY=0` remains available as the explicitly named emergency mode. Its archive carries a `.hot` marker file, and the deploy gateway refuses a marked archive: a hot copy may be taken deliberately by an operator, but it is not a pre-deployment safety net.

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
