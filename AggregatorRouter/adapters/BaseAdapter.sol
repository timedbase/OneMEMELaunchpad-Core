// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "../interfaces/IAdapter.sol";

/**
 * @title  BaseAdapter
 * @notice Abstract base contract for all OneMEME aggregator adapters.
 *
 * Security model
 * ──────────────
 * The `onlyAggregator` modifier is the single most critical guard in the
 * adapter system. By the time execute() is called, the aggregator has
 * already transferred net tokens (or BNB) to this adapter's address.
 * Without this guard, any caller could trigger execute() and drain those
 * funds. Only the registered OneMEMEAggregator address may call execute().
 *
 * To add a new DEX:
 *   1. Write a concrete adapter that extends this base.
 *   2. Implement execute() and name().
 *   3. Deploy the adapter with the aggregator's address as constructor arg.
 *   4. Call aggregator.registerAdapter(id, adapterAddress) — no other changes needed.
 */
abstract contract BaseAdapter is IAdapter {

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice The OneMEMEAggregator address that is permitted to call execute().
    address public immutable aggregator;

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotAggregator();
    error ZeroAddress();
    error TransferFailed();
    error NativeSendFailed();
    error InsufficientOutput();

    // ── Modifier ─────────────────────────────────────────────────────────────

    modifier onlyAggregator() {
        if (msg.sender != aggregator) revert NotAggregator();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address aggregator_) {
        if (aggregator_ == address(0)) revert ZeroAddress();
        aggregator = aggregator_;
    }

    /// @dev Receives BNB from WBNB.withdraw() during native-out swaps.
    receive() external payable {}

    // ── Internal Helpers ─────────────────────────────────────────────────────

    /**
     * @dev Approve `spender` for exactly `amount` of `token`.
     *      Resets to 0 first to handle USDT-style tokens that reject
     *      non-zero → non-zero approvals.
     */
    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, 0)
        );
        if (!ok) revert TransferFailed();
        (ok,) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        if (!ok) revert TransferFailed();
    }

    /**
     * @dev Returns this adapter's current balance of `token`.
     *      Used to measure real received amounts — important for fee-on-transfer
     *      tokens where the amount held may be less than what was sent.
     */
    function _selfBalance(address token) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        bal = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    /**
     * @dev Returns the `token` balance of an external `account`.
     *      Used to track output amounts at the recipient address for V2 swaps.
     */
    function _balanceOf(address token, address account) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        bal = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    /**
     * @dev Reset the allowance for `spender` to zero.
     *      Called after every DEX swap to ensure no residual approval remains.
     *      A lingering non-zero allowance on a DEX router is an unnecessary attack
     *      surface — if the router is later exploited, outstanding allowances can
     *      be drained. Resetting after each swap removes that surface entirely.
     */
    function _resetApproval(address token, address spender) internal {
        (bool ok,) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, 0)
        );
        if (!ok) revert TransferFailed();
    }

    /// @dev Low-level ERC-20 transfer (handles tokens that return nothing).
    function _safeTransfer(address token, address to_, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to_, amount)  // transfer(address,uint256)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /// @dev Send native BNB to `to_`. Reverts if the recipient cannot receive it.
    function _sendNative(address to_, uint256 amount) internal {
        (bool ok,) = to_.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }

    /**
     * @dev Unwrap `amount` of WBNB held by this adapter and forward the
     *      resulting native BNB to `to_`.
     *      Used by V3 adapters for Token → native BNB output.
     */
    function _unwrapAndSend(address wbnb, uint256 amount, address to_) internal {
        (bool ok,) = wbnb.call(abi.encodeWithSignature("withdraw(uint256)", amount));
        if (!ok) revert TransferFailed();
        _sendNative(to_, amount);
    }
}
