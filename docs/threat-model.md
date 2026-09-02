# Threat Model

## Protected assets

- Provider credentials and OAuth state
- Messaging bot tokens and user authorization data
- Sessions, memories, skills, profiles, and user data
- Deployment bundle and backup integrity
- Docker host and neighboring services

## Trust boundaries

| Boundary | Contract |
|---|---|
| Deployment bundle | Desired state, safe templates, and generic paths only |
| Runtime state | Private mutable data under `/opt/hermes/data` |
| Recovery data | Verified backups under `/opt/backups/hermes` |

## Threats and controls

| Threat | Required control |
|---|---|
| Moving or compromised image | Use a verified official release pinned by manifest digest |
| Credential disclosure | Keep production values and credential files outside the deployment bundle and command output |
| Unauthorized messaging user | Keep allow-all disabled and use an explicit allowlist or approved pairing |
| Runaway tool loop | Enable hard-stop guardrails and require approval for sensitive writes. An approval mode can be voided per action class by a command allowlist, so verify the live configuration rather than the shipped template |
| Host takeover | Do not expose the Docker socket, privileged mode, or broad host mounts |
| Public network exposure | Do not publish API or dashboard ports |
| Partial deployment | Validate a complete release bundle before activation |
| State loss | Back up all non-reproducible runtime state outside the live data directory; the package cache may be omitted |
| Incompatible rollback | Separate image rollback from destructive state restoration |
| Damage to neighboring services | Use a dedicated Compose project and service-scoped operations |
| Secret leakage through templates or logs | Use value-free templates and keep credential values out of logs |

## Explicit exclusions

This model does not treat command approvals as a substitute for user authorization, container isolation, backup, or least-privilege host access.
