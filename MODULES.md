# Modules Registry

This file tracks every module shipped in this repo, its tier, maintainer, and audit status. **Update this file in the same PR that adds or modifies a module.**

## First-party modules

| Path                                        | Tier        | Maintainer                    | Audit Status | Notes                                   |
| ------------------------------------------- | ----------- | ----------------------------- | ------------ | --------------------------------------- |
| `src/modules/forwards/ForwardModule.sol`    | first-party | @credit-cooperative/core-team | unaudited    | 1:1 transfer to configured recipient    |
| `src/modules/swaps/DexAggregatorModule.sol` | first-party | @credit-cooperative/core-team | unaudited    | Atomic swap via whitelisted DEX routers |
| `src/modules/swaps/CowSwapModule.sol`       | first-party | @credit-cooperative/core-team | unaudited    | CoW Protocol order book integration     |
| `src/modules/bridges/CCTPBridgeModule.sol`  | first-party | @credit-cooperative/core-team | unaudited    | Circle CCTP integration                 |

## Community modules

_None yet. Add a row when merging a PR that adds a `src/modules/contrib/<category>/<Module>.sol`._

| Path                                                          | Tier      | Maintainer                           | Audit Status | Upstream                           |
| ------------------------------------------------------------- | --------- | ------------------------------------ | ------------ | ---------------------------------- |
| _example: `src/modules/contrib/bridges/AtumBridgeModule.sol`_ | _contrib_ | _@atum-team (security@atum.example)_ | _unaudited_  | _https://github.com/atum-team/..._ |

## Audit status values

- `unaudited` — no third-party security review
- `internal-review` — reviewed by CC core team only
- `audited-by-<firm>:<YYYY-MM>` — external audit (link to report in Notes)
- `formal-verification:<tool>` — formal verification applied
