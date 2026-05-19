// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev ERC20 that does not return a bool from transfer/transferFrom (e.g. USDT on mainnet).
/// Uses low-level storage to avoid inheriting OZ's ERC20 which always returns bool.
contract NoReturnERC20 {
    string public name = "NoReturn";
    string public symbol = "NRT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @dev Transfers tokens but returns NOTHING — mimics USDT on mainnet.
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    /// @dev TransferFrom with no return value — the core edge case this mock tests.
    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        require(balanceOf[from] >= amount, "insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
