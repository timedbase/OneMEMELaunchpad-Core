// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

interface IV2Router {
    function WETH() external pure returns (address);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256           amountIn,
        uint256           amountOutMin,
        address[] calldata path,
        address           to,
        uint256           deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256           amountOutMin,
        address[] calldata path,
        address           to,
        uint256           deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256           amountIn,
        uint256           amountOutMin,
        address[] calldata path,
        address           to,
        uint256           deadline
    ) external;
}

/**
 * @title  GenericV2Adapter
 * @notice Adapter for any Uniswap V2-compatible DEX. Deploy one instance per DEX.
 *         adapterData = abi.encode(address[] path, uint256 deadline)
 *         address(0) legs must use the real WBNB address inside the path.
 */
contract GenericV2Adapter is BaseAdapter {

    address public immutable dexRouter;
    address public immutable weth;

    string private _name;

    error InvalidPath();

    constructor(address aggregator_, address router_, string memory name_)
        BaseAdapter(aggregator_)
    {
        if (router_ == address(0)) revert ZeroAddress();
        dexRouter = router_;
        weth      = IV2Router(router_).WETH();
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
        (address[] memory path, uint256 deadline) = abi.decode(data, (address[], uint256));

        if (path.length < 2) revert InvalidPath();
        address expectedFirst = tokenIn  == address(0) ? weth : tokenIn;
        address expectedLast  = tokenOut == address(0) ? weth : tokenOut;
        if (path[0]               != expectedFirst) revert InvalidPath();
        if (path[path.length - 1] != expectedLast)  revert InvalidPath();

        if (tokenIn == address(0)) {
            uint256 balBefore = _balanceOf(path[path.length - 1], to);
            IV2Router(dexRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
                minOut, path, to, deadline
            );
            amountOut = _balanceOf(path[path.length - 1], to) - balBefore;
            if (amountOut < minOut) revert InsufficientOutput();

        } else if (tokenOut == address(0)) {
            // _selfBalance: FoT tokens may have left adapter with less than amountIn.
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);
            IV2Router(dexRouter).swapExactTokensForETHSupportingFeeOnTransferTokens(
                actualIn, minOut, path, to, deadline
            );
            _resetApproval(tokenIn, dexRouter);
            amountOut = 0;

        } else {
            // _selfBalance: FoT tokens may have left adapter with less than amountIn.
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, dexRouter, actualIn);
            uint256 balBefore = _balanceOf(tokenOut, to);
            IV2Router(dexRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                actualIn, minOut, path, to, deadline
            );
            _resetApproval(tokenIn, dexRouter);
            amountOut = _balanceOf(tokenOut, to) - balBefore;
            if (amountOut < minOut) revert InsufficientOutput();
        }
    }
}
