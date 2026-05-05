# Receivables Node Implementation - v1 (Simplified)

## Overview

This is the first minimal working version of the **Receivables Node** system - a modular smart contract infrastructure for automated cross-chain token routing. The system enables tokens to be swapped, bridged, or forwarded through pre-configured action modules.

**Design Philosophy**: Keep it simple. Execution is permissionless (anyone can trigger), but only the owner can configure where tokens go. No emergency functions, no pause - if there's a problem, fix it by updating the configuration or module.

## Architecture

### Core Contracts

#### 1. **Node.sol** (`src/core/Node.sol`)

The central router contract that:

- Maintains token configurations mapping each token to an action module
- Enforces cooldown periods and minimum balance thresholds
- Delegates execution to configured action modules
- **Permissionless execution** - anyone can trigger pre-configured actions
- **Owner-only configuration** - only owner can set destinations and parameters

**Key Features:**

- Modular design: delegates to separate action modules
- Per-token configuration with independent parameters
- Cooldown mechanism to prevent spam and encourage batching
- Minimum balance thresholds to avoid small/expensive executions
- No pause, no emergency withdraw - fix issues via configuration updates

#### 2. **ForwardModule.sol** (`src/modules/ForwardModule.sol`)

Fully implemented module for simple token transfers.

- Transfers tokens to a pre-configured destination address
- Validates recipient address and minimum amounts
- 1:1 transfer (input amount = output amount)

#### 3. **SwapModule.sol** (`src/modules/SwapModule.sol`)

Skeleton implementation for token swaps.

- **Status**: Skeleton only (not implemented)
- **TODO**: Integrate with DEX routers (Uniswap, CalSwap, etc.)
- **TODO**: Implement oracle price validation
- **TODO**: Add TWAP protection

#### 4. **BridgeModule.sol** (`src/modules/BridgeModule.sol`)

Skeleton implementation for cross-chain bridging.

- **Status**: Skeleton only (not implemented)
- **TODO**: Integrate with CCTP, LayerZero, or other bridges
- **TODO**: Implement bridge health checks
- **TODO**: Add fee estimation

### Interfaces

All contracts implement well-defined interfaces in `src/interfaces/`:

- **INode.sol**: Core node functionality
- **IActionModule.sol**: Base interface for all action modules
- **IForwardModule.sol**: Forward-specific interface
- **ISwapModule.sol**: Swap-specific interface
- **IBridgeModule.sol**: Bridge-specific interface

## Usage Example

### Configuring a Node to Forward USDC

```solidity
// 1. Deploy contracts
Node node = new Node(owner);
ForwardModule forwardModule = new ForwardModule();

// 2. Encode forward parameters
IForwardModule.ForwardParams memory params = IForwardModule.ForwardParams({
    recipient: spigotAddress,
    requireSuccessfulReceipt: false,
    minAmount: 0
});
bytes memory encodedParams = forwardModule.encodeParams(params);

// 3. Configure token (owner only)
node.configureToken(
    USDC_ADDRESS,
    INode.ActionType.FORWARD,
    address(forwardModule),
    100e6,                            // Min 100 USDC to execute
    3600,                             // 1 hour cooldown
    encodedParams
);

// 4. Execute action (anyone can call - permissionless)
// Caller specifies exact amount to process
// Amount must be >= minBalance to prevent inefficient small swaps
uint256 balance = IERC20(USDC_ADDRESS).balanceOf(address(node));
node.executeAction(USDC_ADDRESS, balance);  // Execute with full balance

// Or execute partial amount (as long as amount >= minBalance)
node.executeAction(USDC_ADDRESS, 200e6);  // Execute only 200 USDC
```

### Cross-Chain Pipeline Example

**Scenario**: AVAX on Avalanche → USDC on Base

```solidity
// On Avalanche
Node nodeAvalanche = new Node(owner);

// Step 1: Configure AVAX → USDC swap
nodeAvalanche.configureToken(
    WAVAX,
    INode.ActionType.SWAP,
    address(swapModule),
    1 ether,  // min 1 AVAX
    3600,
    swapParams  // Uniswap, slippage, oracle config
);

// Step 2: Configure USDC → Bridge to Base
nodeAvalanche.configureToken(
    USDC,
    INode.ActionType.BRIDGE,
    address(bridgeModule),
    100e6,  // min 100 USDC
    7200,
    bridgeParams  // CCTP, destination chain, destination address
);

// On Base
Node nodeBase = new Node(owner);

// Step 3: Configure USDC → Forward to spigot
nodeBase.configureToken(
    USDC,
    INode.ActionType.FORWARD,
    address(forwardModule),
    0,
    0,
    forwardParams  // spigot address
);
```

## Testing

Comprehensive test suite in `tests/Node.t.sol`:

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test test_ExecuteForwardAction
```

### Test Coverage

- ✅ Token configuration
- ✅ Forward action execution
- ✅ Public execution (anyone can trigger)
- ✅ Minimum balance enforcement (amount must be >= minBalance)
- ✅ Insufficient balance handling (amount must be <= node balance)
- ✅ Partial amount execution (execute 500 tokens twice from 1000 balance)
- ✅ Cooldown mechanism
- ✅ Enable/disable tokens
- ✅ Update module parameters
- ✅ Execution validation (canExecute)

## Directory Structure

```
v3-protocol-payment-rails/
├── src/
│   ├── interfaces/
│   │   ├── INode.sol
│   │   ├── IActionModule.sol
│   │   ├── IForwardModule.sol
│   │   ├── ISwapModule.sol
│   │   └── IBridgeModule.sol
│   ├── core/
│   │   └── Node.sol
│   └── modules/
│       ├── ForwardModule.sol
│       ├── SwapModule.sol (skeleton)
│       └── BridgeModule.sol (skeleton)
└── tests/
    └── Node.t.sol
```

## Next Steps

### Priority 1: Complete SwapModule

- [ ] Integrate with Uniswap V3 router
- [ ] Add Chainlink oracle price validation
- [ ] Implement slippage protection
- [ ] Add TWAP validation (if available)
- [ ] Test with real DEX on fork

### Priority 2: Complete BridgeModule

- [ ] Integrate with CCTP for USDC bridging
- [ ] Add bridge health oracle integration
- [ ] Implement fee estimation
- [ ] Add support for LayerZero (optional)
- [ ] Test cross-chain flow on testnets

### Priority 3: Advanced Features

- [ ] Multi-path routing (swap A→B→C in single action)
- [ ] Gas optimization for batch executions
- [ ] Event indexing for off-chain monitoring
- [ ] Keeper bot implementation
- [ ] Integration with existing CashFlow Controller

### Priority 4: Security

- [ ] External security audit
- [ ] Formal verification of critical functions
- [ ] MEV protection analysis
- [ ] Gas griefing protection

## Key Design Decisions

1. **Permissionless Execution**: Anyone can trigger actions, but parameters are pre-configured by owner → Safe and decentralized
2. **Explicit Amount Parameter**: Caller specifies exact amount to execute → Enables partial execution and better control
3. **Amount-Based Minimum Check**: The amount parameter must be >= minBalance (not just node balance) → Prevents inefficient small swaps
4. **No Emergency Functions**: If there's a problem, fix it by updating configuration or deploying new module → Forces proper design
5. **No Pause**: Use per-token enable/disable instead → More granular control
6. **Cooldown Mechanism**: Prevents spam, encourages batching, limits MEV exposure
7. **Modular Architecture**: Separate modules allow independent upgrades and testing
8. **Per-Token Configuration**: Each token can have different parameters and execution settings

## Security Model

### What Protects the System

1. **Owner-only configuration** - Only owner can set destinations, modules, and parameters
2. **Pre-configured parameters** - Executors can't pass malicious data; they just trigger pre-defined actions
3. **Amount constraints** - Executor specifies amount, but it's bounded: amount >= minBalance AND amount <= node balance
4. **Cooldown enforcement** - Prevents DOS and forces batching (reduces MEV exposure)
5. **Minimum balance threshold** - Prevents executing tiny/expensive amounts (e.g., can't swap $5 when minBalance is $100)
6. **Module validation** - validate() checks before execution
7. **Per-token enable flag** - Owner can disable problematic tokens
8. **Module-level protection** - Each module implements its own safety checks (oracle validation, slippage, etc.)

### Why Permissionless Execution is Safe

- **Constrained actions**: Executor can only trigger what owner pre-configured
- **No arbitrary parameters**: Can't change destination, slippage, or other critical params
- **Amount bounded**: Executor chooses amount, but constrained by minBalance (lower) and node balance (upper)
- **Worst case**: Someone triggers action early → token moves to pre-configured destination → not harmful
- **DOS self-limiting**: Caller pays gas, so spamming is expensive for attacker
- **Cooldown limits**: Even if triggered early, cooldown prevents immediate re-execution

### How to Recover from Issues

**Problem: Bug in module**

- Solution: Deploy fixed module, call `updateModuleParams()` or reconfigure token with new module

**Problem: Wrong configuration**

- Solution: Call `updateModuleParams()` to update destination/parameters

**Problem: Need to stop token processing**

- Solution: Call `setTokenEnabled(token, false)` to disable

**Problem: Module not working, need funds back**

- Solution: Configure token to use ForwardModule with owner as recipient

## MEV Protection (To Be Implemented in SwapModule)

The SwapModule will implement multi-layered MEV protection:

1. **Oracle price validation** (Chainlink) - Compare swap output vs oracle price
2. **TWAP comparison** (Uniswap V3) - Validate against time-weighted average
3. **Slippage bounds** - Enforce max deviation from expected price
4. **Cooldown + batching** - Execute once per hour instead of every block (reduces MEV surface)
5. **Minimum balance** - Don't swap $5, wait for $100K+ (amortizes MEV impact)

## Gas Optimization Notes

- Use `memory` for config reads where possible
- **Custom errors**: Save ~135K gas on deployment vs string errors
- Off-chain filtering via `canExecute()` before sending transaction
- Minimal storage updates per execution
- **Savings from simplification**: Removed ~700 gas per execution (no permission checks, no pause checks)
- Single execution function reduces contract complexity and code size

## Cooldown Rationale

**Why cooldown is kept despite being permissionless:**

1. **DOS prevention**: Limits how often actions can be triggered (prevents gas griefing)
2. **Batching enforcement**: Encourages collecting larger amounts before execution (gas efficient)
3. **MEV protection**: Reduces frequency of swaps → less MEV exposure
4. **Integration timing**: Some bridges/DEXs work better with periodic execution vs continuous
5. **Business logic**: Owner might want "once per day" execution regardless of who triggers

**Note**: Cooldown can be set to 0 per token if not needed. It's optional but recommended.

## Known Limitations (v1)

1. SwapModule and BridgeModule are skeletons only
2. No multi-hop routing (must configure each step separately)
3. No automatic cross-chain message passing (requires off-chain keeper)
4. Limited to single token per action
5. No built-in DEX aggregation

## License

MIT

## Author

Credit Cooperative
