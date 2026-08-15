#!/usr/bin/env bash
# Narrow SSH forced-command adapter for the CI deploy identity.
set -euo pipefail

if [ "$#" -ne 0 ] || [ "${SSH_ORIGINAL_COMMAND:-}" != "deploy" ]; then
	printf 'error: only the deployment command is allowed\n' >&2
	exit 64
fi

exec sudo -n /usr/local/sbin/hermes-deploy-gateway
