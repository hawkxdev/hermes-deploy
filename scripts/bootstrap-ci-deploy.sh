#!/usr/bin/env bash
# Install the locked CI deployment identity and its root-owned control plane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING="${HERMES_BOOTSTRAP_TESTING:-0}"
ROOT_PREFIX=
PUBLIC_KEY_FILE=
HOST_ENV_FILE=
INSTANCE_NAME=
MAX_INSTANCE_NAME_LENGTH=25
CONTROL_NAME=
DEPLOY_USER=
DEPLOY_HOME=
GATEWAY_WRAPPER_PATH=
GATEWAY_CORE_PATH=
FORCE_ADAPTER_PATH=
HOST_ENV_PATH=
LOCK_FILE_PATH=
DEPLOY_ROOT_PATH=
REPO_MIRROR_PATH=

usage() {
	printf 'usage: %s [--instance-name NAME] --public-key-file PATH --host-env-file PATH\n' "$0" >&2
	exit 64
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--instance-name)
		[ "$#" -ge 2 ] && [ -z "$INSTANCE_NAME" ] || usage
		INSTANCE_NAME="$2"
		shift 2
		;;
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
INSTANCE_NAME="${INSTANCE_NAME:-hermes}"

configure_instance_identity() {
	case "$INSTANCE_NAME" in
	'' | *[!a-z0-9-]* | -* | *- | *--*) die "invalid instance name" ;;
	esac
	case "$INSTANCE_NAME" in
	[a-z]*) ;;
	*) die "invalid instance name" ;;
	esac
	[ "${#INSTANCE_NAME}" -le "$MAX_INSTANCE_NAME_LENGTH" ] ||
		die "invalid instance name"

	CONTROL_NAME="${INSTANCE_NAME}-deploy"
	DEPLOY_USER="$CONTROL_NAME"
	DEPLOY_HOME="/home/$CONTROL_NAME"
	GATEWAY_WRAPPER_PATH="/usr/local/sbin/${CONTROL_NAME}-gateway"
	GATEWAY_CORE_PATH="/usr/local/libexec/${CONTROL_NAME}-gateway-core"
	FORCE_ADAPTER_PATH="/usr/local/libexec/${CONTROL_NAME}-force"
	HOST_ENV_PATH="/etc/${CONTROL_NAME}/env"
	LOCK_FILE_PATH="/run/lock/${CONTROL_NAME}.lock"
	DEPLOY_ROOT_PATH="/opt/${INSTANCE_NAME}/deploy"
	REPO_MIRROR_PATH="${DEPLOY_ROOT_PATH}/repository.git"
}

configure_instance_identity
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
	local identity owner mode permissions expected_owner env_status
	local key_type key_data key_comment extra variable value project container
	local expected_instance="$INSTANCE_NAME"
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
	if (
		readonly expected_instance
		set -a
		# shellcheck disable=SC1090
		. "$HOST_ENV_FILE"
		set +a
		for variable in HERMES_DATA_DIR HERMES_BACKUP_DIR HERMES_CONTAINER \
			HERMES_PROFILE HERMES_ALLOWED_DATA_ROOT HERMES_NEIGHBOUR_UNITS \
			HERMES_NEIGHBOUR_CONTAINERS HERMES_REPO_URL; do
			value="${!variable-}"
			[ -n "$value" ] || exit 20
		done
		project="${HERMES_PROJECT:-hermes}"
		container="${HERMES_CONTAINER:-hermes}"
		[ "$project" = "$expected_instance" ] || exit 21
		[ "$container" = "$expected_instance" ] || exit 22
	); then
		:
	else
		env_status=$?
		case "$env_status" in
		20) die "host environment is missing a required value" ;;
		21) die "host environment project does not match instance" ;;
		22) die "host environment container does not match instance" ;;
		*) die "host environment could not be validated" ;;
		esac
	fi

	[ -f "$SCRIPT_DIR/ci-deploy-gateway.sh" ] &&
		[ -x "$SCRIPT_DIR/ci-deploy-gateway.sh" ] &&
		[ ! -L "$SCRIPT_DIR/ci-deploy-gateway.sh" ] ||
		die "gateway source is unavailable"
	[ -f "$SCRIPT_DIR/ci-deploy-force.sh" ] &&
		[ -x "$SCRIPT_DIR/ci-deploy-force.sh" ] &&
		[ ! -L "$SCRIPT_DIR/ci-deploy-force.sh" ] ||
		die "forced-command source is unavailable"
}

write_gateway_wrapper() {
	local destination="$1" deploy_root="$2" mirror="$3"
	local lock_file="$4" host_env="$5" gateway_core="$6" instance_name="$7"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'set -euo pipefail\n\n'
		printf 'readonly HERMES_INSTANCE_NAME=%q\n' "$instance_name"
		printf 'readonly HERMES_INSTANCE_ENV=%q\n' "$host_env"
		cat <<'EOF'
if [ ! -f "$HERMES_INSTANCE_ENV" ] || [ -L "$HERMES_INSTANCE_ENV" ]; then
	printf 'error: host environment is not a regular file\n' >&2
	exit 1
fi
if stat_output="$(stat -c '%u %a' "$HERMES_INSTANCE_ENV" 2>/dev/null)"; then
	:
elif stat_output="$(stat -f '%u %Lp' "$HERMES_INSTANCE_ENV" 2>/dev/null)"; then
	:
else
	printf 'error: cannot inspect host environment\n' >&2
	exit 1
fi
owner="${stat_output%% *}"
mode="${stat_output#* }"
expected_owner=0
if [ "${HERMES_DEPLOY_TESTING:-0}" = "1" ]; then
	expected_owner="$(id -u)"
fi
if [ "$owner" != "$expected_owner" ]; then
	printf 'error: host environment has the wrong owner\n' >&2
	exit 1
fi
permissions=$((8#$mode))
if [ $((permissions & 022)) -ne 0 ]; then
	printf 'error: host environment is group or other writable\n' >&2
	exit 1
fi
bash -n "$HERMES_INSTANCE_ENV" || {
	printf 'error: host environment has invalid shell syntax\n' >&2
	exit 1
}
set -a
. "$HERMES_INSTANCE_ENV"
set +a
if [ "${HERMES_PROJECT:-hermes}" != "$HERMES_INSTANCE_NAME" ]; then
	printf 'error: host environment project does not match instance\n' >&2
	exit 1
fi
if [ "${HERMES_CONTAINER:-hermes}" != "$HERMES_INSTANCE_NAME" ]; then
	printf 'error: host environment container does not match instance\n' >&2
	exit 1
fi
EOF
		printf 'export HERMES_DEPLOY_ROOT=%q\n' "$deploy_root"
		printf 'export HERMES_REPO_MIRROR=%q\n' "$mirror"
		printf 'export HERMES_LOCK_FILE=%q\n' "$lock_file"
		printf 'export HERMES_HOST_ENV=%q\n\n' "$host_env"
		printf 'exec %q "$@"\n' "$gateway_core"
	} >"$destination"
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
harden_state_roots() (
	local variable path bootstrap_testing="$TESTING"
	readonly bootstrap_testing
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

	if [ "$bootstrap_testing" = "0" ]; then
		chown root:root "$HERMES_BACKUP_DIR"
	fi
	chmod 0700 "$HERMES_DATA_DIR" "$HERMES_BACKUP_DIR"
)


install_control_plane() {
	local sbin libexec etc_dir sudoers_dir ssh_dir
	local wrapper gateway_core adapter installed_env sudoers keys
	local wrapper_tmp sudoers_tmp keys_tmp runtime_deploy_root runtime_mirror
	local runtime_lock runtime_host_env runtime_gateway_core
	local public_key deploy_group
	sbin="$(root_path /usr/local/sbin)"
	libexec="$(root_path /usr/local/libexec)"
	etc_dir="$(root_path "${HOST_ENV_PATH%/env}")"
	sudoers_dir="$(root_path /etc/sudoers.d)"
	ssh_dir="$(root_path "$DEPLOY_HOME/.ssh")"
	wrapper="$(root_path "$GATEWAY_WRAPPER_PATH")"
	gateway_core="$(root_path "$GATEWAY_CORE_PATH")"
	adapter="$(root_path "$FORCE_ADAPTER_PATH")"
	installed_env="$(root_path "$HOST_ENV_PATH")"
	sudoers="$sudoers_dir/$CONTROL_NAME"
	keys="$ssh_dir/authorized_keys"
	runtime_deploy_root="$(root_path "$DEPLOY_ROOT_PATH")"
	runtime_mirror="$(root_path "$REPO_MIRROR_PATH")"
	runtime_lock="$(root_path "$LOCK_FILE_PATH")"
	runtime_host_env="$(root_path "$HOST_ENV_PATH")"
	runtime_gateway_core="$(root_path "$GATEWAY_CORE_PATH")"

	if [ "$TESTING" = "1" ]; then
		install -d -m 0755 "$sbin" "$libexec" "$etc_dir" "$sudoers_dir"
		install -d -m 0755 "$(root_path "$DEPLOY_HOME")"
		install -d -m 0700 "$ssh_dir"
		install -m 0755 "$SCRIPT_DIR/ci-deploy-gateway.sh" "$gateway_core"
		install -m 0755 "$SCRIPT_DIR/ci-deploy-force.sh" "$adapter"
		install -m 0600 "$HOST_ENV_FILE" "$installed_env"
	else
		install -d -m 0755 -o root -g root "$sbin" "$libexec" "$etc_dir" "$sudoers_dir"
		install -m 0755 -o root -g root "$SCRIPT_DIR/ci-deploy-gateway.sh" "$gateway_core"
		install -m 0755 -o root -g root "$SCRIPT_DIR/ci-deploy-force.sh" "$adapter"
		install -m 0600 -o root -g root "$HOST_ENV_FILE" "$installed_env"
	fi

	wrapper_tmp="$wrapper.tmp.$$"
	write_gateway_wrapper "$wrapper_tmp" "$runtime_deploy_root" "$runtime_mirror" \
		"$runtime_lock" "$runtime_host_env" "$runtime_gateway_core" "$INSTANCE_NAME"
	chmod 0755 "$wrapper_tmp"
	if [ "$TESTING" = "0" ]; then
		chown root:root "$wrapper_tmp"
	fi
	mv -f "$wrapper_tmp" "$wrapper"

	sudoers_tmp="$sudoers.tmp.$$"
	printf '%s ALL=(root) NOPASSWD: %s ""\n' "$DEPLOY_USER" \
		"$GATEWAY_WRAPPER_PATH" >"$sudoers_tmp"
	chmod 0440 "$sudoers_tmp"
	if [ "$TESTING" = "0" ]; then
		chown root:root "$sudoers_tmp"
		visudo -cf "$sudoers_tmp" >/dev/null || die "generated sudoers rule is invalid"
	fi
	mv -f "$sudoers_tmp" "$sudoers"

	public_key="$(cat "$PUBLIC_KEY_FILE")"
	keys_tmp="$keys.tmp.$$"
	printf 'restrict,command="%s" %s\n' "$FORCE_ADAPTER_PATH" "$public_key" \
		>"$keys_tmp"
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
