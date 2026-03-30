// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./IVault.sol";

/**
 * @title  IMaintenanceVault
 * @notice Extends IVault for platform maintenance operations.
 *
 * The MaintenanceVault manages:
 *  - Platform development and infrastructure costs
 *  - Maintenance and security fund management
 *  - Operational expenses and payouts
 *  - Emergency fund allocations
 *  - Upgrades and infrastructure improvements
 *
 * Uses 2-of-3 multisig to ensure secure, authorized fund management and protect
 * against single-point-of-failure in critical platform operations.
 */
interface IMaintenanceVault is IVault {
    // MaintenanceVault-specific events and functions can be added here as needed
}
