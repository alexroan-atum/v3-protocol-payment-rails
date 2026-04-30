## Summary

<!-- 1–3 sentences describing what this PR changes and why. -->

## Type of change

- [ ] First-party module (`src/modules/<category>/`)
- [ ] Community module (`src/modules/contrib/<category>/`)
- [ ] Core change (`src/core/`, `src/abstracts/`, `src/interfaces/`)
- [ ] Docs / repo plumbing
- [ ] Bug fix
- [ ] Other: …

## Module contribution checklist (skip if N/A)

- [ ] Module in correct path (first-party vs `contrib/`, correct category)
- [ ] NatSpec on all public/external functions
- [ ] If `contrib/`: NatSpec includes `@custom:tier contrib`, `@custom:maintainer`, `@custom:audit-status`
- [ ] Tests added under matching `tests/integrations/...` path
- [ ] `MODULES.md` updated with new entry
- [ ] `CODEOWNERS` per-module override added if module has external maintainer

## Verification

- [ ] `just build` passes
- [ ] `just test` passes
- [ ] `just full-check` passes (lint + format)

## Risk

<!-- What could break? Migration impact? On-chain implications? -->
