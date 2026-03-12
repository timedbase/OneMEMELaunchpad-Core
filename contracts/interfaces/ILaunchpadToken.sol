// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

/// @notice Minimal interface every launchpad token must implement so the factory
///         can manage the bonding-curve phase and trigger DEX migration.
interface ILaunchpadToken {
    /// @notice Called by the factory once trading has migrated to a DEX.
    ///         Sets the PancakeSwap pair address and router, then opens normal
    ///         fee/reflection logic.
    function enableTrading(address pair_, address router_) external;

    /// @notice Called once by the factory (at token creation) to deposit the
    ///         creator's allocation into the token contract and start the 12-month
    ///         linear vesting schedule.  The factory must have already transferred
    ///         `amount_` tokens to this contract before calling.
    function setupVesting(address creator_, uint256 amount_) external;

    // ── ERC-20 surface the factory needs ──────────────────────────────────
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
