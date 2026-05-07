// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPermit2} from "../../src/interfaces/IPermit2.sol";

/**
 * @notice Mock Permit2 for unit tests — skips EIP-712 signature verification
 *         and simply executes the token transfer directly.
 */
contract MockPermit2 {
    function permitTransferFrom(
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata /* signature */
    ) external {
        IERC20Minimal(permit.permitted.token).transferFrom(
            owner,
            transferDetails.to,
            transferDetails.requestedAmount
        );
    }
}

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
