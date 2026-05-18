# Payment Rails — Implementation Overview

## Overview

The **Payment Rails** system is a modular smart contract infrastructure for automated cross-chain token routing. Tokens sent to a `PaymentRails` contract are swapped, bridged, or forwarded through pre-configured action modules — permissionlessly triggered by anyone, but only configurable by the owner.

**Design Philosophy**: Execution is permissionless (anyone can trigger), but only the owner can configure where tokens go. No emergency functions, no pause — if there's a problem, fix it by updating the configuration or replacing the module.

For a deep architectural walkthrough see [`docs/TECHNICAL_GUIDE.md`](./docs/TECHNICAL_GUIDE.md).

---

## Architecture

### Core Contracts

#### 1. PaymentRails (`src/core/PaymentRails.sol`)

The central router contract that:

- Maintains per-token configurations mapping each token to an action module
- Enforces minimum balance thresholds
- Delegates execution to configured action modules
- **Permissionless execution** — anyone can trigger pre-configured actions via `executeAction()`
- **Owner-only configuration** — only owner can call `configureToken()`

Inherits:

- `PaymentRailsState` — state variable abstraction
- `Ownable` (OpenZeppelin) — owner-only configuration
- `ReentrancyGuard` (OpenZeppelin) — reentrancy protection on `executeAction()`

#### 2. PaymentRailsState (`src/abstracts/PaymentRailsState.sol`)

Abstract contract separating state management from business logic. Exposes internal helpers (`_getTokenConfig`, `_isTokenConfigured`, `_isTokenEnabled`, `_setTokenConfig`, `_deleteTokenConfig`).

#### 3. ActionModuleBase (`src/abstracts/ActionModuleBase.sol`)

Shared base for all action modules. Provides utility functions: `_failedResult`, `_successResult`, `_hasSufficientBalance`, `_safeTransferFrom`.

### Interfaces

All contracts implement well-defined interfaces in `src/interfaces/`:

- **IPaymentRails** — core router: `configureToken()`, `executeAction()`, `previewExecution()`, `getTokenConfig()`, `getTokenBalance()`
- **IActionModule** — base module interface: `execute()`, `validate()`, `estimateOutput()`, `moduleType()`
- **IForwardModule** — forward-specific interface
- **IDexSwapModule** — DEX atomic swap interface
- **ICowSwapModule** — CowSwap order-book interface
- **ICCTPBridgeModule** — CCTP bridge interface
- **IGPv2Settlement** — external CowSwap GPv2 settlement interface
- **ITokenMessengerV2** — external Circle CCTP TokenMessenger interface

### Shared Types & Errors

- **DataTypes** (`src/types/DataTypes.sol`) — all struct definitions: `TokenConfig`, `ExecutionResult`, `ForwardParams`, `DexSwapParams`, `DexSwapExecutionData`, `CowSwapParams`, `CowOrderMetadata`, `CCTPBridgeParams`, `CCTPDomainConfig`
- **Errors** (`src/libraries/Errors.sol`) — all custom errors, centralized for gas efficiency

---

## Action Modules

### ForwardModule (`src/modules/forwards/ForwardModule.sol`)

Simple 1:1 token transfer to a pre-configured recipient.

- Transfers tokens from PaymentRails to `ForwardParams.recipient`
- Validates recipient address and minimum amounts
- Module type: `"FORWARD"`

### DexSwapModule (`src/modules/swaps/DexSwapModule.sol`)

Atomic token swap via whitelisted DEX routers (e.g., Uniswap V3).

- Owner whitelists router addresses (`addRouter()` / `removeRouter()`)
- Static config (`DexSwapParams`): target output token
- Dynamic per-execution data (`DexSwapExecutionData`): router address, minAmountOut, deadline, router calldata
- Uses balance-diff measurement to handle fee-on-transfer tokens
- Inherits `Ownable2Step` for router whitelist management
- Module type: `"SWAP"`

### CowSwapModule (`src/modules/swaps/CowSwapModule.sol`)

Asynchronous order-book swap via CowSwap GPv2 protocol.

- `execute()` places an order → CowSwap solvers fill it off-chain → `markFilled()` settles bookkeeping
- Buy tokens go directly to PaymentRails from the solver (receiver = PaymentRails)
- `cancelOrder()` (owner-only) returns unsold tokens to PaymentRails
- `isValidSignature()` implements EIP-1271 for CowSwap solver verification
- Tracks cumulative `_pendingApprovalAmount[token]` across concurrent orders
- Inherits `Ownable2Step`
- Module type: `"COWSWAP"`

### CCTPBridgeModule (`src/modules/bridges/CCTPBridgeModule.sol`)

Cross-chain USDC bridge via Circle's CCTP V2.

- Owner configures per-domain routing via `setDomainConfig()` / `removeDomainConfig()`
- Supports standard transfers (free, ~15 min) and fast transfers (fee, ~20s) via `maxFee`
- Supports CCTP V2 hooks for destination-chain automation (`depositForBurnWithHook`)
- USDC-only (validated at execution time)
- Inherits `Ownable2Step`
- Module type: `"CCTP_BRIDGE"`

---

## Usage Examples

### Configuring PaymentRails to Forward USDC

```solidity
PaymentRails paymentRails = new PaymentRails(owner);
ForwardModule forwardModule = new ForwardModule();

DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
    recipient: spigotAddress,
    requireSuccessfulReceipt: false,
    minAmount: 0
});
bytes memory encodedParams = forwardModule.encodeParams(params);

paymentRails.configureToken(
    USDC_ADDRESS,
    "FORWARD",
    address(forwardModule),
    100e6,           // min 100 USDC to execute
    encodedParams,
    true             // enabled
);

// Anyone can trigger execution
uint256 balance = IERC20(USDC_ADDRESS).balanceOf(address(paymentRails));
paymentRails.executeAction(USDC_ADDRESS, balance);
```

### Cross-Chain Pipeline: Avalanche → Base

```solidity
// On Avalanche: swap WAVAX → USDC, then bridge USDC to Base
PaymentRails avaxRails = new PaymentRails(owner);
DexSwapModule dexSwap = new DexSwapModule(owner);
CCTPBridgeModule cctpBridge = new CCTPBridgeModule(usdcAddress, tokenMessengerV2, owner);

// Configure WAVAX → swap to USDC
avaxRails.configureToken(
    WAVAX,
    "SWAP",
    address(dexSwap),
    1 ether,
    dexSwap.encodeParams(DataTypes.DexSwapParams({ targetToken: USDC })),
    true
);

// Configure USDC → bridge to Base (CCTP domain 6)
avaxRails.configureToken(
    USDC,
    "CCTP_BRIDGE",
    address(cctpBridge),
    100e6,
    cctpBridge.encodeParams(DataTypes.CCTPBridgeParams({ destinationDomain: 6 })),
    true
);

// On Base: forward USDC to spigot
PaymentRails baseRails = new PaymentRails(owner);
ForwardModule forwardModule = new ForwardModule();

baseRails.configureToken(
    USDC,
    "FORWARD",
    address(forwardModule),
    0,
    forwardModule.encodeParams(DataTypes.ForwardParams({
        recipient: spigotAddress,
        requireSuccessfulReceipt: false,
        minAmount: 0
    })),
    true
);
```

---

## Testing

Test suite: 670+ tests across unit, integration, fork, and invariant categories.

```bash
forge test              # run all tests (default profile)
forge test -vvv         # verbose output
forge test --mt test_Execute   # match specific test names
```

### Test Organization (Sablier BTT Style)

```
tests/
  unit/concrete/
    payment-rails/       # PaymentRails unit tests (7 categories)
    forwards/            # ForwardModule unit tests (6 categories)
    swaps/
      cow-swap-module/   # CowSwapModule unit tests (9 categories)
      dex-swap-module/   # DexSwapModule unit tests (9 categories)
    bridges/
      cctp-bridge-module/ # CCTPBridgeModule unit tests (10 categories)
  integration/concrete/  # Module integration tests with MockPaymentRails
  fork/concrete/         # Fork tests against live mainnet protocols
  invariant/             # Stateful fuzz / invariant tests
  shared/mocks/          # Shared mock contracts
```

---

## Directory Structure

```
src/
├── core/
│   └── PaymentRails.sol
├── abstracts/
│   ├── PaymentRailsState.sol
│   └── ActionModuleBase.sol
├── interfaces/
│   ├── IPaymentRails.sol
│   ├── IActionModule.sol
│   ├── IForwardModule.sol
│   ├── IDexSwapModule.sol
│   ├── ICowSwapModule.sol
│   ├── ICCTPBridgeModule.sol
│   ├── IGPv2Settlement.sol
│   └── ITokenMessengerV2.sol
├── types/
│   └── DataTypes.sol
├── libraries/
│   └── Errors.sol
└── modules/
    ├── forwards/
    │   └── ForwardModule.sol
    ├── swaps/
    │   ├── DexSwapModule.sol
    │   └── CowSwapModule.sol
    └── bridges/
        └── CCTPBridgeModule.sol
tests/       # 55 test files, 10,700+ LOC
scripts/     # deployment + smoke/dry-run scripts
docs/        # architecture guides, audit notes, test docs
```

---

## Security Model

### What Protects the System

1. **Owner-only configuration** — only owner can set destinations, modules, and parameters
2. **Pre-configured parameters** — executors cannot pass malicious data; they trigger pre-defined actions
3. **Amount constraints** — amount >= minBalance AND amount <= PaymentRails balance
4. **Module validation** — `moduleType()` call validates module on configuration
5. **Exact approvals** — PaymentRails approves exact amount to module, revokes on failure
6. **Reentrancy guard** — `nonReentrant` on `executeAction()`
7. **Two-step ownership** — modules use `Ownable2Step` for safe ownership transfers
8. **SafeERC20** — all token transfers use OpenZeppelin's SafeERC20
9. **Custom errors** — gas-efficient structured errors in `Errors.sol`
10. **Per-token enable flag** — owner can disable problematic tokens instantly

### Why Permissionless Execution is Safe

- Executors can only trigger what the owner pre-configured
- No arbitrary parameters — can't change destination, slippage, or critical params
- Amount is bounded by minBalance (lower) and PaymentRails balance (upper)
- Worst case: someone triggers action early → token moves to pre-configured destination → not harmful
- Caller pays gas, so spamming is self-limiting

### Recovery Procedures

| Problem                 | Solution                                                       |
| ----------------------- | -------------------------------------------------------------- |
| Bug in module           | Deploy fixed module, reconfigure token with `configureToken()` |
| Wrong configuration     | Call `configureToken()` with corrected parameters              |
| Need to stop processing | Call `configureToken()` with `enabled: false`                  |
| Need funds back         | Configure token with ForwardModule pointing to owner           |

---

## Key Design Decisions

1. **Permissionless execution** — anyone can trigger, parameters are pre-configured → safe and decentralized
2. **Explicit amount parameter** — caller specifies exact amount → enables partial execution and batching
3. **No emergency functions** — fix issues via reconfiguration → forces proper design, smaller attack surface
4. **String-based action types** — supports unlimited module types without interface changes
5. **Modular architecture** — separate modules allow independent upgrades and auditing
6. **Graceful failure** — modules return `ExecutionResult` with `success: false` instead of reverting where possible

---

## Dependencies

- **Solidity**: 0.8.29 (pinned)
- **OpenZeppelin Contracts**: 5.3.0 (`Ownable`, `Ownable2Step`, `SafeERC20`, `ReentrancyGuard`, `IERC20`)
- **forge-std**: v1.10.0 (testing only)
- **Package manager**: bun

---

## License

MIT — Credit Cooperative
