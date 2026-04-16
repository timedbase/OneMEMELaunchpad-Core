// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

/**
 * @title  IAdapter
 * @notice Interface every OneMEME aggregator adapter must implement.
 *
 * Invariant enforced by OneMEMEAggregator before calling execute():
 *   - ERC-20 input: `amountIn` of `tokenIn` has already been transferred to
 *     this adapter's address.
 *   - Native BNB input: `amountIn` BNB has been forwarded as msg.value.
 *
 * The adapter is responsible for executing the DEX-specific swap and
 * delivering `tokenOut` (or native BNB when tokenOut == address(0)) to `to`.
 */
interface IAdapter {

    /**
     * @notice Execute a swap using offchain-provided routing data.
     *
     * @param tokenIn   Input token. address(0) = native BNB (already in msg.value).
     * @param amountIn  Net input amount (after aggregator fee). Already held by
     *                  this adapter (in balance or msg.value).
     * @param tokenOut  Output token. address(0) = caller wants native BNB back.
     * @param minOut    Minimum acceptable output. Adapter must revert if not met.
     * @param to        Final recipient of the output.
     * @param data      Adapter-specific encoded parameters built by the offchain
     *                  aggregator. See each concrete adapter for the exact encoding.
     * @return amountOut Actual output amount delivered to `to`.
     *                   V3 adapters return exact amounts; V2 adapters return 0
     *                   (the DEX router enforces minOut internally).
     */
    function execute(
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata data
    ) external payable returns (uint256 amountOut);

    /**
     * @notice Human-readable name for this adapter, e.g. "PancakeSwap V2".
     *         Used by the aggregator registry for display and logging.
     */
    function name() external view returns (string memory);
}
