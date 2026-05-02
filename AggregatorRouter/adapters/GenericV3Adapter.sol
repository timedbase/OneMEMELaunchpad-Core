// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

interface IV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title  GenericV3Adapter
 * @notice Adapter for any Uniswap V3-compatible DEX. Deploy one instance per DEX.
 *         adapterData = abi.encode(bool isMultiHop, bytes innerData)
 *         Single-hop: innerData = abi.encode(uint24 poolFee, uint160 sqrtPriceLimitX96)
 *         Multi-hop:  innerData = abi.encodePacked(tokenA, fee, tokenB [, fee, tokenC ...])
 *         address(0) = native BNB; use WBNB address inside paths.
 */
contract GenericV3Adapter is BaseAdapter {

    address public immutable dexRouter;
    address public immutable wbnb;

    string private _name;

    error InvalidPath();

    constructor(address aggregator_, address router_, address wbnb_, string memory name_)
        BaseAdapter(aggregator_)
    {
        if (router_ == address(0) || wbnb_ == address(0)) revert ZeroAddress();
        dexRouter = router_;
        wbnb      = wbnb_;
        _name     = name_;
    }

    function name() external view override returns (string memory) { return _name; }

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
            // V3 packed path: min 43 bytes (addr+fee+addr); each additional hop adds 23 bytes (fee+addr).
            if (inner.length < 43 || (inner.length - 20) % 23 != 0) revert InvalidPath();
            amountOut = _executeMulti(tokenIn, amountIn, tokenOut, minOut, to, inner);
        }
    }

    function _executeSingle(
        address tokenIn, uint256 amountIn, address tokenOut,
        uint256 minOut, address to, bytes memory inner
    ) internal returns (uint256 amountOut) {
        (uint24 poolFee, uint160 sqrtPriceLimit) = abi.decode(inner, (uint24, uint160));

        if (tokenIn == address(0)) {
            amountOut = IV3Router(dexRouter).exactInputSingle{value: amountIn}(
                IV3Router.ExactInputSingleParams({
                    tokenIn: wbnb, tokenOut: tokenOut, fee: poolFee,
                    recipient: to, amountIn: amountIn,
                    amountOutMinimum: minOut, sqrtPriceLimitX96: sqrtPriceLimit
                })
            );
        } else if (tokenOut == address(0)) {
            // _selfBalance: FoT tokens may have left adapter with less than amountIn.
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);
            amountOut = IV3Router(dexRouter).exactInputSingle(
                IV3Router.ExactInputSingleParams({
                    tokenIn: tokenIn, tokenOut: wbnb, fee: poolFee,
                    recipient: address(this), amountIn: actualIn,
                    amountOutMinimum: minOut, sqrtPriceLimitX96: sqrtPriceLimit
                })
            );
            _resetApproval(tokenIn, dexRouter);
            _unwrapAndSend(wbnb, amountOut, to);
        } else {
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);
            amountOut = IV3Router(dexRouter).exactInputSingle(
                IV3Router.ExactInputSingleParams({
                    tokenIn: tokenIn, tokenOut: tokenOut, fee: poolFee,
                    recipient: to, amountIn: actualIn,
                    amountOutMinimum: minOut, sqrtPriceLimitX96: sqrtPriceLimit
                })
            );
            _resetApproval(tokenIn, dexRouter);
        }
    }

    function _executeMulti(
        address tokenIn, uint256 amountIn, address tokenOut,
        uint256 minOut, address to, bytes memory v3Path
    ) internal returns (uint256 amountOut) {
        if (tokenIn == address(0)) {
            amountOut = IV3Router(dexRouter).exactInput{value: amountIn}(
                IV3Router.ExactInputParams({
                    path: v3Path, recipient: to,
                    amountIn: amountIn, amountOutMinimum: minOut
                })
            );
        } else if (tokenOut == address(0)) {
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);
            amountOut = IV3Router(dexRouter).exactInput(
                IV3Router.ExactInputParams({
                    path: v3Path, recipient: address(this),
                    amountIn: actualIn, amountOutMinimum: minOut
                })
            );
            _resetApproval(tokenIn, dexRouter);
            _unwrapAndSend(wbnb, amountOut, to);
        } else {
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);
            amountOut = IV3Router(dexRouter).exactInput(
                IV3Router.ExactInputParams({
                    path: v3Path, recipient: to,
                    amountIn: actualIn, amountOutMinimum: minOut
                })
            );
            _resetApproval(tokenIn, dexRouter);
        }
    }
}
