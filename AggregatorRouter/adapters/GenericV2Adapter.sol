// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

interface IV2Router {
    function WETH() external pure returns (address);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256          amountIn,
        uint256          amountOutMin,
        address[] calldata path,
        address          to,
        uint256          deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256          amountOutMin,
        address[] calldata path,
        address          to,
        uint256          deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256          amountIn,
        uint256          amountOutMin,
        address[] calldata path,
        address          to,
        uint256          deadline
    ) external;
}

/**
 * @title  GenericV2Adapter
 * @notice Adapter for any Uniswap V2-compatible DEX:
 *         PancakeSwap V2, Uniswap V2, BiSwap, BabySwap, ApeSwap, etc.
 *         Deploy one instance per DEX by injecting a different `router_`.
 *
 * ─── Data encoding (offchain aggregator) ────────────────────────────────────
 *
 *   bytes data = abi.encode(address[] path, uint256 deadline)
 *
 *   path     Ordered token addresses. Use the real WBNB address for native BNB
 *            legs (obtainable from router.WETH()). The path length determines
 *            single-hop (length == 2) vs multi-hop (length >= 3) automatically.
 *
 *   deadline Unix timestamp; the DEX router reverts if block.timestamp > deadline.
 *            The offchain aggregator should set this to block.timestamp + buffer
 *            at quote time (e.g. + 60 seconds).
 *
 * ─── Native BNB convention ────────────────────────────────────────────────────
 *
 *   tokenIn  == address(0)  →  native BNB input.
 *                              Aggregator forwarded amountIn as msg.value.
 *                              path[0] must equal router.WETH().
 *
 *   tokenOut == address(0)  →  native BNB output.
 *                              V2 router delivers BNB directly to `to`.
 *                              path[last] must equal router.WETH().
 *
 * ─── Return value ─────────────────────────────────────────────────────────────
 *
 *   V2 *SupportingFeeOnTransferTokens variants do not return amountOut.
 *   The DEX router enforces amountOutMin internally; execute() returns the
 *   measured token delta at `to` for token outputs, and 0 for BNB outputs.
 *
 * ─── Suggested registry IDs ───────────────────────────────────────────────────
 *
 *   keccak256("PANCAKE_V2")   router = 0x10ED43C718714eb63d5aA57B78B54704E256024E
 *   keccak256("UNISWAP_V2")   router = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24
 *   keccak256("BISWAP")       router = 0x3a6d8cA21a1a8D877Cb20E2E86a6F5F14f2b6e5B
 */
contract GenericV2Adapter is BaseAdapter {

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice The Uniswap V2-compatible router this adapter targets.
    address public immutable dexRouter;

    /// @notice Wrapped native token address (WBNB/WETH) read from the router at construction.
    address public immutable weth;

    string private _name;

    // ── Errors ───────────────────────────────────────────────────────────────

    error InvalidPath();

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address aggregator_, address router_, string memory name_)
        BaseAdapter(aggregator_)
    {
        if (router_ == address(0)) revert ZeroAddress();
        dexRouter = router_;
        weth      = IV2Router(router_).WETH();
        _name     = name_;
    }

    function name() external view override returns (string memory) { return _name; }

    // ── execute ──────────────────────────────────────────────────────────────

    /**
     * @dev Pre-condition: amountIn of tokenIn is already in this adapter
     *      (transferred by the aggregator), or BNB is in msg.value.
     */
    function execute(
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata data
    ) external payable override onlyAggregator returns (uint256 amountOut) {
        (address[] memory path, uint256 deadline) = abi.decode(data, (address[], uint256));

        // Validate path length and that the endpoints match the declared tokenIn/tokenOut.
        // address(0) legs must use the wrapped native token (weth) inside the path.
        if (path.length < 2) revert InvalidPath();
        address expectedFirst = tokenIn  == address(0) ? weth : tokenIn;
        address expectedLast  = tokenOut == address(0) ? weth : tokenOut;
        if (path[0]               != expectedFirst) revert InvalidPath();
        if (path[path.length - 1] != expectedLast)  revert InvalidPath();

        if (tokenIn == address(0)) {
            // ── Native BNB → Token(s) ─────────────────────────────────────────
            uint256 balBefore = _balanceOf(path[path.length - 1], to);

            IV2Router(dexRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{
                value: amountIn
            }(minOut, path, to, deadline);

            amountOut = _balanceOf(path[path.length - 1], to) - balBefore;
            // Independent adapter-level slippage guard: catches fee-on-transfer output
            // tokens where the DEX's gross check passes but `to` received less after deduction.
            if (amountOut < minOut) revert InsufficientOutput();

        } else if (tokenOut == address(0)) {
            // ── Token(s) → Native BNB ─────────────────────────────────────────
            // Use _selfBalance: if tokenIn is fee-on-transfer, the adapter received
            // less than amountIn from the aggregator. Passing amountIn would cause
            // the DEX transferFrom to fail on insufficient balance.
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);

            IV2Router(dexRouter).swapExactTokensForETHSupportingFeeOnTransferTokens(
                actualIn, minOut, path, to, deadline
            );
            _resetApproval(tokenIn, dexRouter);

            // BNB output is sent atomically to `to` by the DEX — not trackable here.
            amountOut = 0;

        } else {
            // ── Token(s) → Token(s) ───────────────────────────────────────────
            // Same FoT reasoning: use actual held balance, not the nominal amountIn.
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);
            uint256 balBefore = _balanceOf(tokenOut, to);

            IV2Router(dexRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                actualIn, minOut, path, to, deadline
            );
            _resetApproval(tokenIn, dexRouter);

            amountOut = _balanceOf(tokenOut, to) - balBefore;
            // Independent adapter-level slippage guard: catches fee-on-transfer output
            // tokens where the DEX's gross check passes but `to` received less after deduction.
            if (amountOut < minOut) revert InsufficientOutput();
        }
    }
}
