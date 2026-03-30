// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./IVault.sol";

/**
 * @title  ICreatorVault
 * @notice Extends IVault for creator-allocation management.
 *
 * The CreatorVault manages:
 *  - Creator token distributions from launchpad sales
 *  - Creator allocation vesting and releases
 *  - Creator fund management and transfers
 *  - Payouts to multiple creators
 *
 * Uses 2-of-3 multisig to ensure secure, authorized transfers.
 */
interface ICreatorVault is IVault {
    // CreatorVault-specific events and functions can be added here as needed
}
