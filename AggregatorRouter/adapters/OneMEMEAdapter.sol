// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

interface IBondingCurve {
    function buy(address token_, uint256 minOut, uint256 deadline) external payable;
    function sell(address token_, uint256 amountIn, uint256 minBNBOut, uint256 deadline) external;
}

/**
 * @title  OneMEMEAdapter
 * @notice Adapter for the OneMEME launchpad bonding curve (pre-migration only).
 *         Supports BNB→Token (buy) and Token→BNB (sell).
 *         adapterData = abi.encode(address token, uint256 deadline)
 *         Registry ID: keccak256("ONEMEME_BC")
 */
contract OneMEMEAdapter is BaseAdapter {

    address public immutable bondingCurve;

    error UnsupportedDirection();
    error TokenMismatch();

    constructor(address aggregator_, address bondingCurve_)
        BaseAdapter(aggregator_)
    {
        if (bondingCurve_ == address(0)) revert ZeroAddress();
        bondingCurve = bondingCurve_;
    }

    function name() external pure override returns (string memory) {
        return "OneMEME Bonding Curve";
    }

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
            if (tokenOut != token) revert TokenMismatch();
            amountOut = _executeBuy(token, amountIn, minOut, deadline, to);
        } else if (tokenIn != address(0) && tokenOut == address(0)) {
            if (tokenIn != token) revert TokenMismatch();
            _executeSell(token, minOut, deadline, to);
            // amountOut = 0; BNB is delivered directly to `to` by the bonding curve
        } else {
            revert UnsupportedDirection();
        }
    }

    function _executeBuy(
        address token, uint256 amountIn, uint256 minOut, uint256 deadline, address to
    ) internal returns (uint256 tokensReceived) {
        uint256 balBefore = _selfBalance(token);
        IBondingCurve(bondingCurve).buy{value: amountIn}(token, minOut, deadline);
        tokensReceived = _selfBalance(token) - balBefore;
        if (tokensReceived < minOut) revert InsufficientOutput();
        _safeTransfer(token, to, tokensReceived);
        uint256 refund = address(this).balance;
        if (refund > 0) _sendNative(to, refund);
    }

    function _executeSell(
        address token, uint256 minBNBOut, uint256 deadline, address to
    ) internal {
        // _selfBalance: FoT tokens may have left adapter with less than the declared amountIn.
        uint256 actualIn = _selfBalance(token);
        _approve(token, bondingCurve, actualIn);
        uint256 bnbBefore = address(this).balance;
        IBondingCurve(bondingCurve).sell(token, actualIn, minBNBOut, deadline);
        _resetApproval(token, bondingCurve);
        uint256 received = address(this).balance - bnbBefore;
        if (received > 0) _sendNative(to, received);
    }
}
