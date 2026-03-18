// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

/// @notice Minimal interface every launchpad token must implement so the factory
///         can manage the bonding-curve phase and trigger DEX migration.
interface ILaunchpadToken {
    /// @notice Called by the BondingCurve at migration to exit the bonding phase
    ///         and enable normal DEX trading.  No-op on StandardToken; activates
    ///         taxes / reflection on TaxToken / ReflectionToken.
    function postMigrateSetup() external;

    // ── Metadata URI ──────────────────────────────────────────────────────
    /// @notice Returns the token's off-chain metadata URI (JSON with name,
    ///         description, image, website, etc.).  Empty string if unset.
    function metaURI() external view returns (string memory);

    /// @notice Update the metadata URI.  Callable only by the token owner.
    function setMetaURI(string calldata uri_) external;

    // ── ERC-20 surface the factory needs ──────────────────────────────────
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
