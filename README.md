# Credit Cooperative Foundry Template

[![License: MIT][license-badge]][license]

[license]: https://opensource.org/licenses/MIT
[license-badge]: https://img.shields.io/badge/License-MIT-blue.svg

A production-ready Foundry-based template for developing Solidity smart contracts at Credit Cooperative, with sensible defaults and integrated tooling.

## What's Inside

- **[Foundry](https://github.com/foundry-rs/foundry)**: Compile, test, fuzz, format, and deploy smart contracts
- **[Credit Coop Devkit](https://github.com/credit-cooperative/devkit)**: Shared configuration and build automation
- **[Just](https://github.com/casey/just)**: Command runner for development tasks
- **[Husky](https://github.com/typicode/husky)**: Git hooks for pre-commit validation
- **[lint-staged](https://github.com/okonet/lint-staged)**: Run linters on staged files
- **[Forge Std](https://github.com/foundry-rs/forge-std)**: Collection of helpful contracts for testing
- **[Prettier](https://github.com/prettier/prettier)**: Code formatter for non-Solidity files
- **[Solhint](https://github.com/protofire/solhint)**: Linter for Solidity code

## Getting Started

### Prerequisites

- [Foundry](https://github.com/foundry-rs/foundry#installation) >= 0.2.0
- [Bun](https://bun.sh) >= 1.0
- [Just](https://github.com/casey/just#installation) >= 1.0

### Installation

Create a new project from this template:

```sh
forge init --template credit-cooperative/foundry-template my-project
cd my-project
bun install
bun run setup  # Initialize git hooks
```

## Features

### 🛠️ Devkit Integration

This template integrates [@credit-cooperative/devkit](https://www.npmjs.com/package/@credit-cooperative/devkit) which provides:

- Shared Just recipes for build automation
- Prettier/Solhint configurations
- TypeScript configs for mixed projects
- GitHub Actions workflows

All configuration is centralized in devkit and automatically updated when you upgrade.

### 🔨 Just Command Runner

We use [Just](https://github.com/casey/just) instead of npm scripts for better composability and error handling.

**See all available commands:**

```sh
just --list
```

**Common commands:**

```sh
just build              # Compile contracts
just test               # Run tests
just fmt-check          # Check formatting
just fmt-write          # Auto-format code
just full-check         # Run all quality checks (linting + formatting)
just coverage           # Generate coverage report
just gas-report         # Generate gas usage report
```

### 🎨 Pre-commit Hooks

Automatic code formatting and linting on every commit:

- Solidity files: Auto-formatted with `forge fmt` and linted with `solhint`
- JSON/Markdown/YAML: Auto-formatted with `prettier`

Configured via `.lintstagedrc.js` and runs via Husky.

### 📊 Advanced Foundry Profiles

Multiple profiles for different use cases:

```sh
# Default - Standard development
forge build

# Lite - Fast iteration (no optimizer, low fuzz runs)
FOUNDRY_PROFILE=lite forge test

# Optimized - Production builds (1M optimizer runs, via-ir)
FOUNDRY_PROFILE=optimized forge build

# Test-optimized - Test production builds without recompiling
FOUNDRY_PROFILE=test-optimized forge test

# CI - High fuzz runs for continuous integration
FOUNDRY_PROFILE=ci forge test
```

See `foundry.toml` for detailed profile configurations.

### 🌐 Multi-Chain Support

Pre-configured RPC endpoints for 15+ networks:

- Mainnets: Ethereum, Arbitrum, Optimism, Base, Polygon, BSC, and more
- Testnets: Sepolia, Base Sepolia, Optimism Sepolia, Arbitrum Sepolia

Easy to extend with your own RPC providers.

## Usage

### Build

Compile contracts:

```sh
just build
```

Build with specific profile:

```sh
FOUNDRY_PROFILE=optimized forge build
```

### Clean

Delete build artifacts:

```sh
just clean
```

### Test

Run all tests:

```sh
just test
```

Run tests with gas reporting:

```sh
just gas-report
```

Run specific test:

```sh
forge test --match-test testFoo
```

### Coverage

Generate coverage report:

```sh
just coverage
```

### Format

Check formatting:

```sh
just fmt-check
```

Auto-format all code:

```sh
just fmt-write
```

### Quality Checks

Run all quality checks (linting + formatting):

```sh
just full-check
```

Run specific checks:

```sh
just solhint-check      # Solidity linting
just fmt-check          # Solidity formatting
just prettier-check     # JSON/Markdown/YAML formatting
```

### Deploy

Deploy to local Anvil:

```sh
forge script scripts/solidity/Deploy.s.sol --broadcast --fork-url http://localhost:8545
```

For testnet/mainnet deployment, see the [Solidity Scripting tutorial](https://getfoundry.sh/guides/scripting-with-solidity/).

## Project Structure

```
foundry-template/
├── scripts/
│   ├── bash/
│   │   └── prepare-artifacts.sh    # Build production artifacts
│   └── solidity/
│       ├── Base.s.sol              # Base deployment script
│       └── Deploy.s.sol            # Example deployment
├── src/
│   └── Foo.sol                     # Example contract
├── tests/
│   └── Foo.t.sol                   # Example tests
├── .husky/
│   └── pre-commit                  # Git hook
├── foundry.toml                    # Foundry configuration
├── justfile                        # Just command definitions
├── .lintstagedrc.js               # Pre-commit linting config
└── package.json                    # Dependencies
```

## Configuration Files

### Extending Configurations

The template uses devkit configurations by default. You can override as needed:

**Solhint (Solidity linting):**

Edit `.solhint.json` to customize Solidity linting rules.

**Prettier (formatting):**

The template uses Prettier from devkit for JSON, Markdown, and YAML files. Solidity files are formatted with `forge fmt`.

**Foundry:**

Edit `foundry.toml` directly for project-specific settings.

## GitHub Actions

The template includes a production-ready CI/CD workflow:

- ✅ Lint checks (Solidity + Prettier)
- ✅ Build with artifact caching
- ✅ Comprehensive testing
- ✅ Coverage reporting (Codecov)
- ✅ Concurrency control

See `.github/workflows/ci.yml`.

## Environment Variables

Copy `.env.example` to `.env` and fill in:

```sh
# API Keys
ETHERSCAN_API_KEY=
ARBISCAN_API_KEY=

# Deployment
DEPLOYER_PRIVATE_KEY=
```

## Installing Dependencies

This template uses npm packages instead of git submodules for better scalability.

**Install a dependency:**

```sh
bun install dependency-name

# From GitHub
bun install github:username/repo-name
```

**Add remapping:**

```txt
# remappings.txt
dependency-name=node_modules/dependency-name
```

Example: OpenZeppelin Contracts is pre-installed and remapped.

## Updating Devkit

Get latest devkit features:

```sh
bun update @credit-cooperative/devkit
```

This updates all shared configurations and Just recipes automatically.

## Writing Tests

Tests inherit from `forge-std/Test.sol`:

```solidity
import { Test } from "forge-std/Test.sol";

contract MyTest is Test {
    function testExample() public {
        assertTrue(true);
    }
}
```

Run with verbosity:

```sh
forge test -vvv
```

See the example in `tests/Foo.t.sol` for unit, fuzz, and fork test patterns.

## Troubleshooting

### "just: command not found"

Install Just:

```sh
# macOS
brew install just

# Linux
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash
```

### Pre-commit hooks not running

Re-initialize Husky:

```sh
bun run setup
```

### Import resolution issues

Ensure remappings are correct:

```sh
forge remappings
```

## Related Projects

- [@credit-cooperative/devkit](https://www.npmjs.com/package/@credit-cooperative/devkit) - Shared configuration and tooling
- [foundry-rs/forge-template](https://github.com/foundry-rs/forge-template) - Official Foundry template
- [PaulRBerg/foundry-template](https://github.com/PaulRBerg/foundry-template) - Original inspiration

## Contributing

We welcome contributions! Please:

1. Run `just fmt-write` before committing
2. Ensure all tests pass: `just test`
3. Follow existing code style

## License

This project is licensed under MIT.

## Credits

Built with ❤️ by [Credit Cooperative](https://creditcoop.xyz)

Inspired by [Sablier](https://sablier.com)'s production infrastructure.
