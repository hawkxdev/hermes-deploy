<!--
Read CONTRIBUTING.md before filling this in.

Merged work is imported into the private development repository and returns here in a later projection, so the commit that lands on main is not byte-identical to the one you authored. This pull request stays the durable record of your authorship.
-->

## What changes and why

<!-- The failure or gap this closes, not the patch. Link the issue if one exists: Closes #NNN -->

## How it was proven

<!-- The check that fails before this change and passes after it. State how it tells a refusal by the code under test apart from a refusal by the environment. -->

```
paste the relevant result
```

## Checks run locally

- [ ] `bash scripts/validate.sh`
- [ ] `bash tests/lifecycle/run.sh` with the pinned image already pulled, so no runtime case was skipped
- [ ] `bash tests/cicd/run.sh`
- [ ] ShellCheck for touched shell, actionlint for touched workflows

## Boundaries this change touches

Tick anything it relaxes. Ticking a box does not disqualify the change, but an unticked box that turns out to be false does.

- [ ] Publishes a port, mounts the Docker socket, requests privileged mode or host networking, or adds a broad host mount
- [ ] Enables the dashboard or an API server
- [ ] Overrides the image entrypoint or enables init
- [ ] Introduces a custom image or an additional service
- [ ] Writes to the runtime data directory from the deployment path
- [ ] None of the above

## Confirmations

- [ ] Fixtures carry invented values only: no real tokens, keys, hostnames, addresses, or user IDs
- [ ] Documentation touched here states current behaviour, with no edit timestamps, version stamps, or changelog sections
- [ ] Commit messages follow Conventional Commits
