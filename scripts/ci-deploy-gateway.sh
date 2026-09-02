#!/usr/bin/env bash
# Root-owned deployment gateway for the forced-command CI identity.
set -euo pipefail

DEPLOY_ROOT="${HERMES_DEPLOY_ROOT:-/opt/hermes/deploy}"
# The contour this host deploys from is a host decision, read from the validated
# host environment below. It used to carry a literal fallback, which is exactly
# what a deleted or renamed public repository looks like from here: the default
# kept pointing somewhere plausible, and the failure appeared as a fetch error
# instead of a configuration one.
REPO_URL=
MIRROR="${HERMES_REPO_MIRROR:-$DEPLOY_ROOT/repository.git}"
LOCK_FILE="${HERMES_LOCK_FILE:-/run/lock/hermes-deploy.lock}"
FLOCK_BIN="${HERMES_FLOCK_BIN:-flock}"
HOST_ENV="${HERMES_HOST_ENV:-/etc/hermes-deploy/env}"
TESTING="${HERMES_DEPLOY_TESTING:-0}"
RELEASE_KEEP="${HERMES_RELEASE_KEEP:-5}"
STAGING=
ARCHIVE=
TREE_LIST=
RELEASE_NAME=
FINAL_RELEASE=
BACKUP_BASENAME=
BACKUP_CHECKSUM=
LIFECYCLE_LOG=

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
	rm -f -- "$ARCHIVE" "$TREE_LIST"
	if [ -n "$STAGING" ]; then
		case "$STAGING" in
		"$DEPLOY_ROOT/releases/.staging-"*) rm -rf -- "$STAGING" ;;
		*) printf 'error: refusing to clean unexpected staging path\n' >&2 ;;
		esac
	fi
}

trap cleanup EXIT

case "$TESTING" in
0) ;;
1)
	case "$DEPLOY_ROOT" in
	/ | /opt/hermes/deploy) die "testing mode requires an isolated deployment root" ;;
	esac
	;;
*) die "invalid HERMES_DEPLOY_TESTING value" ;;
esac

case "$RELEASE_KEEP" in
'' | *[!0-9]*) die "release retention must be numeric" ;;
esac
[ "$RELEASE_KEEP" -ge 2 ] || die "release retention must be at least two"

[ "$#" -eq 0 ] || die "gateway does not accept arguments"

read_request() {
	local marker sha extra
	IFS=' ' read -r marker sha extra || die "missing deployment request"
	[ "$marker" = "HERMES_DEPLOY_V1" ] || die "unsupported deployment protocol"
	[ -z "${extra:-}" ] || die "deployment request has extra fields"
	case "$sha" in
	'' | *[!0123456789abcdef]*) die "deployment sha is not lowercase hexadecimal" ;;
	esac
	[ "${#sha}" -eq 40 ] || die "deployment sha must contain 40 characters"
	extra=
	if IFS= read -r extra || [ -n "$extra" ]; then
		die "deployment request has trailing payload"
	fi
	printf '%s\n' "$sha"
}

acquire_lock() {
	command -v "$FLOCK_BIN" >/dev/null 2>&1 || die "flock is unavailable"
	mkdir -p "$(dirname "$LOCK_FILE")"
	exec 9>"$LOCK_FILE"
	"$FLOCK_BIN" -n 9 || die "another Hermes deployment is active"
}

fetch_current_main() {
	local requested="$1" current
	mkdir -p "$DEPLOY_ROOT"
	if [ -e "$MIRROR" ] && [ ! -d "$MIRROR" ]; then
		die "repository mirror path is not a directory"
	fi
	if [ ! -d "$MIRROR" ]; then
		git init --bare -q "$MIRROR"
		git --git-dir="$MIRROR" remote add origin "$REPO_URL"
	fi
	[ "$(git --git-dir="$MIRROR" rev-parse --is-bare-repository)" = "true" ] ||
		die "repository mirror is not bare"
	git --git-dir="$MIRROR" remote set-url origin "$REPO_URL"
	git --git-dir="$MIRROR" fetch --force --prune --no-tags origin \
		'+refs/heads/main:refs/remotes/origin/main' >/dev/null
	current="$(git --git-dir="$MIRROR" rev-parse --verify 'refs/remotes/origin/main^{commit}')"
	[ "$requested" = "$current" ] || die "requested sha is not current origin/main"
	printf '%s\n' "$current"
}

validate_tree() {
	local sha="$1" entry meta path mode type top
	TREE_LIST="$DEPLOY_ROOT/.tree.$$"
	git --git-dir="$MIRROR" ls-tree -rz --full-tree -r "$sha" >"$TREE_LIST" ||
		die "cannot inspect release tree"
	while IFS= read -r -d '' entry; do
		meta="${entry%%$'\t'*}"
		path="${entry#*$'\t'}"
		mode="${meta%% *}"
		type="${meta#* }"
		type="${type%% *}"
		[ "$type" = "blob" ] || die "release contains a non-blob Git entry"
		case "$mode" in
		100644 | 100755) ;;
		*) die "release contains unsafe Git mode $mode" ;;
		esac
		case "/$path/" in
		*'/../'*) die "release contains parent traversal" ;;
		esac
		case "$path" in
		/*) die "release contains an absolute path" ;;
		esac
		top="${path%%/*}"
		case "$top" in
		.env.example | .github | .gitignore | LICENSE | README.md | compose.yaml | config | docs | scripts | tests) ;;
		*) die "release contains an unexpected top-level entry" ;;
		esac
	done <"$TREE_LIST"
	rm -f -- "$TREE_LIST"
	TREE_LIST=
}

stage_release() {
	local sha="$1" short timestamp unsafe hardlinked script
	short="${sha:0:7}"
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	RELEASE_NAME="$timestamp-$short"
	mkdir -p "$DEPLOY_ROOT/releases"
	[ ! -e "$DEPLOY_ROOT/releases/$RELEASE_NAME" ] ||
		die "release directory already exists"
	STAGING="$DEPLOY_ROOT/releases/.staging-$RELEASE_NAME-$$"
	mkdir "$STAGING"
	ARCHIVE="$DEPLOY_ROOT/.release-$RELEASE_NAME-$$.tar"

	validate_tree "$sha"
	git --git-dir="$MIRROR" archive --format=tar --output="$ARCHIVE" "$sha"
	tar -xf "$ARCHIVE" -C "$STAGING" --no-same-owner --no-same-permissions
	rm -f -- "$ARCHIVE"
	ARCHIVE=

	unsafe="$(find "$STAGING" ! -type d ! -type f -print -quit)"
	[ -z "$unsafe" ] || die "release extraction produced an unsafe object"
	hardlinked="$(find "$STAGING" -type f -links +1 -print -quit)"
	[ -z "$hardlinked" ] || die "release extraction produced a hard-linked file"
	for script in validate backup deploy verify rollback; do
		[ -x "$STAGING/scripts/$script.sh" ] ||
			die "release is missing executable lifecycle scripts"
	done
}

load_host_env() {
	local stat_output owner mode expected_owner permissions variable value
	[ -f "$HOST_ENV" ] && [ ! -L "$HOST_ENV" ] ||
		die "host environment is not a regular file"
	if stat_output="$(stat -c '%u %a' "$HOST_ENV" 2>/dev/null)"; then
		:
	elif stat_output="$(stat -f '%u %Lp' "$HOST_ENV" 2>/dev/null)"; then
		:
	else
		die "cannot inspect host environment ownership"
	fi
	owner="${stat_output%% *}"
	mode="${stat_output#* }"
	expected_owner=0
	if [ "$TESTING" = "1" ]; then
		expected_owner="$(id -u)"
	fi
	[ "$owner" = "$expected_owner" ] || die "host environment has the wrong owner"
	permissions=$((8#$mode))
	[ $((permissions & 022)) -eq 0 ] ||
		die "host environment is group or other writable"

	set -a
	# The production path is fixed and root-owned; tests inject a checked fixture.
	# shellcheck disable=SC1090
	. "$HOST_ENV"
	set +a
	for variable in HERMES_DATA_DIR HERMES_BACKUP_DIR HERMES_CONTAINER \
		HERMES_PROFILE HERMES_ALLOWED_DATA_ROOT HERMES_NEIGHBOUR_UNITS \
		HERMES_NEIGHBOUR_CONTAINERS HERMES_REPO_URL; do
		value="${!variable-}"
		[ -n "$value" ] || die "host environment is missing $variable"
	done
	REPO_URL="$HERMES_REPO_URL"
}

run_pre_activation() {
	local sha="$1" backup_archive backup_dir expected_backup_dir base
	local checksum checksum_name checksum_extra evidence
	LIFECYCLE_LOG="$STAGING/.deployment-log"
	(umask 077 && : >"$LIFECYCLE_LOG") ||
		die "cannot create private lifecycle log"
	if ! "$STAGING/scripts/validate.sh" >>"$LIFECYCLE_LOG" 2>&1; then
		die "staged validation failed"
	fi
	if ! backup_archive="$("$STAGING/scripts/backup.sh" 2>>"$LIFECYCLE_LOG")"; then
		die "pre-deployment backup failed"
	fi
	[ -f "$backup_archive" ] && [ ! -L "$backup_archive" ] ||
		die "backup script did not return a regular archive"
	[ -f "$backup_archive.sha256" ] && [ ! -L "$backup_archive.sha256" ] ||
		die "backup checksum is missing"
	# A marked archive is a copy taken while the gateway could not be proven
	# stopped. The backup script still produces one deliberately in an emergency,
	# but accepting it here would restore the false confidence the marker exists
	# to remove: the deployment would proceed believing it has a safety net.
	[ ! -e "$backup_archive.hot" ] ||
		die "pre-deployment backup is marked hot: the gateway was not proven stopped, refusing to deploy"
	backup_dir="$(cd "$(dirname "$backup_archive")" && pwd -P)"
	[ -d "$HERMES_BACKUP_DIR" ] || die "configured backup directory is missing"
	expected_backup_dir="$(cd "$HERMES_BACKUP_DIR" && pwd -P)"
	[ "$backup_dir" = "$expected_backup_dir" ] ||
		die "backup is outside configured backup directory"
	base="$(basename "$backup_archive")"
	IFS=' ' read -r checksum checksum_name checksum_extra <"$backup_archive.sha256" ||
		die "cannot read backup checksum"
	case "$checksum" in
	'' | *[!0123456789abcdef]*) die "backup checksum is not lowercase hexadecimal" ;;
	esac
	[ "${#checksum}" -eq 64 ] || die "backup checksum has the wrong length"
	[ "$checksum_name" = "$base" ] && [ -z "${checksum_extra:-}" ] ||
		die "backup checksum names an unexpected file"
	(
		cd "$backup_dir"
		if command -v shasum >/dev/null 2>&1; then
			shasum -a 256 -c "$base.sha256" >/dev/null
		else
			sha256sum -c --strict "$base.sha256" >/dev/null
		fi
	) >>"$LIFECYCLE_LOG" 2>&1 || die "backup checksum verification failed"
	BACKUP_BASENAME="$base"
	BACKUP_CHECKSUM="$checksum"

	evidence="$STAGING/.deployment-evidence"
	umask 077
	{
		printf 'commit=%s\n' "$sha"
		printf 'release=%s\n' "$RELEASE_NAME"
		printf 'stages=validate,backup\n'
		printf 'backup=%s\n' "$base"
		printf 'checksum=%s\n' "$checksum"
		printf 'verdict=pending\n'
	} >"$evidence"
}

validate_current() {
	local target relative releases_root resolved
	[ -L "$DEPLOY_ROOT/current" ] || die "current is not a symlink"
	target="$(readlink "$DEPLOY_ROOT/current")"
	case "$target" in
	releases/*) ;;
	*) die "current target is outside releases" ;;
	esac
	relative="${target#releases/}"
	case "$relative" in
	'' | */*) die "current must target one direct release directory" ;;
	esac
	[ -d "$DEPLOY_ROOT/$target" ] || die "current release directory is missing"
	releases_root="$(cd "$DEPLOY_ROOT/releases" && pwd -P)"
	resolved="$(cd "$DEPLOY_ROOT/$target" && pwd -P)"
	case "$resolved" in
	"$releases_root"/*) ;;
	*) die "current resolves outside releases" ;;
	esac
	[ -x "$resolved/scripts/rollback.sh" ] ||
		die "current release has no rollback script"
	[ -x "$resolved/scripts/verify.sh" ] ||
		die "current release has no verify script"
	printf '%s\n' "$target"
}

finalize_release() {
	FINAL_RELEASE="$DEPLOY_ROOT/releases/$RELEASE_NAME"
	[ ! -e "$FINAL_RELEASE" ] || die "final release already exists"
	mv "$STAGING" "$FINAL_RELEASE"
	STAGING=
	LIFECYCLE_LOG="$FINAL_RELEASE/.deployment-log"
}

switch_current() {
	local target="$1" link="$DEPLOY_ROOT/.current.$$"
	case "$target" in
	releases/*) ;;
	*) die "refusing a current target outside releases" ;;
	esac
	rm -f -- "$link"
	ln -s "$target" "$link"
	case "$(uname -s)" in
	Linux)
		if ! mv -Tf "$link" "$DEPLOY_ROOT/current"; then
			rm -f -- "$link"
			die "cannot atomically switch current"
		fi
		;;
	Darwin)
		if ! mv -fh "$link" "$DEPLOY_ROOT/current"; then
			rm -f -- "$link"
			die "cannot atomically switch current"
		fi
		;;
	*)
		rm -f -- "$link"
		die "unsupported platform for atomic symlink replacement"
		;;
	esac
}

update_evidence() {
	local release="$1" stages="$2" verdict="$3"
	local evidence="$release/.deployment-evidence" temporary line
	[ -f "$evidence" ] || die "deployment evidence is missing"
	temporary="$release/.deployment-evidence.$$"
	umask 077
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		stages=*) printf 'stages=%s\n' "$stages" ;;
		verdict=*) printf 'verdict=%s\n' "$verdict" ;;
		*) printf '%s\n' "$line" ;;
		esac
	done <"$evidence" >"$temporary"
	mv -f "$temporary" "$evidence"
	chmod 0600 "$evidence"
}

emit_evidence() {
	local sha="$1" verdict="$2"
	printf 'commit: %s\n' "$sha" >&2
	printf 'release: %s\n' "$RELEASE_NAME" >&2
	printf 'backup: %s\n' "$BACKUP_BASENAME" >&2
	printf 'checksum: %s\n' "$BACKUP_CHECKSUM" >&2
	printf 'verdict: %s\n' "$verdict" >&2
}

recover_previous_release() {
	local old_target="$1" stages="$2"
	local old_release="$DEPLOY_ROOT/$old_target"
	local image_record="$FINAL_RELEASE/.previous-image"
	if [ -s "$image_record" ]; then
		if ! HERMES_PREVIOUS_IMAGE_FILE="$image_record" \
			"$old_release/scripts/rollback.sh" >>"$LIFECYCLE_LOG" 2>&1; then
			update_evidence "$FINAL_RELEASE" "$stages,rollback-failed" "rollback-failed"
			return 1
		fi
		switch_current "$old_target"
		if ! "$old_release/scripts/verify.sh" >>"$LIFECYCLE_LOG" 2>&1; then
			update_evidence "$FINAL_RELEASE" "$stages,rollback,previous-verify-failed" "rollback-failed"
			return 1
		fi
		update_evidence "$FINAL_RELEASE" "$stages,rollback,previous-verify" "rolled-back"
		return 0
	fi

	switch_current "$old_target"
	if ! "$old_release/scripts/verify.sh" >>"$LIFECYCLE_LOG" 2>&1; then
		update_evidence "$FINAL_RELEASE" "$stages,bundle-restore,previous-verify-failed" "rollback-failed"
		return 1
	fi
	update_evidence "$FINAL_RELEASE" "$stages,bundle-restore,previous-verify" "rolled-back"
	return 0
}

prune_releases() {
	local kept=1 release
	while IFS= read -r release; do
		[ "$release" = "$FINAL_RELEASE" ] && continue
		if [ "$kept" -lt "$RELEASE_KEEP" ]; then
			kept=$((kept + 1))
			continue
		fi
		rm -rf -- "$release"
	done < <(
		find "$DEPLOY_ROOT/releases" -mindepth 1 -maxdepth 1 -type d \
			-name '????????T??????Z-???????' -print | sort -r
	)
}

main() {
	local requested current old_target stages
	requested="$(read_request)"
	acquire_lock
	# The host environment is validated before anything reaches the network: it
	# names the contour to fetch from, and a misconfigured host should fail as a
	# configuration error rather than as a fetch error against whatever default
	# happened to be compiled in.
	load_host_env
	current="$(fetch_current_main "$requested")"
	stage_release "$current"
	run_pre_activation "$current"
	old_target="$(validate_current)"
	finalize_release
	switch_current "releases/$RELEASE_NAME"

	stages="validate,backup,deploy"
	if ! "$FINAL_RELEASE/scripts/deploy.sh" >>"$LIFECYCLE_LOG" 2>&1; then
		if recover_previous_release "$old_target" "$stages-failed"; then
			emit_evidence "$current" "rolled-back"
			die "deployment failed; previous release restored"
		fi
		emit_evidence "$current" "rollback-failed"
		die "deployment and automatic rollback failed; manual recovery required"
	fi

	stages="$stages,verify"
	if ! "$FINAL_RELEASE/scripts/verify.sh" >>"$LIFECYCLE_LOG" 2>&1; then
		if recover_previous_release "$old_target" "$stages-failed"; then
			emit_evidence "$current" "rolled-back"
			die "deployment verification failed; previous release restored"
		fi
		emit_evidence "$current" "rollback-failed"
		die "deployment verification and automatic rollback failed; manual recovery required"
	fi

	update_evidence "$FINAL_RELEASE" "$stages" "success"
	prune_releases
	emit_evidence "$current" "success"
}

main
