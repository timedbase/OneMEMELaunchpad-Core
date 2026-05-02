// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

interface IFlapSH {
    struct ExactInputParams {
        address inputToken;       // address(0) = native BNB
        address outputToken;      // address(0) = native BNB
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes   permitData;       // optional EIP-2612 permit; pass "" if not needed
    }
    // Output is always delivered to msg.sender.
    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256 outputAmount);
}

/**
 * @title  FlapSHAdapter
 * @notice Aggregator adapter for Flap.SH. Supports BNB→Token, Token→BNB, Token→Token.
 *         adapterData is unused; pass empty bytes offchain.
 *         Registry ID: keccak256("FLAPSH")
 *
 *         swapExactInput has no recipient — output always goes to msg.sender (this adapter).
 *         The adapter measures the balance delta and forwards to `to`.
 */
contract FlapSHAdapter is BaseAdapter {

    address public constant FLAP = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;

    constructor(address aggregator_) BaseAdapter(aggregator_) {}

    function name() external pure override returns (string memory) {
        return "Flap.SH";
    }

    function execute(
        address        tokenIn,
        uint256        netIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata /* adapterData — unused */
    ) external payable override onlyAggregator returns (uint256 amountOut) {

        if (tokenIn == address(0)) {
            uint256 balBefore = _selfBalance(tokenOut);
            IFlapSH(FLAP).swapExactInput{value: netIn}(IFlapSH.ExactInputParams({
                inputToken: address(0), outputToken: tokenOut,
                inputAmount: netIn, minOutputAmount: minOut, permitData: ""
            }));
            amountOut = _selfBalance(tokenOut) - balBefore;
            if (amountOut < minOut) revert InsufficientOutput();
            _safeTransfer(tokenOut, to, amountOut);

        } else if (tokenOut == address(0)) {
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, FLAP, actualIn);
            uint256 bnbBefore = address(this).balance;
            IFlapSH(FLAP).swapExactInput(IFlapSH.ExactInputParams({
                inputToken: tokenIn, outputToken: address(0),
                inputAmount: actualIn, minOutputAmount: minOut, permitData: ""
            }));
            _resetApproval(tokenIn, FLAP);
            amountOut = address(this).balance - bnbBefore;
            if (amountOut < minOut) revert InsufficientOutput();
            _sendNative(to, amountOut);

        } else {
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, FLAP, actualIn);
            uint256 balBefore = _selfBalance(tokenOut);
            IFlapSH(FLAP).swapExactInput(IFlapSH.ExactInputParams({
                inputToken: tokenIn, outputToken: tokenOut,
                inputAmount: actualIn, minOutputAmount: minOut, permitData: ""
            }));
            _resetApproval(tokenIn, FLAP);
            amountOut = _selfBalance(tokenOut) - balBefore;
            if (amountOut < minOut) revert InsufficientOutput();
            _safeTransfer(tokenOut, to, amountOut);
        }
    }
}
