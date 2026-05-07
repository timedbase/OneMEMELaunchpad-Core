// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  SafeTransfer
 * @notice Low-level token helpers that handle every non-standard ERC-20 variant:
 *         - tokens with no return value (USDT, BNB-pegged)
 *         - tokens that return false on failure
 *         - fee-on-transfer and rebasing (callers use balance-delta accounting)
 *
 * @dev    All functions use raw .call()/.staticcall() and manually decode the
 *         optional bool return value, matching OpenZeppelin SafeERC20 semantics
 *         without the OZ import overhead.
 */
library SafeTransfer {

    error TransferFailed();
    error ApproveFailed();

    // ERC-20 selectors cached as constants to save PUSH32 overhead.
    bytes4 private constant _TRANSFER      = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant _TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 private constant _APPROVE       = 0x095ea7b3; // approve(address,uint256)
    bytes4 private constant _BALANCE_OF    = 0x70a08231; // balanceOf(address)

    /// @notice ERC-20 transfer — handles tokens that return nothing.
    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(_TRANSFER, to, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /// @notice ERC-20 transferFrom — handles tokens that return nothing.
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(_TRANSFER_FROM, from, to, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /**
     * @notice ERC-20 approve — handles tokens that return nothing.
     * @dev    Callers are responsible for the USDT-safe reset-before-set pattern
     *         (call safeApprove(token, spender, 0) before a non-zero amount).
     */
    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(_APPROVE, spender, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert ApproveFailed();
    }

    /**
     * @notice Read token balance via staticcall.
     * @dev    Returns 0 on failure rather than reverting — callers handle zero-balance
     *         semantics (e.g. dust checks).
     */
    function balanceOf(address token, address account) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSelector(_BALANCE_OF, account)
        );
        bal = (ok && ret.length >= 32) ? abi.decode(ret, (uint256)) : 0;
    }
}
