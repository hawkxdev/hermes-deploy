# Security policy

## What this repository is

This repository is a deployment and operations bundle for Hermes Agent. It contains Compose definitions, lifecycle scripts, tests, and documentation. It does not vendor or fork Hermes Agent source code, and it ships no production values.

Report vulnerabilities in Hermes Agent itself to [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent). Report weaknesses in the deployment contract, the lifecycle scripts, or the delivery workflow here.

## Reporting a vulnerability

Use GitHub's private reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. That channel is enabled and reaches the maintainer without disclosing anything publicly.

Do not open a public issue for a suspected vulnerability, and do not include real tokens, keys, hostnames, or addresses in the report.

A useful report names the affected file or script, the commit or release you tested, what an attacker gains, and the steps that demonstrate it.

This project is maintained by one person and reports are handled on a best-effort basis. There is no guaranteed response time.

## Supported versions

Fixes land on `main` and reach production as a new projection. Older commits and tags are not patched, so upgrading to current `main` is the remedy for any accepted report.

## In scope

- Weaknesses in the lifecycle scripts: validation, backup, deploy, verify, restore, rollback.
- Ways to defeat the deployment boundaries the bundle claims to enforce, including the exclusions listed in the README, the mount boundary, and the separation of code rollback from state restore.
- Weaknesses in the delivery workflow or the least-privilege host gateway, including ways to make it act on a revision other than the one dispatched.
- A verification path that reports success while the condition it claims to prove is false. A check that cannot fail is treated as a vulnerability here, not as a cosmetic defect.
- Any credential, real hostname, or address found committed to this repository. By contract none exists; a finding means the contract failed.

## Out of scope

- Vulnerabilities in Docker Engine, s6-overlay, or the upstream Hermes image. Report those to their own projects.
- Findings that require the operator to have already departed from the documented contract, such as publishing ports, mounting the Docker socket, overriding the entrypoint, or enabling `init`.
- Hardening absent from an operator's own host, network, or messaging account.
- Missing defence in depth with no demonstrated impact.
