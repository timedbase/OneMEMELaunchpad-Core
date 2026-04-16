// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

// ─── Interface ────────────────────────────────────────────────────────────────

interface IFlapSH {
    struct ExactInputParams {
        address inputToken;       // address(0) = native BNB
        address outputToken;      // address(0) = native BNB
        uint256 inputAmount;      // in token decimals
        uint256 minOutputAmount;  // slippage guard
        bytes   permitData;       // optional EIP-2612 permit; pass "" if not needed
    }

    // Output is always delivered to msg.sender.
    function swapExactInput(ExactInputParams calldata params)
        external payable returns (uint256 outputAmount);
}

// ─── Main Contract ────────────────────────────────────────────────────────────

/**
 * @title  FlapSHAdapter
 * @notice Aggregator adapter for Flap.SH bonding-curve tokens.
 *         Supports all three swap directions: BNB→Token, Token→BNB, Token→Token.
 *         Routing is handled entirely by the Flap.SH contract — no offchain path needed.
 *
 * adapterData  not used; pass empty bytes offchain
 * Registry ID  keccak256("FLAPSH")
 *
 * Output delivery note
 * ────────────────────
 *   Flap.SH's swapExactInput has no recipient parameter — output always goes to
 *   msg.sender (this adapter). The adapter measures the balance delta and
 *   forwards the full received amount to `to`.
 */
contract FlapSHAdapter is BaseAdapter {

    // ── Protocol address (BSC mainnet) ────────────────────────────────────────

    address public constant FLAP = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address aggregator_) BaseAdapter(aggregator_) {}

    function name() external pure override returns (string memory) {
        return "Flap.SH";
    }

    // ── execute ──────────────────────────────────────────────────────────────

    /**
     * @dev Pre-condition (BNB input):   netIn BNB in msg.value.
     *      Pre-condition (token input): netIn of tokenIn already held by this adapter.
     */
    function execute(
        address        tokenIn,
        uint256        netIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata /* adapterData — unused */
    ) external payable override onlyAggregator returns (uint256 amountOut) {

        if (tokenIn == address(0)) {
            // ── BNB → Token ───────────────────────────────────────────────────
            uint256 balBefore = _selfBalance(tokenOut);

            IFlapSH(FLAP).swapExactInput{value: netIn}(IFlapSH.ExactInputParams({
                inputToken:      address(0),
                outputToken:     tokenOut,
                inputAmount:     netIn,
                minOutputAmount: minOut,
                permitData:      ""
            }));

            amountOut = _selfBalance(tokenOut) - balBefore;
            if (amountOut < minOut) revert InsufficientOutput();
            _safeTransfer(tokenOut, to, amountOut);

        } else if (tokenOut == address(0)) {
            // ── Token → BNB ───────────────────────────────────────────────────
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, FLAP, actualIn);

            uint256 bnbBefore = address(this).balance;

            IFlapSH(FLAP).swapExactInput(IFlapSH.ExactInputParams({
                inputToken:      tokenIn,
                outputToken:     address(0),
                inputAmount:     actualIn,
                minOutputAmount: minOut,
                permitData:      ""
            }));
            _resetApproval(tokenIn, FLAP);

            amountOut = address(this).balance - bnbBefore;
            if (amountOut < minOut) revert InsufficientOutput();
            _sendNative(to, amountOut);

        } else {
            // ── Token → Token (e.g. stablecoin ↔ bonding-curve token) ─────────
            uint256 actualIn = _selfBalance(tokenIn);
            _approve(tokenIn, FLAP, actualIn);

            uint256 balBefore = _selfBalance(tokenOut);

            IFlapSH(FLAP).swapExactInput(IFlapSH.ExactInputParams({
                inputToken:      tokenIn,
                outputToken:     tokenOut,
                inputAmount:     actualIn,
                minOutputAmount: minOut,
                permitData:      ""
            }));
            _resetApproval(tokenIn, FLAP);

            amountOut = _selfBalance(tokenOut) - balBefore;
            if (amountOut < minOut) revert InsufficientOutput();
            _safeTransfer(tokenOut, to, amountOut);
        }
    }
}
