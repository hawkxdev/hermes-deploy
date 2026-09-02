# Contributing

Thank you for considering a contribution. This repository is small, its boundaries are deliberate, and most of the rules below exist because a specific failure taught them.

## How changes reach this repository

Releases arrive as a projection of a private development repository. The public history is rebuilt by machine from that source, so direct pushes are limited to the maintainer and the branch refuses force pushes and deletion.

An accepted pull request is imported into the private repository and returns here in a later projection. Your change ships, but the commit that lands on `main` is not byte-identical to the one you authored. Attribution stays in the pull request, which remains the durable record of who contributed what.

## Before you open a pull request

Fork the repository, branch from `main`, and run the same checks CI runs.

```bash
bash scripts/validate.sh
bash tests/lifecycle/run.sh
bash tests/cicd/run.sh
```

The lifecycle suite reports runtime cases as skipped when the pinned image is not available locally. CI pulls the pinned image and fails if those cases skip, so pull the image before trusting a local pass.

Shell changes must survive ShellCheck, and workflow changes must survive actionlint. CI runs both:

```bash
docker run --rm --volume "$PWD:/mnt:ro" --workdir /mnt koalaman/shellcheck -x scripts/*.sh tests/cicd/run.sh tests/lifecycle/run.sh
```

Open the pull request against `main`. The `lifecycle` check is required and cannot be bypassed.

## What will be refused

The bundle's exclusions are the product, not an oversight. A change is refused if it publishes ports, mounts the Docker socket, requests privileged mode or host networking, adds broad host mounts, enables the dashboard or an API server, introduces a custom image, overrides the image entrypoint, or enables `init`.

The last two deserve their own sentence. Supervision exists only while the image's dispatcher receives PID 1; an external PID 1 sends it down a path with no supervised services, and every health check in this repository loses its subject.

Changes that write to the runtime data directory from the deployment path are also refused. Deployment delivers code; state belongs to the host.

## Writing tests

A test that passes without reaching the code under test is a defect, not coverage. This is not hypothetical here: an early neighbour-container test passed against a script where the function did not yet exist, because `bash` itself failed and the harness counted the failure as the expected refusal. Tests must distinguish a refusal by the code under test from a refusal by the environment.

Fixtures carry invented values only. No real tokens, keys, hostnames, or addresses reach this repository, including in tests.

## Style

Shell is Bash with `set -euo pipefail`. Definitions shared by more than one script live in `scripts/_lib.sh` rather than being copied; duplicated readiness logic once made every rollback declare a healthy deployment broken.

Commit messages follow Conventional Commits, for example `fix(verify): compare neighbour containers by name`.

Documentation states the current behaviour. It carries no edit timestamps, version stamps, or changelog sections.

## Security issues

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## Conduct

Participation is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).
