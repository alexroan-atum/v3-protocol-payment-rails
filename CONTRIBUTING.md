# Contributing

This repo is a modular cross-chain routing rail. Most contributions take the form of a **new action module** or a fix/extension to an existing one. The flow below covers both.

If you have a question that isn't covered here, [open an issue](../../issues/new) or reach out to the Credit Cooperative team.

## Two contribution paths

There are two tiers for modules. Pick the one that fits your situation.

|                      | **First-party**                                                        | **Community (`contrib/`)**                                            |
| -------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Path                 | `src/modules/<category>/`                                              | `src/modules/contrib/<category>/`                                     |
| Maintainer           | CC core team                                                           | You / your team                                                       |
| Audit responsibility | CC                                                                     | You                                                                   |
| Review bar           | Full review + (eventually) audit                                       | CC reviews for safety only                                            |
| Approval             | CC core team approval required                                         | CC core team approval required                                        |
| When to choose       | The module is a primitive CC wants to own and ship as part of the rail | You want to ship your own module on the rail without ceding ownership |

When in doubt, start in `contrib/`. A `contrib/` module that gets externally audited and adopted by CC core can be promoted later with a one-line rename.

Read [`src/modules/contrib/README.md`](./src/modules/contrib/README.md) before opening a `contrib/` PR.

## Before you start

1. **Open a [module proposal issue](./.github/ISSUE_TEMPLATE/module-proposal.md)** describing what the module does, which external protocols it touches, and which tier you're targeting. This avoids wasted work on something that isn't a fit.
2. Wait for CC core team feedback. Once aligned, fork the repo and branch from `main`.

## Local setup

Required:

- [Foundry](https://github.com/foundry-rs/foundry) (latest)
- [Bun](https://bun.sh) >= 1.0
- [Just](https://github.com/casey/just) >= 1.0

```sh
git clone git@github.com:credit-cooperative/v3-protocol-payment-rails.git
cd v3-protocol-payment-rails
bun install
bun run setup        # initialize git hooks
just build
just test
```

Fork tests need RPC URLs — copy `.env.example` to `.env` and fill them in.

## Adding a module

1. **Place the file** under the right path:
   - First-party: `src/modules/<category>/<YourModule>.sol`
   - Community: `src/modules/contrib/<category>/<YourModule>.sol`

2. **Implement `IActionModule`** (or a more specific interface like `ISwapModule`, `IBridgeModule`). Inherit from `ActionModuleBase` where it fits.

3. **NatSpec on every public/external function.** Include `@notice`, `@param`, `@return` as appropriate.

4. **For `contrib/` modules**, the contract NatSpec must include:

   ```solidity
   /// @title YourModule
   /// @custom:tier contrib
   /// @custom:maintainer @your-team (security@your.example)
   /// @custom:audit-status unaudited
   ```

5. **Add tests** under the matching path:
   - First-party: `tests/{unit,integration,fork,invariant}/concrete/<category>/<your-module>/`
   - Community: `tests/{unit,integration,fork,invariant}/concrete/contrib/<category>/<your-module>/`

   At minimum: unit tests covering `validate()`, `execute()`, and any module-specific state. Integration tests against a `MockNode`. Fork tests if behavior depends on a live external protocol.

6. **Update [`MODULES.md`](./MODULES.md)** with a new row in the same PR.

7. **Update [`CODEOWNERS`](./CODEOWNERS)** with a per-module override if your module has an external maintainer:

   ```
   /src/modules/contrib/<category>/<YourModule>.sol  @your-team @credit-cooperative/core-team
   ```

## Verification before opening the PR

```sh
just build          # forge build clean
just test           # forge test green (fork tests need RPC URLs)
just full-check     # solhint + forge fmt + prettier
```

If `just full-check` flags issues, run `just full-write` to auto-fix what's auto-fixable.

## PR checklist

Use the [PR template](./.github/PULL_REQUEST_TEMPLATE.md) — it walks through:

- Module placed in correct path/tier/category
- NatSpec on every public/external function
- (`contrib/` only) `@custom:tier`, `@custom:maintainer`, `@custom:audit-status` on the contract
- Tests added under matching path
- `MODULES.md` updated
- `CODEOWNERS` per-module override added if needed
- Build, test, full-check all green

## Code style

- **Format:** `forge fmt` (runs on commit). 4-space indent, 120-char lines, double quotes.
- **Naming:** contracts `PascalCase`, functions `camelCase`, constants `SCREAMING_SNAKE_CASE`, internal/private `_underscore`.
- **Test names:** `test_<Function>_<Condition>_<Expected>` (e.g., `test_Execute_RevertsWhen_AmountBelowMin`).

## Security

Security-relevant findings should never go in a public issue. Email **security@creditcoop.xyz** — see [`SECURITY.md`](./SECURITY.md) for scope and disclosure terms.

## License

By contributing, you agree your contributions are licensed under MIT.
