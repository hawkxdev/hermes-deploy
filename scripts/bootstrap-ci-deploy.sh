#!/usr/bin/env bash
# Install the locked CI deployment identity and its root-owned control plane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING="${HERMES_BOOTSTRAP_TESTING:-0}"
ROOT_PREFIX=
PUBLIC_KEY_FILE=
HOST_ENV_FILE=
DEPLOY_USER=hermes-deploy
DEPLOY_HOME=/home/hermes-deploy

usage() {
	printf 'usage: %s --public-key-file PATH --host-env-file PATH\n' "$0" >&2
	exit 64
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--public-key-file)
		[ "$#" -ge 2 ] && [ -z "$PUBLIC_KEY_FILE" ] || usage
		PUBLIC_KEY_FILE="$2"
		shift 2
		;;
	--host-env-file)
		[ "$#" -ge 2 ] && [ -z "$HOST_ENV_FILE" ] || usage
		HOST_ENV_FILE="$2"
		shift 2
		;;
	*) usage ;;
	esac
done

[ -n "$PUBLIC_KEY_FILE" ] && [ -n "$HOST_ENV_FILE" ] || usage
case "$TESTING" in
0)
	[ "$(id -u)" -eq 0 ] || die "production bootstrap requires root"
	;;
1)
	ROOT_PREFIX="${HERMES_BOOTSTRAP_ROOT:-}"
	[ -n "$ROOT_PREFIX" ] && [ "$ROOT_PREFIX" != "/" ] ||
		die "testing mode requires an isolated root"
	ROOT_PREFIX="${ROOT_PREFIX%/}"
	;;
*) die "invalid HERMES_BOOTSTRAP_TESTING value" ;;
esac

root_path() {
	printf '%s%s\n' "$ROOT_PREFIX" "$1"
}

file_identity() {
	if stat -c '%u %a' "$1" >/dev/null 2>&1; then
		stat -c '%u %a' "$1"
	else
		stat -f '%u %Lp' "$1"
	fi
}

validate_inputs() {
	local identity owner mode permissions expected_owner
	local key_type key_data key_comment extra variable value
	[ -f "$PUBLIC_KEY_FILE" ] && [ ! -L "$PUBLIC_KEY_FILE" ] ||
		die "public key is not a regular file"
	IFS=' ' read -r key_type key_data key_comment <"$PUBLIC_KEY_FILE" ||
		die "cannot read public key"
	[ "$key_type" = "ssh-ed25519" ] && [ -n "$key_data" ] ||
		die "public key must be ssh-ed25519"
	extra="$(sed -n '2p' "$PUBLIC_KEY_FILE")"
	[ -z "$extra" ] || die "public key file contains multiple lines"
	ssh-keygen -l -f "$PUBLIC_KEY_FILE" >/dev/null 2>&1 ||
		die "public key is invalid"
	: "${key_comment:=}"

	[ -f "$HOST_ENV_FILE" ] && [ ! -L "$HOST_ENV_FILE" ] ||
		die "host environment is not a regular file"
	identity="$(file_identity "$HOST_ENV_FILE")" ||
		die "cannot inspect host environment"
	owner="${identity%% *}"
	mode="${identity#* }"
	expected_owner=0
	if [ "$TESTING" = "1" ]; then
		expected_owner="$(id -u)"
	fi
	[ "$owner" = "$expected_owner" ] || die "host environment has the wrong owner"
	permissions=$((8#$mode))
	[ $((permissions & 022)) -eq 0 ] ||
		die "host environment is group or other writable"
	bash -n "$HOST_ENV_FILE" || die "host environment has invalid shell syntax"
	(
		set -a
		# shellcheck disable=SC1090
		. "$HOST_ENV_FILE"
		set +a
		for variable in HERMES_DATA_DIR HERMES_BACKUP_DIR HERMES_CONTAINER \
			HERMES_PROFILE HERMES_ALLOWED_DATA_ROOT HERMES_NEIGHBOUR_UNITS \
			HERMES_NEIGHBOUR_CONTAINERS HERMES_REPO_URL; do
			value="${!variable-}"
			[ -n "$value" ] || exit 1
		done
	) || die "host environment is missing a required value"

	[ -f "$SCRIPT_DIR/ci-deploy-gateway.sh" ] &&
		[ -x "$SCRIPT_DIR/ci-deploy-gateway.sh" ] &&
		[ ! -L "$SCRIPT_DIR/ci-deploy-gateway.sh" ] ||
		die "gateway source is unavailable"
	[ -f "$SCRIPT_DIR/ci-deploy-force.sh" ] &&
		[ -x "$SCRIPT_DIR/ci-deploy-force.sh" ] &&
		[ ! -L "$SCRIPT_DIR/ci-deploy-force.sh" ] ||
		die "forced-command source is unavailable"
}

install_account() {
	local passwd_entry account_home account_shell deploy_group groups
	if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
		useradd --system --create-home --home-dir "$DEPLOY_HOME" \
			--shell /bin/bash "$DEPLOY_USER"
	fi
	passwd -l "$DEPLOY_USER" >/dev/null
	passwd_entry="$(getent passwd "$DEPLOY_USER")"
	IFS=: read -r _ _ _ _ _ account_home account_shell <<<"$passwd_entry"
	[ "$account_home" = "$DEPLOY_HOME" ] || die "deploy user has an unexpected home"
	[ "$account_shell" = "/bin/bash" ] || die "deploy user has an unexpected shell"
	groups="$(id -nG "$DEPLOY_USER")"
	case " $groups " in
	*' docker '*) gpasswd -d "$DEPLOY_USER" docker >/dev/null ;;
	esac
	deploy_group="$(id -gn "$DEPLOY_USER")"
	install -d -m 0755 -o "$DEPLOY_USER" -g "$deploy_group" "$DEPLOY_HOME"
	install -d -m 0700 -o "$DEPLOY_USER" -g "$deploy_group" "$DEPLOY_HOME/.ssh"
}
harden_state_roots() {
	local variable path
	set -a
	# shellcheck disable=SC1090
	. "$HOST_ENV_FILE"
	set +a

	for variable in HERMES_DATA_DIR HERMES_BACKUP_DIR; do
		path="${!variable}"
		case "$path" in
	/*) ;;
	*) die "$variable must be an absolute path" ;;
		esac
		[ -d "$path" ] && [ ! -L "$path" ] ||
			die "$variable is not a regular directory"
	done

	if [ "$TESTING" = "0" ]; then
		chown root:root "$HERMES_BACKUP_DIR"
	fi
	chmod 0700 "$HERMES_DATA_DIR" "$HERMES_BACKUP_DIR"
}


install_control_plane() {
	local sbin libexec etc_dir sudoers_dir ssh_dir
	local gateway adapter installed_env sudoers keys sudoers_tmp keys_tmp
	local public_key deploy_group
	sbin="$(root_path /usr/local/sbin)"
	libexec="$(root_path /usr/local/libexec)"
	etc_dir="$(root_path /etc/hermes-deploy)"
	sudoers_dir="$(root_path /etc/sudoers.d)"
	ssh_dir="$(root_path "$DEPLOY_HOME/.ssh")"
	gateway="$sbin/hermes-deploy-gateway"
	adapter="$libexec/hermes-deploy-force"
	installed_env="$etc_dir/env"
	sudoers="$sudoers_dir/hermes-deploy"
	keys="$ssh_dir/authorized_keys"

	if [ "$TESTING" = "1" ]; then
		install -d -m 0755 "$sbin" "$libexec" "$etc_dir" "$sudoers_dir"
		install -d -m 0755 "$(root_path "$DEPLOY_HOME")"
		install -d -m 0700 "$ssh_dir"
		install -m 0755 "$SCRIPT_DIR/ci-deploy-gateway.sh" "$gateway"
		install -m 0755 "$SCRIPT_DIR/ci-deploy-force.sh" "$adapter"
		install -m 0600 "$HOST_ENV_FILE" "$installed_env"
	else
		install -d -m 0755 -o root -g root "$sbin" "$libexec" "$etc_dir" "$sudoers_dir"
		install -m 0755 -o root -g root "$SCRIPT_DIR/ci-deploy-gateway.sh" "$gateway"
		install -m 0755 -o root -g root "$SCRIPT_DIR/ci-deploy-force.sh" "$adapter"
		install -m 0600 -o root -g root "$HOST_ENV_FILE" "$installed_env"
	fi

	sudoers_tmp="$sudoers.tmp.$$"
	printf '%s\n' \
		'hermes-deploy ALL=(root) NOPASSWD: /usr/local/sbin/hermes-deploy-gateway ""' \
		>"$sudoers_tmp"
	chmod 0440 "$sudoers_tmp"
	if [ "$TESTING" = "0" ]; then
		chown root:root "$sudoers_tmp"
		visudo -cf "$sudoers_tmp" >/dev/null || die "generated sudoers rule is invalid"
	fi
	mv -f "$sudoers_tmp" "$sudoers"

	public_key="$(cat "$PUBLIC_KEY_FILE")"
	keys_tmp="$keys.tmp.$$"
	printf 'restrict,command="/usr/local/libexec/hermes-deploy-force" %s\n' \
		"$public_key" >"$keys_tmp"
	chmod 0600 "$keys_tmp"
	if [ "$TESTING" = "0" ]; then
		deploy_group="$(id -gn "$DEPLOY_USER")"
		chown "$DEPLOY_USER:$deploy_group" "$keys_tmp"
	fi
	mv -f "$keys_tmp" "$keys"
}

validate_inputs
if [ "$TESTING" = "0" ]; then
	install_account
fi
harden_state_roots
install_control_plane
