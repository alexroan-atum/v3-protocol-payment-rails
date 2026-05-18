# v3-protocol-payment-rails

[![License: MIT][license-badge]][license]

[license]: https://opensource.org/licenses/MIT
[license-badge]: https://img.shields.io/badge/License-MIT-blue.svg

Modular cross-chain token routing rails. The repo ships a single core router contract — `PaymentRails` — together with a growing catalogue of pluggable **action modules** that handle the actual on-chain work: forwarding, swapping, bridging, and whatever the ecosystem adds next.

## What this is

- **`PaymentRails`** — owner-configurable router. The owner pre-registers a `(token, moduleType, params)` triple per token; anyone can then call `executeAction` to trigger that pre-configured action when the balance crosses a threshold. No arbitrary calldata, no surprise destinations.
- **Action modules** — small, single-purpose contracts that implement the `IActionModule` interface. Each module is responsible for one side-effect (forward, swap, bridge), validates its own parameters, and is plugged into a `PaymentRails` instance by configuration.
- **Two-tier module catalogue** — first-party modules (CC owns and audits) live under `src/modules/<category>/`; community modules live under `src/modules/contrib/<category>/` with a different trust model. See [`MODULES.md`](./MODULES.md) and [`src/modules/contrib/README.md`](./src/modules/contrib/README.md).

## Repo layout

```
src/
  core/         PaymentRails — the router
  abstracts/    PaymentRailsState, ActionModuleBase
  interfaces/   IActionModule, IPaymentRails, per-module interfaces
  libraries/    Errors and shared utilities
  types/        DataTypes
  modules/
    forwards/   ForwardModule
    swaps/      DexSwapModule, CowSwapModule
    bridges/    CCTPBridgeModule
    contrib/    community modules (different trust model — see README inside)
tests/          unit, integration, fork, invariant — mirroring src/modules categories
scripts/        deployment + smoke/dryrun scripts
```

## Quickstart for integrators

Install as a Solidity dependency:

```sh
bun install github:credit-cooperative/v3-protocol-payment-rails
```

Add a remapping in `remappings.txt`:

```txt
@credit-cooperative/payment-rails/=node_modules/@credit-cooperative/payment-rails/
```

Import:

```solidity
import { PaymentRails } from "@credit-cooperative/payment-rails/src/core/PaymentRails.sol";
import { CCTPBridgeModule } from "@credit-cooperative/payment-rails/src/modules/bridges/CCTPBridgeModule.sol";
```

Pin to a tagged release in production. `vX.Y.Z` tags follow semver; `deployed/<chain>-<YYYYMM>-<label>` tags anchor specific deployments.

## Local development

```sh
bun install
bun run setup        # initialize git hooks
just build           # forge build
just test            # forge test
just full-check      # solhint + fmt + prettier
```

Fork tests require RPC URLs — copy `.env.example` to `.env` and fill in your endpoints.

## Contributing

If you want to add or modify a module — first-party or `contrib/` — start with [`CONTRIBUTING.md`](./CONTRIBUTING.md) and the module catalogue in [`MODULES.md`](./MODULES.md). For new modules, open a [module proposal issue](./.github/ISSUE_TEMPLATE/module-proposal.md) before sending a PR.

## Security

Disclose vulnerabilities privately to **security@creditcoop.xyz**. See [`SECURITY.md`](./SECURITY.md) for scope and disclosure details.

## License

MIT. See [`LICENSE.md`](./LICENSE.md).
