// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

interface IBondingCurve {
    /// @notice Buy `token_` with BNB. Sends purchased tokens to msg.sender.
    ///         May refund excess BNB (near migration cap) to msg.sender.
    function buy(address token_, uint256 minOut, uint256 deadline) external payable;

    /// @notice Sell `amountIn` of `token_` back to the curve.
    ///         Does transferFrom(msg.sender, address(this), amountIn) internally.
    ///         Sends net BNB to msg.sender.
    function sell(address token_, uint256 amountIn, uint256 minBNBOut, uint256 deadline) external;
}

/**
 * @title  OneMEMEAdapter
 * @notice Adapter for trading tokens on the OneMEME launchpad bonding curve
 *         (pre-migration only — once a token migrates to a DEX, use a V2/V3 adapter).
 *
 *         Only two directions are supported:
 *           BNB  → Token   (tokenIn  == address(0))   buy on bonding curve
 *           Token → BNB    (tokenOut == address(0))   sell on bonding curve
 *
 * ─── Data encoding (offchain aggregator) ────────────────────────────────────
 *
 *   bytes adapterData = abi.encode(address token, uint256 deadline)
 *
 *   token    The specific launchpad token being bought or sold.
 *            Must match tokenIn on sells and tokenOut on buys.
 *
 *   deadline Unix timestamp forwarded to the bonding curve's own deadline check.
 *            Set to block.timestamp + buffer at quote time (e.g. + 60 seconds).
 *            The aggregator enforces an outer deadline; this provides an inner
 *            guard at the BC level consistent with V2 adapter behaviour.
 *
 * ─── Buy flow (BNB → Token) ──────────────────────────────────────────────────
 *
 *   1. Aggregator forwards net BNB as msg.value to execute().
 *   2. Adapter calls BC.buy{value: amountIn}(token, minOut, deadline).
 *   3. BC sends purchased tokens to this adapter (msg.sender) and may refund
 *      excess BNB (near migration cap) to this adapter.
 *   4. Adapter measures the token delta, asserts >= minOut, forwards tokens to `to`.
 *   5. Any BNB refund held by the adapter is forwarded to `to`.
 *
 * ─── Sell flow (Token → BNB) ─────────────────────────────────────────────────
 *
 *   1. Aggregator pre-transfers net tokens to this adapter before calling execute().
 *   2. Adapter reads actualIn via _selfBalance(tokenIn) — FoT-safe.
 *   3. Adapter approves the BC for actualIn, calls BC.sell(token, actualIn, minOut, deadline).
 *   4. BC transfersFrom(adapter → BC) and sends net BNB back to this adapter (msg.sender).
 *   5. Adapter resets approval, forwards all received BNB to `to`.
 *
 * ─── Suggested registry ID ───────────────────────────────────────────────────
 *
 *   keccak256("ONEMEME_BC")
 */
contract OneMEMEAdapter is BaseAdapter {

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice The OneMEME BondingCurve contract.
    address public immutable bondingCurve;

    // ── Errors ───────────────────────────────────────────────────────────────

    error UnsupportedDirection();   // Token→Token or BNB→BNB not supported on bonding curve
    error TokenMismatch();          // adapterData.token does not match tokenIn/tokenOut

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address aggregator_, address bondingCurve_)
        BaseAdapter(aggregator_)
    {
        if (bondingCurve_ == address(0)) revert ZeroAddress();
        bondingCurve = bondingCurve_;
    }

    function name() external pure override returns (string memory) {
        return "OneMEME Bonding Curve";
    }

    // ── execute ──────────────────────────────────────────────────────────────

    /**
     * @dev Pre-condition (buy):  amountIn BNB is in msg.value (forwarded by aggregator).
     * @dev Pre-condition (sell): amountIn of tokenIn is already in this adapter.
     */
    function execute(
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata data
    ) external payable override onlyAggregator returns (uint256 amountOut) {
        (address token, uint256 deadline) = abi.decode(data, (address, uint256));

        if (tokenIn == address(0) && tokenOut != address(0)) {
            // ── BNB → Token (buy) ─────────────────────────────────────────────
            if (tokenOut != token) revert TokenMismatch();
            amountOut = _executeBuy(token, amountIn, minOut, deadline, to);

        } else if (tokenIn != address(0) && tokenOut == address(0)) {
            // ── Token → BNB (sell) ────────────────────────────────────────────
            if (tokenIn != token) revert TokenMismatch();
            _executeSell(token, minOut, deadline, to);
            // amountOut is 0 — BNB is delivered directly to `to` (untrackable from here)

        } else {
            // Token→Token and BNB→BNB are not possible on a bonding curve
            revert UnsupportedDirection();
        }
    }

    // ── Internal: buy ────────────────────────────────────────────────────────

    function _executeBuy(
        address token,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address to
    ) internal returns (uint256 tokensReceived) {
        uint256 balBefore = _selfBalance(token);

        // BC sends purchased tokens to msg.sender (this adapter); may refund excess BNB here too.
        IBondingCurve(bondingCurve).buy{value: amountIn}(token, minOut, deadline);

        tokensReceived = _selfBalance(token) - balBefore;
        if (tokensReceived < minOut) revert InsufficientOutput();

        // Forward tokens to the final recipient.
        _safeTransfer(token, to, tokensReceived);

        // Forward any BNB refund (excess near migration cap) to the recipient.
        uint256 refund = address(this).balance;
        if (refund > 0) {
            _sendNative(to, refund);
        }
    }

    // ── Internal: sell ───────────────────────────────────────────────────────

    function _executeSell(
        address token,
        uint256 minBNBOut,
        uint256 deadline,
        address to
    ) internal {
        // Use actual held balance — FoT-safe (adapter may have received less than amountIn).
        uint256 actualIn = _selfBalance(token);

        // BC.sell does transferFrom(msg.sender, BC, actualIn) internally.
        _approve(token, bondingCurve, actualIn);

        uint256 bnbBefore = address(this).balance;
        IBondingCurve(bondingCurve).sell(token, actualIn, minBNBOut, deadline);
        _resetApproval(token, bondingCurve);

        // Forward all BNB received from the bonding curve to the recipient.
        uint256 received = address(this).balance - bnbBefore;
        if (received > 0) {
            _sendNative(to, received);
        }
    }
}
