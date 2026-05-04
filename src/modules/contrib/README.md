# `contrib/` — community-maintained modules

Modules in this directory are contributed and maintained by external teams. They follow a **different trust model** than first-party modules in sibling directories.

## What `contrib/` means

- **CC reviews them for safety** — compiles, tests pass, NatSpec correct, doesn't break the rail.
- **CC does not vouch** for their correctness, security, or audit status.
- **The maintainer team owns the module** — bug reports, fixes, and disclosure go to them. See `MODULES.md` and the module's NatSpec `@custom:maintainer` line.
- **Use at your own risk.** Importing a `contrib/` module is positively opting into community trust.

## Adding a contrib module

1. Open a [module proposal issue](../../../issues/new?template=module-proposal.md) first to align on scope.
2. Fork this repo, branch from `main`, add your module under `src/modules/contrib/<category>/<YourModule>.sol`.
3. Include in module NatSpec:
   ```solidity
   /// @title YourModule
   /// @custom:tier contrib
   /// @custom:maintainer @your-team (security@your.example)
   /// @custom:audit-status unaudited
   ```
4. Add tests under `tests/integrations/contrib/<category>/<your-module>/`.
5. Add a row to `MODULES.md`.
6. Add a per-module override to `CODEOWNERS` so your team auto-reviews future changes:
   ```
   /src/modules/contrib/<category>/<YourModule>.sol  @your-team @credit-cooperative/core-team
   ```
7. Open the PR. CC core team reviews for safety; merge requires their approval.

## Promotion to first-party

A `contrib/` module that gets externally audited and adopted by CC core can be promoted with a one-line rename PR — path moves from `src/modules/contrib/<category>/` → `src/modules/<category>/`, `CODEOWNERS` updates, `MODULES.md` updates.
