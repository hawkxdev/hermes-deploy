# Threat Model

## Protected assets

- Provider credentials and OAuth state
- Messaging bot tokens and user authorization data
- Sessions, memories, skills, profiles, and user data
- Deployment bundle and backup integrity
- Docker host and neighboring services
- Public Git history

## Trust boundaries

| Boundary | Contract |
|---|---|
| Public Git repository | Desired state, safe templates, generic paths, and synthetic fixtures only |
| Deployment tree | Immutable versioned bundles under `/opt/hermes/deploy` |
| Runtime state | Private mutable data under `/opt/hermes/data` |
| Recovery data | Verified backups under `/opt/backups/hermes` |

## Threats and controls

| Threat | Required control |
|---|---|
| Moving or compromised image | Use a verified official release pinned by manifest digest |
| Credential disclosure | Keep production values and credential files outside Git and command output |
| Unauthorized messaging user | Keep allow-all disabled and use an explicit allowlist or approved pairing |
| Runaway tool loop | Enable hard-stop guardrails and require approval for sensitive writes |
| Host takeover | Do not expose the Docker socket, privileged mode, or broad host mounts |
| Public network exposure | Do not publish API or dashboard ports in the initial deployment |
| Partial deployment | Validate a complete release bundle before activation |
| State loss | Back up the complete runtime state outside the deployment tree |
| Incompatible rollback | Separate image rollback from destructive state restoration |
| Damage to neighboring services | Use a dedicated Compose project and service-scoped operations |
| Secret leakage through fixtures or logs | Use synthetic values and scan repository files and history before release |

## Explicit exclusions

This model does not treat command approvals as a substitute for user authorization, container isolation, backup, or least-privilege host access.
