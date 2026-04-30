# Security Policy

## Reporting a vulnerability

If you discover a vulnerability in any contract or module in this repo, **do not open a public issue**. Email **security@creditcoop.xyz** with:

- Description of the vulnerability
- Steps to reproduce or proof-of-concept
- Affected version (commit SHA, semver tag, or `deployed/...` tag if relevant)
- On-chain address(es) if you've identified affected deployments
- Your contact info for follow-up

We aim to acknowledge within 72 hours and will coordinate disclosure with you.

## Scope

**In scope:**
- Contracts in `src/core/`, `src/abstracts/`, `src/interfaces/`, `src/libraries/`
- First-party modules in `src/modules/<category>/` (excluding `contrib/`)

**Out of scope** — report directly to the module's maintainer (see `MODULES.md`):
- Community modules in `src/modules/contrib/`

**Out of scope** — report upstream:
- Issues in dependencies (OpenZeppelin, forge-std, etc.)

## Supported versions

We support the latest tagged `vX.Y.Z` release on `main`. `deployed/...` tags reference frozen commits and will not receive patches; integrators should re-deploy from the current `vX.Y.Z` line.
