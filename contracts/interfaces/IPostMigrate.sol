// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

/// @dev Implemented by TaxToken and ReflectionToken — exits bonding phase after liquidity is seeded.
interface IPostMigrate {
    function postMigrateSetup() external;
}
