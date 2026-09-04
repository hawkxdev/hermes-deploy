#!/usr/bin/env bash
# Narrow SSH forced-command adapter for the CI deploy identity.
set -euo pipefail

if [ "$#" -ne 0 ] || [ "${SSH_ORIGINAL_COMMAND:-}" != "deploy" ]; then
	printf 'error: only the deployment command is allowed\n' >&2
	exit 64
fi

adapter_name="${0##*/}"
case "$adapter_name" in
*-deploy-force) control_name="${adapter_name%-force}" ;;
*)
	printf 'error: forced-command adapter has an invalid installed name\n' >&2
	exit 64
	;;
esac

exec sudo -n "/usr/local/sbin/${control_name}-gateway"
