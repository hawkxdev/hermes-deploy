#!/usr/bin/env bash
# CI/CD contract and deployment gateway fixture suite.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/../.." && pwd -P)"
GIT_ROOT="$(git -C "$REPO_ROOT" rev-parse --show-toplevel)"
PUBLIC_CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
PUBLIC_DEPLOY_WORKFLOW="$REPO_ROOT/.github/workflows/deploy.yml"
SOURCE_CI_WORKFLOW=""
if [ "$GIT_ROOT" != "$REPO_ROOT" ]; then
	SOURCE_CI_WORKFLOW="$GIT_ROOT/.github/workflows/source-ci.yml"
fi
SCRIPTS="$REPO_ROOT/scripts"
WORK="$(mktemp -d)"
DEPLOY_ROOT="$WORK/deploy"
ORIGIN="$WORK/origin.git"
FLOCK_STUB="$WORK/flock"
cat >"$FLOCK_STUB" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$FLOCK_STUB"

trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
skipped=0

ok() {
	printf 'PASS  %s\n' "$1"
	passed=$((passed + 1))
}

no() {
	printf 'FAIL  %s\n' "$1" >&2
	failed=$((failed + 1))
}

skip() {
	printf 'SKIP  %s\n' "$1"
	skipped=$((skipped + 1))
}

require_ci_pattern() {
	local pattern="$1" description="$2"
	if grep -Eq "$pattern" "$PUBLIC_CI_WORKFLOW"; then
		ok "$description"
	else
		no "$description"
	fi
}

reject_ci_pattern() {
	local pattern="$1" description="$2"
	if grep -Eq "$pattern" "$PUBLIC_CI_WORKFLOW"; then
		no "$description"
	else
		ok "$description"
	fi
}

require_file_pattern() {
	local file="$1" pattern="$2" description="$3"
	if grep -Eq "$pattern" "$file"; then
		ok "$description"
	else
		no "$description"
	fi
}

reject_file_pattern() {
	local file="$1" pattern="$2" description="$3"
	if grep -Eq "$pattern" "$file"; then
		no "$description"
	else
		ok "$description"
	fi
}

file_mode() {
	if stat -c '%a' "$1" >/dev/null 2>&1; then
		stat -c '%a' "$1"
	else
		stat -f '%Lp' "$1"
	fi
}

printf '== repository release contract ==\n'
if git -C "$REPO_ROOT" ls-files --error-unmatch .memory/handoff.md >/dev/null 2>&1; then
	no "local session handoff is absent from the public Git tree"
else
	ok "local session handoff is absent from the public Git tree"
fi
if [ -e "$REPO_ROOT/.memory" ] || [ -L "$REPO_ROOT/.memory" ]; then
	no "nested local session state is absent from the public checkout"
else
	ok "nested local session state is absent from the public checkout"
fi
if git -C "$REPO_ROOT" check-ignore -q .memory/handoff.md; then
	no "nested local session state remains visible as drift"
else
	ok "nested local session state remains visible as drift"
fi
printf '\n'

printf '== public workflow contract ==\n'
if [ ! -f "$PUBLIC_CI_WORKFLOW" ]; then
	no "public CI workflow is present"
else
	require_ci_pattern '^  push:$' "public CI runs on push"
	require_ci_pattern '^    branches: \[main\]$' "public CI push is limited to main"
	require_ci_pattern '^  pull_request:$' "public CI runs on pull requests"
	require_ci_pattern '^permissions:$' "public CI declares token permissions"
	require_ci_pattern '^  contents: read$' "public CI token is read-only"
	require_ci_pattern '^    runs-on: ubuntu-24\.04$' "public CI uses a GitHub-hosted runner"
	require_ci_pattern '^          persist-credentials: false$' \
		"public checkout credentials are not persisted"
	require_ci_pattern \
		'uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' \
		"public CI checkout revision is a verified upstream commit"
	require_ci_pattern 'actionlint_1\.7\.12_linux_amd64\.tar\.gz$' \
		"public CI actionlint version is pinned"
	require_ci_pattern 'ACTIONLINT_SHA256: 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8$' \
		"public CI actionlint checksum is pinned"
	require_ci_pattern \
		'koalaman/shellcheck@sha256:bb596a0d169b85ddd81d8b6d3a2ff6d5baf5fca10b97f575ebc647c3dff62b3d' \
		"public CI ShellCheck image is pinned"
	require_ci_pattern '^          -x scripts/\*\.sh tests/cicd/run\.sh tests/lifecycle/run\.sh$' \
		"public CI follows sourced shell libraries"
	require_ci_pattern '^        run: tests/cicd/run\.sh$' \
		"public CI runs tests from the public root"
	require_ci_pattern 'image="\$\(docker compose config --format json' \
		"public CI resolves Compose from the public root"
	require_ci_pattern 'output="\$\(tests/lifecycle/run\.sh\)"' \
		"public CI runs lifecycle tests from the public root"
	reject_ci_pattern '^        run: shellcheck ' \
		"public CI does not use runner-provided ShellCheck"
	reject_ci_pattern 'pull_request_target' \
		"public CI does not use pull_request_target"
	reject_ci_pattern 'runs-on:.*self-hosted' \
		"public CI does not use a self-hosted runner"
	reject_ci_pattern 'secrets\.' "public CI does not read production secrets"
	reject_ci_pattern '^    environment:' \
		"public CI does not enter a deployment environment"
	reject_ci_pattern '(^|[[:space:]])app/' \
		"public CI contains no private-root path prefix"

	uses_lines="$(grep -E '^[[:space:]]*uses:' "$PUBLIC_CI_WORKFLOW" || true)"
	if [ -z "$uses_lines" ]; then
		no "public CI contains an immutable Action reference"
	elif printf '%s\n' "$uses_lines" |
		grep -Ev '^[[:space:]]*uses: [^[:space:]@]+@[0-9a-f]{40}([[:space:]]+#.*)?$' >/dev/null; then
		no "every public CI Action reference uses a full commit SHA"
	else
		ok "every public CI Action reference uses a full commit SHA"
	fi
fi

if (cd "$REPO_ROOT" && docker compose config -q); then
	ok "public Compose resolves from the public root"
else
	no "public Compose resolves from the public root"
fi

printf '\n== deploy workflow contract ==\n'
if [ ! -f "$PUBLIC_DEPLOY_WORKFLOW" ]; then
	no "public deploy workflow is present"
else
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '^  workflow_dispatch:$' \
		"deploy uses only a manual trigger"
	reject_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'^  (push|pull_request|pull_request_target|schedule|repository_dispatch|workflow_call):' \
		"deploy has no automatic, reusable or privileged event trigger"
	reject_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '^    inputs:' \
		"deploy accepts no caller-controlled inputs"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '^permissions:$' \
		"deploy declares token permissions"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '^  contents: read$' \
		"deploy token is read-only"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '^  group: hermes-production$' \
		"deploy uses one production concurrency group"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '^  cancel-in-progress: false$' \
		"deploy never cancels an active production rollout"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '^    environment: production$' \
		"deployment secrets are protected by the production environment"
	environment_count="$(grep -Ec '^    environment: production$' "$PUBLIC_DEPLOY_WORKFLOW")"
	if [ "$environment_count" -eq 1 ]; then
		ok "only the deployment job enters production"
	else
		no "only the deployment job enters production"
	fi
	environment_line="$(grep -n '^    environment: production$' "$PUBLIC_DEPLOY_WORKFLOW" |
		cut -d: -f1)"
	if sed -n "1,$((environment_line - 1))p" "$PUBLIC_DEPLOY_WORKFLOW" |
		grep -Eq 'secrets\.'; then
		no "preflight cannot read production secrets"
	else
		ok "preflight cannot read production secrets"
	fi
	secret_names="$(grep -Eo 'secrets\.[A-Z_]+' "$PUBLIC_DEPLOY_WORKFLOW" |
		sort -u)"
	expected_secret_names="$(printf '%s\n' \
		secrets.DEPLOY_HOST secrets.DEPLOY_KNOWN_HOSTS \
		secrets.DEPLOY_SSH_KEY secrets.DEPLOY_USER)"
	if [ "$secret_names" = "$expected_secret_names" ]; then
		ok "deploy reads only the four production secrets"
	else
		no "deploy reads only the four production secrets"
	fi
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '^    needs: preflight$' \
		"deployment waits for preflight"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" 'refs/heads/main' \
		"deploy rejects every ref except main"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'DEPLOY_REF: \$\{\{ github\.ref \}\}' \
		"deploy preflight reads the dispatched ref"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'\[ "[$]DEPLOY_REF" = "refs/heads/main" \]' \
		"deploy preflight fails non-main dispatches"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'ref: \$\{\{ github\.sha \}\}' \
		"deploy preflight checks out the exact dispatch SHA"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' \
		"deploy checkout revision is a verified upstream commit"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" 'docker pull "[$]image"' \
		"deploy preflight pulls the pinned runtime image"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'output="\$\(tests/lifecycle/run\.sh\)"' \
		"deploy preflight runs the lifecycle suite"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'runtime cases were skipped after the pinned image pull' \
		"deploy preflight rejects skipped runtime tests"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" 'actionlint_1\.7\.12_linux_amd64\.tar\.gz$' \
		"deploy preflight pins actionlint"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'ACTIONLINT_SHA256: 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8$' \
		"deploy preflight pins the actionlint checksum"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'koalaman/shellcheck@sha256:bb596a0d169b85ddd81d8b6d3a2ff6d5baf5fca10b97f575ebc647c3dff62b3d' \
		"deploy preflight pins ShellCheck"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'^          -x scripts/\*\.sh tests/cicd/run\.sh tests/lifecycle/run\.sh$' \
		"deploy preflight follows sourced shell libraries"
	reject_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" 'runs-on:.*self-hosted' \
		"deploy does not use a self-hosted runner"
	reject_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" 'pull_request_target' \
		"deploy does not use pull_request_target"
	reject_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '\$\{\{[[:space:]]*inputs\.' \
		"deploy shell receives no workflow input"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" 'StrictHostKeyChecking=yes' \
		"deploy requires trusted SSH host keys"
	reject_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" 'StrictHostKeyChecking=no' \
		"deploy cannot disable SSH host verification"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'HERMES_DEPLOY_V1 %s\\n.*DEPLOY_SHA.*\| ssh' \
		"deploy sends only the SHA protocol"
	require_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" \
		'DEPLOY_SHA: \$\{\{ github\.sha \}\}' \
		"deploy sends the public repository SHA"
	reject_file_pattern "$PUBLIC_DEPLOY_WORKFLOW" '(^|[[:space:]])app/' \
		"deploy contains no private-root path prefix"

	deploy_uses="$(grep -E '^[[:space:]]*uses:' "$PUBLIC_DEPLOY_WORKFLOW" || true)"
	if [ -z "$deploy_uses" ]; then
		no "deploy contains an immutable Action reference"
	elif printf '%s\n' "$deploy_uses" |
		grep -Ev '^[[:space:]]*uses: [^[:space:]@]+@[0-9a-f]{40}([[:space:]]+#.*)?$' >/dev/null; then
		no "every deploy Action reference uses a full commit SHA"
	else
		ok "every deploy Action reference uses a full commit SHA"
	fi
fi

if [ -n "$SOURCE_CI_WORKFLOW" ]; then
	printf '\n== private source workflow contract ==\n'
	workflow_files="$(find "$GIT_ROOT/.github/workflows" -maxdepth 1 -type f \
		\( -name '*.yml' -o -name '*.yaml' \) -print | sort)"
	if [ "$workflow_files" = "$SOURCE_CI_WORKFLOW" ]; then
		ok "private root contains exactly one source CI workflow"
	else
		no "private root contains exactly one source CI workflow"
	fi
	if [ ! -f "$SOURCE_CI_WORKFLOW" ]; then
		no "private source CI workflow is present"
	else
		require_file_pattern "$SOURCE_CI_WORKFLOW" '^name: Source CI$' \
			"private workflow has a distinct source CI role"
		require_file_pattern "$SOURCE_CI_WORKFLOW" '^        run: app/tests/cicd/run\.sh$' \
			"private source CI invokes the cross-boundary suite"
		require_file_pattern "$SOURCE_CI_WORKFLOW" \
			'docker compose -f app/compose\.yaml config -q' \
			"private source CI names the public Compose file"
		require_file_pattern "$SOURCE_CI_WORKFLOW" \
			'^          -x scripts/\*\.sh tests/cicd/run\.sh tests/lifecycle/run\.sh$' \
			"private source CI follows public sourced shell libraries"
		reject_file_pattern "$SOURCE_CI_WORKFLOW" 'secrets\.' \
			"private source CI reads no deployment secrets"
		reject_file_pattern "$SOURCE_CI_WORKFLOW" '^    environment:' \
			"private source CI enters no deployment environment"
		reject_file_pattern "$SOURCE_CI_WORKFLOW" \
			'(ssh|DEPLOY_HOST|DEPLOY_KEY|DEPLOY_KNOWN_HOSTS|DEPLOY_USER)' \
			"private source CI contains no production transport"
	fi
	if (cd "$GIT_ROOT" && docker compose -f app/compose.yaml config -q); then
		ok "private source tree resolves public Compose explicitly"
	else
		no "private source tree resolves public Compose explicitly"
	fi
fi
printf '\n== gateway protocol ==\n'
SOURCE="$WORK/source"
mkdir -p "$SOURCE"
git -C "$SOURCE" init -q -b main
git -C "$SOURCE" config user.name "CI fixture"
git -C "$SOURCE" config user.email "ci-fixture@example.invalid"
printf 'old\n' >"$SOURCE/README.md"
git -C "$SOURCE" add README.md
git -C "$SOURCE" commit -q -m "old"
OLD_SHA="$(git -C "$SOURCE" rev-parse HEAD)"
printf 'current\n' >"$SOURCE/README.md"
git -C "$SOURCE" commit -q -am "current"
CURRENT_SHA="$(git -C "$SOURCE" rev-parse HEAD)"
git clone -q --bare "$SOURCE" "$ORIGIN"

write_host_env() {
	local validate_fail="$1" backup_fail="$2"
	local deploy_fail="${3:-0}" verify_fail="${4:-0}"
	local write_previous_image="${5:-0}" rollback_fail="${6:-0}"
	local previous_verify_fail="${7:-0}" backup_hot="${8:-0}"
	cat >"$WORK/host.env" <<EOF
HERMES_DATA_DIR='$WORK/data'
HERMES_BACKUP_DIR='$WORK/backups'
HERMES_CONTAINER='fixture'
HERMES_PROFILE='default'
HERMES_ALLOWED_DATA_ROOT='$WORK'
HERMES_NEIGHBOUR_UNITS='fixture.service'
HERMES_NEIGHBOUR_CONTAINERS='fixture-neighbour'
HERMES_REPO_URL='$ORIGIN'
HERMES_CI_FIXTURE_LOG='$WORK/stages.log'
HERMES_FIXTURE_VALIDATE_FAIL='$validate_fail'
HERMES_FIXTURE_BACKUP_FAIL='$backup_fail'
HERMES_FIXTURE_DEPLOY_FAIL='$deploy_fail'
HERMES_FIXTURE_VERIFY_FAIL='$verify_fail'
HERMES_FIXTURE_WRITE_PREVIOUS_IMAGE='$write_previous_image'
HERMES_FIXTURE_ROLLBACK_FAIL='$rollback_fail'
HERMES_FIXTURE_PREVIOUS_VERIFY_FAIL='$previous_verify_fail'
HERMES_FIXTURE_BACKUP_HOT='$backup_hot'
EOF
	chmod 0600 "$WORK/host.env"
}

request() {
	local payload="$1"
	# Payloads use visible \n escapes so edge cases remain readable.

	printf '%b' "$payload" | env \
		HERMES_DEPLOY_ROOT="$DEPLOY_ROOT" \
		HERMES_FLOCK_BIN="$FLOCK_STUB" \
		HERMES_DEPLOY_TESTING=1 \
		HERMES_HOST_ENV="$WORK/host.env" \
		HERMES_LOCK_FILE="$WORK/deploy.lock" \
		"$SCRIPTS/ci-deploy-gateway.sh" 2>&1
}

# The gateway validates the host environment before it reaches the network, so
# every case below needs a valid one — including those that assert a rejection
# happening before the fetch.
write_host_env 0 0

expect_rejected_before_fetch() {
	local payload="$1" description="$2"
	rm -rf "$DEPLOY_ROOT"
	if request "$payload" >/dev/null; then
		no "$description"
	elif [ -e "$DEPLOY_ROOT/repository.git" ]; then
		no "$description"
	else
		ok "$description"
	fi
}

if [ ! -x "$SCRIPTS/ci-deploy-gateway.sh" ]; then
	no "deployment gateway exists and is executable"
else
	expect_rejected_before_fetch 'deploy main\n' \
		"malformed protocol is rejected before fetch"
	expect_rejected_before_fetch "HERMES_DEPLOY_V1 ${CURRENT_SHA}0\n" \
		"invalid SHA length is rejected before fetch"
	BAD_SHA="${CURRENT_SHA%?}g"
	expect_rejected_before_fetch "HERMES_DEPLOY_V1 $BAD_SHA\n" \
		"non-hex SHA is rejected before fetch"
	UPPER_SHA="$(printf '%s' "$CURRENT_SHA" | tr '[:lower:]' '[:upper:]')"
	expect_rejected_before_fetch "HERMES_DEPLOY_V1 $UPPER_SHA\n" \
		"uppercase SHA is rejected before fetch"
	expect_rejected_before_fetch "HERMES_DEPLOY_V1 $CURRENT_SHA extra\n" \
		"extra protocol fields are rejected before fetch"
	expect_rejected_before_fetch "HERMES_DEPLOY_V1 $CURRENT_SHA\ntrailing" \
		"trailing payload is rejected before fetch"

	rm -rf "$DEPLOY_ROOT"
	if printf 'HERMES_DEPLOY_V1 %s\n' "$CURRENT_SHA" | env \
		HERMES_DEPLOY_ROOT="$DEPLOY_ROOT" \
		HERMES_FLOCK_BIN="$FLOCK_STUB" \
		HERMES_HOST_ENV="$WORK/host.env" \
		HERMES_DEPLOY_TESTING=1 \
		HERMES_LOCK_FILE="$WORK/deploy.lock" \
		"$SCRIPTS/ci-deploy-gateway.sh" unexpected >/dev/null 2>&1; then
		no "gateway argv is rejected"
	elif [ -e "$DEPLOY_ROOT/repository.git" ]; then
		no "gateway argv is rejected before fetch"
	else
		ok "gateway argv is rejected before fetch"
	fi

	rm -rf "$DEPLOY_ROOT"
	if request "HERMES_DEPLOY_V1 $OLD_SHA\n" >/dev/null; then
		no "historical main commit is rejected"
	elif [ ! -d "$DEPLOY_ROOT/repository.git" ]; then
		no "historical main check fetched origin"
	elif [ -d "$DEPLOY_ROOT/releases" ] &&
		find "$DEPLOY_ROOT/releases" -mindepth 1 -print -quit | grep -q .; then
		no "historical main rejection created a release"
	else
		ok "only current origin main is deployable"
	fi
fi

printf '\n== release staging ==\n'
mkdir -p "$SOURCE/scripts"
cat >"$SOURCE/scripts/validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'validate\n' >>"$HERMES_CI_FIXTURE_LOG"
printf 'private topology: %s\n' "$HERMES_NEIGHBOUR_UNITS" >&2
[ "${HERMES_FIXTURE_VALIDATE_FAIL:-0}" = "0" ] || exit 31
[ "${HERMES_FIXTURE_VALIDATE_DELAY:-0}" = "0" ] ||
	sleep "$HERMES_FIXTURE_VALIDATE_DELAY"
EOF
cat >"$SOURCE/scripts/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'backup\n' >>"$HERMES_CI_FIXTURE_LOG"
[ "${HERMES_FIXTURE_BACKUP_FAIL:-0}" = "0" ] || exit 32
mkdir -p "$HERMES_BACKUP_DIR"
archive="$HERMES_BACKUP_DIR/fixture.tar.gz"
printf 'fixture\n' >"$archive"
(
	cd "$HERMES_BACKUP_DIR"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$(basename "$archive")" >"$(basename "$archive").sha256"
	else
		sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256"
	fi
)
# A backup that could not prove the gateway stopped marks its archive. The real
# script does this too; the deployment must refuse such an archive rather than
# treat a hot copy as a pre-deployment safety net.
# The real script timestamps every archive, so a marker can never outlive its
# run. This fixture reuses one name, so it must clear the marker explicitly —
# otherwise one hot case silently marks every deployment that follows it.
if [ "${HERMES_FIXTURE_BACKUP_HOT:-0}" = "0" ]; then
	rm -f "$archive.hot"
else
	printf 'fixture hot\n' >"$archive.hot"
fi
printf '%s\n' "$archive"
EOF
cat >"$SOURCE/scripts/deploy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'deploy\n' >>"$HERMES_CI_FIXTURE_LOG"
if [ "${HERMES_FIXTURE_WRITE_PREVIOUS_IMAGE:-0}" = "1" ]; then
	printf 'fixture@sha256:%064d\n' 0 >"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.previous-image"
fi
[ "${HERMES_FIXTURE_DEPLOY_FAIL:-0}" = "0" ] || exit 33
EOF
cat >"$SOURCE/scripts/verify.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify\n' >>"$HERMES_CI_FIXTURE_LOG"
[ "${HERMES_FIXTURE_VERIFY_FAIL:-0}" = "0" ] || exit 34
EOF
cat >"$SOURCE/scripts/rollback.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'new-rollback\n' >>"$HERMES_CI_FIXTURE_LOG"
exit 35
EOF
chmod 0755 "$SOURCE"/scripts/*.sh
printf 'services: {}\n' >"$SOURCE/compose.yaml"
git -C "$SOURCE" add README.md compose.yaml scripts
git -C "$SOURCE" commit -q -m "fixture bundle"
BUNDLE_SHA="$(git -C "$SOURCE" rev-parse HEAD)"
git -C "$SOURCE" push -q --force "$ORIGIN" main:main


reset_current() {
	rm -rf "$DEPLOY_ROOT"
	mkdir -p "$DEPLOY_ROOT/releases/existing/scripts"
	cat >"$DEPLOY_ROOT/releases/existing/scripts/rollback.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'previous-rollback\n' >>"$HERMES_CI_FIXTURE_LOG"
[ "${HERMES_FIXTURE_ROLLBACK_FAIL:-0}" = "0" ] || exit 41
[ -f "$HERMES_PREVIOUS_IMAGE_FILE" ] || exit 42
EOF
	cat >"$DEPLOY_ROOT/releases/existing/scripts/verify.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'previous-verify\n' >>"$HERMES_CI_FIXTURE_LOG"
[ "${HERMES_FIXTURE_PREVIOUS_VERIFY_FAIL:-0}" = "0" ] || exit 43
EOF
	chmod 0755 "$DEPLOY_ROOT/releases/existing/scripts/"*.sh
	ln -s releases/existing "$DEPLOY_ROOT/current"
	: >"$WORK/stages.log"
}

current_is_existing() {
	[ -L "$DEPLOY_ROOT/current" ] &&
		[ "$(readlink "$DEPLOY_ROOT/current")" = "releases/existing" ]
}

has_staging_residue() {
	[ -d "$DEPLOY_ROOT/releases" ] &&
		find "$DEPLOY_ROOT/releases" -maxdepth 1 -type d -name '.staging-*' \
			-print -quit | grep -q .
}

write_host_env 0 0
reset_current
request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >/dev/null || true
if [ "$(sed -n '1p' "$WORK/stages.log")" = "validate" ] &&
	[ "$(sed -n '2p' "$WORK/stages.log")" = "backup" ]; then
	ok "regular bundle reaches validation and verified backup"
else
	no "regular bundle reaches validation and verified backup"
fi
if has_staging_residue; then
	no "regular staging leaves no temporary directory"
else
	ok "regular staging leaves no temporary directory"
fi

write_host_env 1 0
reset_current
if request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >/dev/null; then
	no "validation failure is fatal"
elif current_is_existing && [ "$(cat "$WORK/stages.log")" = "validate" ] &&
	! has_staging_residue; then
	ok "validation failure preserves current and removes staging"
else
	no "validation failure preserves current and removes staging"
fi

write_host_env 0 1
reset_current
if request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >/dev/null; then
	no "backup failure is fatal"
elif current_is_existing &&
	[ "$(<"$WORK/stages.log")" = "$(printf 'validate\nbackup\n')" ] &&
	! has_staging_residue; then
	ok "backup failure preserves current and removes staging"
else
	no "backup failure preserves current and removes staging"
fi

# An unproven copy is not a safety net. The backup script may still produce one
# on purpose in an emergency, but it marks it, and a deployment that accepted the
# marked artifact would restore exactly the false confidence the marker exists to
# remove.
write_host_env 0 0 0 0 0 0 0 1
reset_current
if request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >/dev/null; then
	no "a hot backup was accepted as a pre-deployment safety net"
elif current_is_existing &&
	[ "$(<"$WORK/stages.log")" = "$(printf 'validate\nbackup\n')" ] &&
	! has_staging_residue; then
	ok "a hot backup stops the deployment and preserves current"
else
	no "a hot backup stops the deployment and preserves current"
fi

# Neighbour container names are host topology, so the public bundle cannot carry
# them and the check that uses them is silent without a declaration. That makes
# the declaration part of the host contract rather than an optional extra: a
# forgotten value would restore a green verdict about neighbours nobody examined.
write_host_env 0 0
grep -v '^HERMES_NEIGHBOUR_CONTAINERS=' "$WORK/host.env" >"$WORK/host.env.stripped"
mv "$WORK/host.env.stripped" "$WORK/host.env"
chmod 0600 "$WORK/host.env"
reset_current
if request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >/dev/null; then
	no "gateway accepted a host environment declaring no neighbouring containers"
elif current_is_existing && [ ! -s "$WORK/stages.log" ]; then
	ok "gateway refuses a host environment declaring no neighbouring containers"
else
	no "gateway refuses a host environment declaring no neighbouring containers"
fi

# The repository URL used to fall back to a literal inside the gateway. That
# default is what a deleted or renamed public contour looks like from the host:
# the fallback keeps pointing at a URL that no longer resolves to the intended
# repository, and the failure surfaces as a fetch error rather than as a
# configuration one. The host must state the contour it deploys from.
write_host_env 0 0
grep -v '^HERMES_REPO_URL=' "$WORK/host.env" >"$WORK/host.env.stripped"
mv "$WORK/host.env.stripped" "$WORK/host.env"
chmod 0600 "$WORK/host.env"
reset_current
if request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >/dev/null; then
	no "gateway accepted a host environment with no repository URL"
elif current_is_existing && [ ! -s "$WORK/stages.log" ]; then
	ok "gateway refuses a host environment with no repository URL"
else
	no "gateway refuses a host environment with no repository URL"
fi

git -C "$SOURCE" reset -q --hard "$BUNDLE_SHA"
ln -s README.md "$SOURCE/unsafe-link"
git -C "$SOURCE" add unsafe-link
git -C "$SOURCE" commit -q -m "unsafe symlink"
UNSAFE_SHA="$(git -C "$SOURCE" rev-parse HEAD)"
git -C "$SOURCE" push -q --force "$ORIGIN" main:main
write_host_env 0 0
reset_current
UNSAFE_OUTPUT="$(request "HERMES_DEPLOY_V1 $UNSAFE_SHA\n")"
UNSAFE_STATUS=$?
if [ "$UNSAFE_STATUS" -eq 0 ]; then
	no "Git symlink is rejected"
elif current_is_existing && [ ! -s "$WORK/stages.log" ] &&
	! has_staging_residue; then
	case "$UNSAFE_OUTPUT" in
	*"unsafe Git mode"*) ok "Git symlink is rejected before extraction" ;;
	*) no "Git symlink is rejected for its unsafe mode" ;;
	esac
else
	no "Git symlink is rejected before extraction"
fi

git -C "$SOURCE" reset -q --hard "$BUNDLE_SHA"
printf 'unexpected\n' >"$SOURCE/unexpected"
git -C "$SOURCE" add unexpected
git -C "$SOURCE" commit -q -m "unexpected top level"
UNEXPECTED_SHA="$(git -C "$SOURCE" rev-parse HEAD)"
git -C "$SOURCE" push -q --force "$ORIGIN" main:main
reset_current
UNEXPECTED_OUTPUT="$(request "HERMES_DEPLOY_V1 $UNEXPECTED_SHA\n")"
UNEXPECTED_STATUS=$?
if [ "$UNEXPECTED_STATUS" -eq 0 ]; then
	no "unexpected top-level entry is rejected"
elif current_is_existing && [ ! -s "$WORK/stages.log" ] &&
	! has_staging_residue; then
	case "$UNEXPECTED_OUTPUT" in
	*"unexpected top-level entry"*) ok "unexpected top-level entry is rejected before extraction" ;;
	*) no "unexpected top-level entry is rejected for its layout" ;;
	esac
else
	no "unexpected top-level entry is rejected before extraction"
fi

git -C "$SOURCE" reset -q --hard "$BUNDLE_SHA"
git -C "$SOURCE" push -q --force "$ORIGIN" main:main

printf '\n== activation and rollback ==\n'
log_is() {
	[ "$(<"$WORK/stages.log")" = "$1" ]
}

failed_release() {
	find "$DEPLOY_ROOT/releases" -mindepth 1 -maxdepth 1 -type d \
		! -name existing ! -name '.staging-*' -print -quit
}

write_host_env 0 0 0 0 0 0 0
reset_current
request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >"$WORK/success.out"
SUCCESS_STATUS=$?
SUCCESS_TARGET="$(readlink "$DEPLOY_ROOT/current")"
if [ "$SUCCESS_STATUS" -eq 0 ] &&
	[ "$SUCCESS_TARGET" != "releases/existing" ] &&
	log_is "$(printf 'validate\nbackup\ndeploy\nverify')" &&
	grep -Fxq 'verdict=success' "$DEPLOY_ROOT/$SUCCESS_TARGET/.deployment-evidence"; then
	ok "successful deployment activates and verifies the new release"
else
	no "successful deployment activates and verifies the new release"
fi
if grep -Fq 'fixture.service' "$WORK/success.out"; then
	no "gateway keeps private lifecycle output off the SSH channel"
elif [ -f "$DEPLOY_ROOT/$SUCCESS_TARGET/.deployment-log" ] &&
	[ "$(file_mode "$DEPLOY_ROOT/$SUCCESS_TARGET/.deployment-log")" = "600" ] &&
	grep -Fq 'fixture.service' \
		"$DEPLOY_ROOT/$SUCCESS_TARGET/.deployment-log"; then
	ok "gateway keeps private lifecycle output off the SSH channel"
else
	no "gateway preserves private lifecycle output on the host"
fi

write_host_env 0 0 1 0 1 0 0
reset_current
request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >"$WORK/image-failure.out"
IMAGE_FAILURE_STATUS=$?
IMAGE_FAILED_RELEASE="$(failed_release)"
if [ "$IMAGE_FAILURE_STATUS" -ne 0 ] && current_is_existing &&
	log_is "$(printf 'validate\nbackup\ndeploy\nprevious-rollback\nprevious-verify')" &&
	[ -f "$IMAGE_FAILED_RELEASE/.previous-image" ] &&
	grep -Fxq 'verdict=rolled-back' "$IMAGE_FAILED_RELEASE/.deployment-evidence"; then
	ok "deploy failure restores previous bundle and image but remains failed"
else
	no "deploy failure restores previous bundle and image but remains failed"
fi

write_host_env 0 0 0 1 1 0 0
reset_current
request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >"$WORK/verify-failure.out"
VERIFY_FAILURE_STATUS=$?
VERIFY_FAILED_RELEASE="$(failed_release)"
if [ "$VERIFY_FAILURE_STATUS" -ne 0 ] && current_is_existing &&
	log_is "$(printf 'validate\nbackup\ndeploy\nverify\nprevious-rollback\nprevious-verify')" &&
	grep -Fxq 'verdict=rolled-back' "$VERIFY_FAILED_RELEASE/.deployment-evidence"; then
	ok "independent verify failure follows the image rollback path"
else
	no "independent verify failure follows the image rollback path"
fi

write_host_env 0 0 1 0 0 0 0
reset_current
request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >"$WORK/no-image.out"
NO_IMAGE_STATUS=$?
NO_IMAGE_FAILED_RELEASE="$(failed_release)"
if [ "$NO_IMAGE_STATUS" -ne 0 ] && current_is_existing &&
	log_is "$(printf 'validate\nbackup\ndeploy\nprevious-verify')" &&
	grep -Fxq 'verdict=rolled-back' "$NO_IMAGE_FAILED_RELEASE/.deployment-evidence"; then
	ok "failure without image record restores only the previous bundle"
else
	no "failure without image record restores only the previous bundle"
fi

write_host_env 0 0 1 0 1 1 0
reset_current
request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >"$WORK/rollback-failure.out"
ROLLBACK_FAILURE_STATUS=$?
ROLLBACK_FAILED_RELEASE="$(failed_release)"
if [ "$ROLLBACK_FAILURE_STATUS" -ne 0 ] && ! current_is_existing &&
	log_is "$(printf 'validate\nbackup\ndeploy\nprevious-rollback')" &&
	grep -Fxq 'verdict=rollback-failed' "$ROLLBACK_FAILED_RELEASE/.deployment-evidence"; then
	ok "rollback failure preserves failed current release and evidence"
else
	no "rollback failure preserves failed current release and evidence"
fi

write_host_env 0 0 1 0 0 0 1
reset_current
request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >"$WORK/no-image-verify.out"
NO_IMAGE_VERIFY_STATUS=$?
NO_IMAGE_VERIFY_RELEASE="$(failed_release)"
if [ "$NO_IMAGE_VERIFY_STATUS" -ne 0 ] && current_is_existing &&
	log_is "$(printf 'validate\nbackup\ndeploy\nprevious-verify')" &&
	grep -Fxq 'verdict=rollback-failed' "$NO_IMAGE_VERIFY_RELEASE/.deployment-evidence"; then
	ok "failed previous verification remains a rollback failure"
else
	no "failed previous verification remains a rollback failure"
fi

write_host_env 0 0 0 0 0 0 0
reset_current
mkdir -p "$WORK/data" "$WORK/backups"
printf 'keep\n' >"$WORK/data/sentinel"
printf 'keep\n' >"$WORK/backups/sentinel"
for release in \
	20240101T000001Z-0000001 20240101T000002Z-0000002 \
	20240101T000003Z-0000003 20240101T000004Z-0000004 \
	20240101T000005Z-0000005 20240101T000006Z-0000006; do
	mkdir "$DEPLOY_ROOT/releases/$release"
done
request "HERMES_DEPLOY_V1 $BUNDLE_SHA\n" >"$WORK/retention.out"
RETENTION_STATUS=$?
RELEASE_COUNT="$(find "$DEPLOY_ROOT/releases" -mindepth 1 -maxdepth 1 -type d \
	-name '????????T??????Z-???????' | wc -l | tr -d ' ')"
if [ "$RETENTION_STATUS" -eq 0 ] && [ "$RELEASE_COUNT" -eq 5 ] &&
	[ -f "$WORK/data/sentinel" ] && [ -f "$WORK/backups/sentinel" ]; then
	ok "success retention keeps five releases without touching state or backups"
else
	no "success retention keeps five releases without touching state or backups"
fi

printf '\n== forced deployment identity ==\n'
FORCE_ADAPTER="$SCRIPTS/ci-deploy-force.sh"
BOOTSTRAP="$SCRIPTS/bootstrap-ci-deploy.sh"
FAKE_BIN="$WORK/fake-bin"
mkdir "$FAKE_BIN"
cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$SUDO_ARGS_LOG"
cat >"$SUDO_STDIN_LOG"
EOF
chmod 0755 "$FAKE_BIN/sudo"

if [ ! -x "$FORCE_ADAPTER" ]; then
	no "forced-command adapter exists and is executable"
else
	for original in '' shell 'deploy extra' ' deploy' 'deploy '; do
		rm -f "$WORK/sudo.args" "$WORK/sudo.stdin"
		if printf 'request\n' | env \
			PATH="$FAKE_BIN:$PATH" \
			SUDO_ARGS_LOG="$WORK/sudo.args" \
			SUDO_STDIN_LOG="$WORK/sudo.stdin" \
			SSH_ORIGINAL_COMMAND="$original" \
			"$FORCE_ADAPTER" >/dev/null 2>&1; then
			no "forced command rejects '$original'"
		elif [ -e "$WORK/sudo.args" ]; then
			no "rejected forced command cannot invoke sudo"
		else
			ok "forced command rejects '$original'"
		fi
	done

	printf 'HERMES_DEPLOY_V1 %s\n' "$BUNDLE_SHA" | env \
		PATH="$FAKE_BIN:$PATH" \
		SUDO_ARGS_LOG="$WORK/sudo.args" \
		SUDO_STDIN_LOG="$WORK/sudo.stdin" \
		SSH_ORIGINAL_COMMAND=deploy \
		"$FORCE_ADAPTER" >/dev/null
	if [ "$(<"$WORK/sudo.args")" = "$(printf '%s\n%s' -n /usr/local/sbin/hermes-deploy-gateway)" ] &&
		[ "$(<"$WORK/sudo.stdin")" = "$(printf 'HERMES_DEPLOY_V1 %s' "$BUNDLE_SHA")" ]; then
		ok "exact deploy command invokes only the gateway and preserves stdin"
	else
		no "exact deploy command invokes only the gateway and preserves stdin"
	fi
fi


BOOTSTRAP_KEY="$WORK/bootstrap-key"
ssh-keygen -q -t ed25519 -N '' -C fixture -f "$BOOTSTRAP_KEY"
BOOTSTRAP_ENV="$WORK/bootstrap.env"
cat >"$BOOTSTRAP_ENV" <<EOF
HERMES_DATA_DIR='$WORK/data'
HERMES_BACKUP_DIR='$WORK/backups'
HERMES_CONTAINER='fixture'
HERMES_PROFILE='default'
HERMES_ALLOWED_DATA_ROOT='$WORK'
HERMES_NEIGHBOUR_UNITS='fixture.service'
HERMES_NEIGHBOUR_CONTAINERS='fixture-neighbour'
HERMES_REPO_URL='https://example.invalid/fixture.git'
EOF
chmod 0600 "$BOOTSTRAP_ENV"
mkdir -p "$WORK/data" "$WORK/backups"
chmod 0755 "$WORK/data" "$WORK/backups"
BOOTSTRAP_ROOT="$WORK/bootstrap-root"

if [ ! -x "$BOOTSTRAP" ]; then
	no "CI deploy bootstrap exists and is executable"
else
	if env HERMES_BOOTSTRAP_TESTING=1 HERMES_BOOTSTRAP_ROOT="$BOOTSTRAP_ROOT" \
		"$BOOTSTRAP" --public-key-file "$BOOTSTRAP_KEY.pub" \
		--host-env-file "$BOOTSTRAP_ENV" >/dev/null; then
		INSTALLED_GATEWAY="$BOOTSTRAP_ROOT/usr/local/sbin/hermes-deploy-gateway"
		INSTALLED_ADAPTER="$BOOTSTRAP_ROOT/usr/local/libexec/hermes-deploy-force"
		INSTALLED_ENV="$BOOTSTRAP_ROOT/etc/hermes-deploy/env"
		INSTALLED_SUDOERS="$BOOTSTRAP_ROOT/etc/sudoers.d/hermes-deploy"
		INSTALLED_KEYS="$BOOTSTRAP_ROOT/home/hermes-deploy/.ssh/authorized_keys"
		EXPECTED_KEY="restrict,command=\"/usr/local/libexec/hermes-deploy-force\" $(<"$BOOTSTRAP_KEY.pub")"
		if cmp -s "$SCRIPTS/ci-deploy-gateway.sh" "$INSTALLED_GATEWAY" &&
			cmp -s "$FORCE_ADAPTER" "$INSTALLED_ADAPTER" &&
			cmp -s "$BOOTSTRAP_ENV" "$INSTALLED_ENV" &&
			[ "$(<"$INSTALLED_SUDOERS")" = 'hermes-deploy ALL=(root) NOPASSWD: /usr/local/sbin/hermes-deploy-gateway ""' ] &&
			[ "$(<"$INSTALLED_KEYS")" = "$EXPECTED_KEY" ] &&
			[ "$(file_mode "$INSTALLED_GATEWAY")" = "755" ] &&
			[ "$(file_mode "$INSTALLED_ADAPTER")" = "755" ] &&
			[ "$(file_mode "$INSTALLED_ENV")" = "600" ] &&
			[ "$(file_mode "$INSTALLED_KEYS")" = "600" ]; then
			ok "bootstrap installs exact least-privilege control-plane files"
		else
			no "bootstrap installs exact least-privilege control-plane files"
		fi
	else
		no "bootstrap installs a valid fixture"
	fi
	if [ "$(file_mode "$WORK/data")" = "700" ] &&
		[ "$(file_mode "$WORK/backups")" = "700" ]; then
		ok "bootstrap restricts state roots"
	else
		no "bootstrap restricts state roots"
	fi

	if env HERMES_BOOTSTRAP_TESTING=1 HERMES_BOOTSTRAP_ROOT="$BOOTSTRAP_ROOT" \
		"$BOOTSTRAP" --public-key-file "$BOOTSTRAP_KEY.pub" \
		--host-env-file "$BOOTSTRAP_ENV" >/dev/null &&
		cmp -s "$SCRIPTS/ci-deploy-gateway.sh" \
			"$BOOTSTRAP_ROOT/usr/local/sbin/hermes-deploy-gateway"; then
		ok "bootstrap rerun is idempotent"
	else
		no "bootstrap rerun is idempotent"
	fi

	printf 'not-a-key\n' >"$WORK/invalid.pub"
	if env HERMES_BOOTSTRAP_TESTING=1 \
		HERMES_BOOTSTRAP_ROOT="$WORK/invalid-key-root" \
		"$BOOTSTRAP" --public-key-file "$WORK/invalid.pub" \
		--host-env-file "$BOOTSTRAP_ENV" >/dev/null 2>&1; then
		no "bootstrap rejects an invalid public key"
	elif [ -e "$WORK/invalid-key-root/usr/local/sbin/hermes-deploy-gateway" ]; then
		no "invalid public key is rejected before installation"
	else
		ok "invalid public key is rejected before installation"
	fi

	cp "$BOOTSTRAP_ENV" "$WORK/writable.env"
	chmod 0666 "$WORK/writable.env"
	if env HERMES_BOOTSTRAP_TESTING=1 \
		HERMES_BOOTSTRAP_ROOT="$WORK/writable-env-root" \
		"$BOOTSTRAP" --public-key-file "$BOOTSTRAP_KEY.pub" \
		--host-env-file "$WORK/writable.env" >/dev/null 2>&1; then
		no "bootstrap rejects a writable host environment"
	elif [ -e "$WORK/writable-env-root/usr/local/sbin/hermes-deploy-gateway" ]; then
		no "writable host environment is rejected before installation"
	else
		ok "writable host environment is rejected before installation"
	fi

	grep -v '^HERMES_NEIGHBOUR_CONTAINERS=' "$BOOTSTRAP_ENV" >"$WORK/no-containers.env"
	chmod 0600 "$WORK/no-containers.env"
	if env HERMES_BOOTSTRAP_TESTING=1 \
		HERMES_BOOTSTRAP_ROOT="$WORK/no-containers-root" \
		"$BOOTSTRAP" --public-key-file "$BOOTSTRAP_KEY.pub" \
		--host-env-file "$WORK/no-containers.env" >/dev/null 2>&1; then
		no "bootstrap accepted a host environment declaring no neighbouring containers"
	elif [ -e "$WORK/no-containers-root/usr/local/sbin/hermes-deploy-gateway" ]; then
		no "an incomplete host environment is rejected before installation"
	else
		ok "an incomplete host environment is rejected before installation"
	fi

	if env HERMES_BOOTSTRAP_TESTING=1 \
		HERMES_BOOTSTRAP_ROOT="$WORK/unexpected-arg-root" \
		"$BOOTSTRAP" --public-key-file "$BOOTSTRAP_KEY.pub" \
		--host-env-file "$BOOTSTRAP_ENV" extra >/dev/null 2>&1; then
		no "bootstrap rejects unexpected arguments"
	elif [ -e "$WORK/unexpected-arg-root/usr/local/sbin/hermes-deploy-gateway" ]; then
		no "unexpected arguments are rejected before installation"
	else
		ok "unexpected arguments are rejected before installation"
	fi
fi

printf '\n== gateway lock ==\n'
if command -v flock >/dev/null 2>&1; then
	write_host_env 0 0
	printf "HERMES_FIXTURE_VALIDATE_DELAY='2'\n" >>"$WORK/host.env"
	reset_current
	request_with_real_lock() {
		printf 'HERMES_DEPLOY_V1 %s\n' "$BUNDLE_SHA" | env \
			HERMES_DEPLOY_ROOT="$DEPLOY_ROOT" \
			HERMES_FLOCK_BIN=flock \
			HERMES_DEPLOY_TESTING=1 \
			HERMES_HOST_ENV="$WORK/host.env" \
			HERMES_LOCK_FILE="$WORK/deploy.lock" \
			"$SCRIPTS/ci-deploy-gateway.sh" 2>&1
	}
	request_with_real_lock >"$WORK/first-lock.out" &
	FIRST_GATEWAY_PID=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$WORK/stages.log" ] && break
		sleep 0.1
	done
	SECOND_LOCK_OUTPUT="$(request_with_real_lock)"
	SECOND_LOCK_STATUS=$?
	wait "$FIRST_GATEWAY_PID" || true
	if [ "$SECOND_LOCK_STATUS" -ne 0 ]; then
		case "$SECOND_LOCK_OUTPUT" in
		*"another Hermes deployment is active"*) ok "concurrent gateway request is rejected" ;;
		*) no "concurrent gateway request reports the lock conflict" ;;
		esac
	else
		no "concurrent gateway request is rejected"
	fi
else
	skip "concurrent gateway request: flock is unavailable locally"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
