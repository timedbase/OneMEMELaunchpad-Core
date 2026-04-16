// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

/// @dev Compatible with PancakeSwap V3 SmartRouter and Uniswap V3 SwapRouter02.
///      Neither uses `deadline` inside the struct (moved outside in SwapRouter02).
///      Both accept native ETH/BNB when tokenIn == WETH9 and msg.value >= amountIn.
interface IV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;            // pool fee tier: 100, 500, 2500, 10000
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96; // 0 = no price limit
    }

    struct ExactInputParams {
        bytes   path;           // abi.encodePacked(tokenA, fee, tokenB [, fee, tokenC ...])
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);

    function exactInput(ExactInputParams calldata params)
        external payable returns (uint256 amountOut);
}

/**
 * @title  GenericV3Adapter
 * @notice Adapter for any Uniswap V3-compatible DEX:
 *         PancakeSwap V3 SmartRouter, Uniswap V3 SwapRouter02, etc.
 *         Deploy one instance per DEX by injecting a different `router_`.
 *
 * ─── Data encoding (offchain aggregator) ────────────────────────────────────
 *
 *   bytes data = abi.encode(bool isMultiHop, bytes innerData)
 *
 *   Single-hop (isMultiHop == false):
 *     innerData = abi.encode(uint24 poolFee, uint160 sqrtPriceLimitX96)
 *     poolFee           Pool fee tier in hundredths of a bip. BSC: 100, 500, 2500, 10000.
 *     sqrtPriceLimitX96 Price limit. Pass 0 for no limit (standard for aggregators).
 *
 *   Multi-hop (isMultiHop == true):
 *     innerData = abi.encodePacked(tokenA, uint24(fee0), tokenB, uint24(fee1), tokenC ...)
 *     This is the raw V3 packed path. Minimum 43 bytes (20 + 3 + 20).
 *     Each additional hop adds 23 bytes (3 + 20).
 *     For BNB legs use the real WBNB address inside the path.
 *
 * ─── Native BNB convention ────────────────────────────────────────────────────
 *
 *   tokenIn  == address(0)  →  native BNB input (aggregator sends msg.value == amountIn).
 *                              The V3 router wraps BNB → WBNB automatically when the
 *                              effective tokenIn is WBNB and ETH is attached.
 *
 *   tokenOut == address(0)  →  native BNB output.
 *                              Adapter receives WBNB from the router, then unwraps
 *                              and forwards native BNB to `to`.
 *
 * ─── Suggested registry IDs ───────────────────────────────────────────────────
 *
 *   keccak256("PANCAKE_V3")   router = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4  (BSC)
 *   keccak256("UNISWAP_V3")   router = 0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2  (BSC)
 */
contract GenericV3Adapter is BaseAdapter {

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice The V3-compatible router this adapter targets.
    address public immutable dexRouter;

    /// @notice Wrapped native token (WBNB on BSC) used for native BNB swaps.
    address public immutable wbnb;

    string private _name;

    // ── Errors ───────────────────────────────────────────────────────────────

    error InvalidPath();

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address aggregator_, address router_, address wbnb_, string memory name_)
        BaseAdapter(aggregator_)
    {
        if (router_ == address(0) || wbnb_ == address(0)) revert ZeroAddress();
        dexRouter = router_;
        wbnb      = wbnb_;
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
        (bool isMultiHop, bytes memory inner) = abi.decode(data, (bool, bytes));

        if (!isMultiHop) {
            amountOut = _executeSingle(tokenIn, amountIn, tokenOut, minOut, to, inner);
        } else {
            // Minimum: addr(20) + fee(3) + addr(20) = 43 bytes.
            // Each additional hop is fee(3) + addr(20) = 23 bytes.
            // Total must satisfy: (length - 20) % 23 == 0.
            if (inner.length < 43 || (inner.length - 20) % 23 != 0) revert InvalidPath();
            amountOut = _executeMulti(tokenIn, amountIn, tokenOut, minOut, to, inner);
        }
    }

    // ── Internal: single-hop ─────────────────────────────────────────────────

    function _executeSingle(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        address to,
        bytes memory inner
    ) internal returns (uint256 amountOut) {
        (uint24 poolFee, uint160 sqrtPriceLimit) = abi.decode(inner, (uint24, uint160));

        if (tokenIn == address(0)) {
            // ── Native BNB → Token ────────────────────────────────────────────
            // V3 router wraps BNB automatically when tokenIn == wbnb and msg.value is set
            amountOut = IV3Router(dexRouter).exactInputSingle{value: amountIn}(
                IV3Router.ExactInputSingleParams({
                    tokenIn:           wbnb,
                    tokenOut:          tokenOut,
                    fee:               poolFee,
                    recipient:         to,
                    amountIn:          amountIn,
                    amountOutMinimum:  minOut,
                    sqrtPriceLimitX96: sqrtPriceLimit
                })
            );

        } else if (tokenOut == address(0)) {
            // ── Token → Native BNB ────────────────────────────────────────────
            // Route WBNB output to this adapter, then unwrap and forward BNB to `to`.
            // Use _selfBalance: if tokenIn is FoT, the adapter holds less than amountIn.
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);

            amountOut = IV3Router(dexRouter).exactInputSingle(
                IV3Router.ExactInputSingleParams({
                    tokenIn:           tokenIn,
                    tokenOut:          wbnb,
                    fee:               poolFee,
                    recipient:         address(this),
                    amountIn:          actualIn,
                    amountOutMinimum:  minOut,
                    sqrtPriceLimitX96: sqrtPriceLimit
                })
            );
            _resetApproval(tokenIn, dexRouter);
            _unwrapAndSend(wbnb, amountOut, to);

        } else {
            // ── Token → Token ─────────────────────────────────────────────────
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);

            amountOut = IV3Router(dexRouter).exactInputSingle(
                IV3Router.ExactInputSingleParams({
                    tokenIn:           tokenIn,
                    tokenOut:          tokenOut,
                    fee:               poolFee,
                    recipient:         to,
                    amountIn:          actualIn,
                    amountOutMinimum:  minOut,
                    sqrtPriceLimitX96: sqrtPriceLimit
                })
            );
            _resetApproval(tokenIn, dexRouter);
        }
    }

    // ── Internal: multi-hop ──────────────────────────────────────────────────

    function _executeMulti(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        address to,
        bytes memory v3Path       // raw abi.encodePacked path — already length-checked by caller
    ) internal returns (uint256 amountOut) {
        if (tokenIn == address(0)) {
            // ── Native BNB → Token(s) ─────────────────────────────────────────
            // V3 router wraps BNB when the path starts with WBNB and ETH is attached
            amountOut = IV3Router(dexRouter).exactInput{value: amountIn}(
                IV3Router.ExactInputParams({
                    path:             v3Path,
                    recipient:        to,
                    amountIn:         amountIn,
                    amountOutMinimum: minOut
                })
            );

        } else if (tokenOut == address(0)) {
            // ── Token(s) → Native BNB ─────────────────────────────────────────
            // Path must end with WBNB; adapter receives WBNB then unwraps and sends BNB.
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);

            amountOut = IV3Router(dexRouter).exactInput(
                IV3Router.ExactInputParams({
                    path:             v3Path,
                    recipient:        address(this),
                    amountIn:         actualIn,
                    amountOutMinimum: minOut
                })
            );
            _resetApproval(tokenIn, dexRouter);
            _unwrapAndSend(wbnb, amountOut, to);

        } else {
            // ── Token(s) → Token(s) ───────────────────────────────────────────
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);

            amountOut = IV3Router(dexRouter).exactInput(
                IV3Router.ExactInputParams({
                    path:             v3Path,
                    recipient:        to,
                    amountIn:         actualIn,
                    amountOutMinimum: minOut
                })
            );
            _resetApproval(tokenIn, dexRouter);
        }
    }
}
