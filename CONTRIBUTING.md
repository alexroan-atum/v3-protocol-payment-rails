# Contributing

Feel free to dive in! [Open](../../issues/new) an issue or submit a PR. For any informal concerns or feedback, please reach out to the Credit Cooperative team.

Contributions are welcome by anyone interested in improving this template, adding new features, writing better tests, or optimizing for gas efficiency.

## Prerequisites

You'll need the following tools installed:

- [Foundry](https://github.com/foundry-rs/foundry) >= 0.2.0 (EVM development framework)
- [Bun](https://bun.sh) >= 1.0 (package manager)
- [Just](https://github.com/casey/just) >= 1.0 (command runner)
- [Ni](https://github.com/antfu-collective/ni) (package manager resolver - installed via `npm install -g @antfu/ni`)
- [Node.js](https://nodejs.org) >= 20 (JavaScript runtime)

In addition, familiarity with [Solidity](https://soliditylang.org) is required.

## Set Up

Clone this repository:

```shell
git clone git@github.com:credit-cooperative/foundry-template.git
cd foundry-template
```

Install dependencies:

```shell
bun install
```

Initialize pre-commit hooks:

```shell
bun run setup
```

Build the contracts:

```shell
just build
```

Run tests to verify everything works:

```shell
just test
```

See all available commands:

```shell
just --list
```

Now you can start making changes!

## Development Workflow

### Making Changes

1. Create a new branch from `main`:

   ```shell
   git checkout -b feature/your-feature-name
   ```

2. Make your changes following the [Code Style Standards](#code-style-standards)

3. Test your changes:

   ```shell
   just test
   just coverage  # Ensure coverage doesn't decrease
   ```

4. Pre-commit hooks will automatically run when you commit:
   - Solidity files: Auto-formatted with `forge fmt` and linted with `solhint`
   - JSON/Markdown/YAML: Auto-formatted with `prettier`

5. If pre-commit fails, fix the issues and commit again:
   ```shell
   just fmt-write  # Auto-fix formatting issues
   git add .
   git commit -m "your commit message"
   ```

### Pre-commit Hooks

This template uses Husky and lint-staged to enforce code quality:

**What runs automatically on commit:**

- `forge fmt` - Formats Solidity code
- `solhint` - Lints Solidity for errors and style issues
- `prettier` - Formats JSON, Markdown, and YAML files

**If hooks fail:**

```shell
# Check what's wrong
just fmt-check      # See formatting issues
just lint           # See linting issues

# Auto-fix
just fmt-write      # Fix formatting
```

**Bypassing hooks (not recommended):**

```shell
git commit --no-verify -m "message"
```

Only bypass hooks if absolutely necessary and ensure manual verification.

## Code Style Standards

### Solidity

Follow these conventions:

1. **Formatting:**
   - Use `forge fmt` (runs automatically on commit)
   - 4-space indentation
   - 120 character line length
   - Double quotes for strings

2. **Naming Conventions:**
   - Contracts: `PascalCase`
   - Functions: `camelCase`
   - Variables: `camelCase`
   - Constants: `SCREAMING_SNAKE_CASE`
   - Internal/Private: prefix with underscore `_functionName`

3. **Documentation:**
   - All public/external functions must have NatSpec comments
   - Include `@notice`, `@param`, `@return` as appropriate
   - Complex logic should have inline comments

4. **Example:**
   ```solidity
   /// @notice Transfers tokens from sender to recipient
   /// @param recipient The address receiving tokens
   /// @param amount The amount of tokens to transfer
   /// @return success Whether the transfer succeeded
   function transfer(address recipient, uint256 amount) external returns (bool success) {
       // Implementation
   }
   ```

### Gas Optimization

- Use `unchecked` blocks where overflow is impossible
- Cache storage reads in local variables
- Use `calldata` instead of `memory` for read-only function parameters
- Prefer `uint256` over smaller uints (unless packing)

### Testing

- Test file names: `ContractName.t.sol`
- Test contract names: `ContractNameTest`
- Test function names: `test_FunctionName_Condition_ExpectedOutcome`
- Use descriptive names that explain what's being tested

**Example:**

```solidity
contract FooTest is Test {
    function test_transfer_RevertsWhen_InsufficientBalance() public {
        // Test implementation
    }
}
```

## Testing Requirements

### Before Submitting a PR

Ensure all tests pass and coverage is maintained:

```shell
# Run all tests
just test

# Run specific profile
FOUNDRY_PROFILE=test-optimized forge test

# Generate coverage report
just coverage

# Generate gas report
just gas-report
```

### Writing New Tests

1. **Unit Tests:** Test individual functions in isolation
2. **Integration Tests:** Test interactions between contracts
3. **Fuzz Tests:** Use Foundry's fuzzing for edge cases
4. **Fork Tests:** Test against mainnet state when relevant

### Test Coverage

- Maintain or improve coverage percentage
- Critical paths must have 100% coverage
- Include both success and failure cases
- Test edge cases and boundary conditions

## Pull Request Process

### Before Submitting

Verify your changes pass all checks:

```shell
# 1. Format code
just fmt-write

# 2. Run linters
just lint

# 3. Run all tests
just test

# 4. Check coverage
just coverage

# 5. Run gas report (if modifying contracts)
just gas-report
```

### PR Requirements

When submitting a pull request, ensure:

- [ ] All tests pass
- [ ] Code coverage remains the same or increases
- [ ] All lint checks pass (`just lint`)
- [ ] Code is formatted (`just fmt-check`)
- [ ] New code is thoroughly commented with NatSpec
- [ ] Commit messages are clear and descriptive
- [ ] PR description explains what and why
- [ ] If changing contracts:
  - [ ] Gas snapshots show improvement (or acceptable trade-off)
  - [ ] New tests cover all new code paths
  - [ ] Edge cases are tested

### PR Template

```markdown
## Description

Brief description of changes

## Type of Change

- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing

- [ ] All existing tests pass
- [ ] Added new tests for new features
- [ ] Coverage maintained or improved

## Gas Impact

- Snapshot before: X gas
- Snapshot after: Y gas
- Change: +/- Z gas

## Checklist

- [ ] Code follows style guidelines
- [ ] Self-reviewed the code
- [ ] Commented complex logic
- [ ] Updated documentation
```

## Commit Message Convention

Use clear, descriptive commit messages:

**Format:**

```
type: brief description

Longer description if needed
```

**Types:**

- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `docs`: Documentation changes
- `chore`: Maintenance tasks
- `perf`: Performance improvements

**Examples:**

```
feat: add multi-signature support to deployment script

fix: resolve reentrancy vulnerability in withdraw function

test: add fuzz tests for edge cases in transfer logic

docs: update README with new deployment instructions
```

## Environment Variables

### Local Development

Create a `.env` file from `.env.example`:

```shell
cp .env.example .env
```

Fill in the required values:

```shell
# API Keys for contract verification
ETHERSCAN_API_KEY=your_key_here
ARBISCAN_API_KEY=your_key_here

# Deployment (use a test wallet!)
DEPLOYER_PRIVATE_KEY=your_private_key_here
```

**⚠️ Never commit `.env` files or expose private keys!**

### CI/CD

For fork testing in CI, add these secrets to your GitHub repository:

- `MAINNET_RPC_URL`: Get from [Alchemy](https://alchemy.com/)
- `CODECOV_TOKEN`: Get from [Codecov](https://codecov.io/) (for coverage reports)

## IDE Integration

### VSCode (Recommended)

Install these extensions for the best experience:

- [Solidity](https://marketplace.visualstudio.com/items?itemName=NomicFoundation.hardhat-solidity) - Syntax highlighting and IntelliSense
- [Prettier](https://marketplace.visualstudio.com/items?itemName=esbenp.prettier-vscode) - Code formatting
- [Even Better TOML](https://marketplace.visualstudio.com/items?itemName=tamasfe.even-better-toml) - TOML syntax support

The template includes `.vscode/settings.json` with recommended configurations.

## Troubleshooting

### Common Issues

**Pre-commit hooks fail:**

```shell
# Re-initialize Husky
bun run setup

# Make hooks executable
chmod +x .husky/pre-commit
```

**Just command not found:**

```shell
# macOS
brew install just

# Linux
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash
```

**Import resolution errors:**

```shell
# Verify remappings
forge remappings

# Rebuild
just clean
just build
```

**Tests failing after Foundry update:**

```shell
# Update Foundry to latest
foundryup

# Clear cache and rebuild
forge clean
forge build
```

## Getting Help

- **Issues:** Open an issue for bugs or feature requests
- **Discussions:** Start a discussion for questions or ideas
- **Discord:** Join Credit Cooperative's Discord for real-time help
- **Documentation:** Check the [README](./README.md) for usage instructions

## Code of Conduct

Be respectful and constructive in all interactions. We're here to build great things together!

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to Credit Cooperative's Foundry Template! 🚀
