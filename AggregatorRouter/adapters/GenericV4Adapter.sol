// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

// ─── Interface ────────────────────────────────────────────────────────────────

interface IUniversalRouterV4 {
    /// @dev execute(commands, inputs, deadline) — each byte in commands is a command;
    ///      inputs[i] is the ABI-encoded payload for commands[i].
    function execute(
        bytes calldata  commands,
        bytes[] calldata inputs,
        uint256          deadline
    ) external payable;
}

// ─── Main Contract ────────────────────────────────────────────────────────────

/**
 * @title  GenericV4Adapter
 * @notice Adapter for any Uniswap V4-compatible DEX via its UniversalRouter.
 *         Deploy one instance per DEX by injecting a different `router_`.
 *         Supports all three swap directions: BNB→Token, Token→BNB, Token→Token.
 *
 * ─── adapterData encoding ────────────────────────────────────────────────────
 *
 *   Single-hop (isMultiHop == false):
 *     abi.encode(false, PoolKey, bool zeroForOne, bytes hookData, uint256 deadline)
 *
 *   Multi-hop  (isMultiHop == true):
 *     abi.encode(true, PathKey[], uint256 deadline)
 *     currencyIn is inferred from tokenIn; the last PathKey.intermediateCurrency == tokenOut.
 *
 * ─── Pool and path types ─────────────────────────────────────────────────────
 *
 *   PoolKey   { currency0, currency1, fee, tickSpacing, hooks }
 *   PathKey   { intermediateCurrency, fee, tickSpacing, hooks, hookData }
 *   address(0) = native BNB in all currency fields.
 *
 * ─── Suggested registry IDs ──────────────────────────────────────────────────
 *
 *   keccak256("PANCAKE_V4")  router = 0xd9c500dff816a1da21a48a732d3498bf09dc9aeb
 *   keccak256("UNISWAP_V4")  router = 0x1906c1d672b88cd1b9ac7593301ca990f94eae07
 *
 * ─── Settlement model ────────────────────────────────────────────────────────
 *
 *   BNB input:   sent as msg.value → UniversalRouter → SETTLE_ALL clears native debt.
 *   ERC20 input: adapter pre-transfers to UniversalRouter; SETTLE(payerIsUser=false)
 *                pulls from the router's balance into the PoolManager.
 *   Output (any): TAKE(recipient=address(this), amount=OPEN_DELTA) sends all output
 *                 credit to the adapter; adapter then forwards to `to`.
 *
 *   Note: fee-on-transfer input tokens are not supported in V4 (PoolManager records
 *   the declared amountIn as the debt; a FoT transfer leaves the router short, causing
 *   SETTLE to revert). FoT output tokens are handled by the balance-delta check.
 */
contract GenericV4Adapter is BaseAdapter {

    // ── UniversalRouter command ───────────────────────────────────────────────

    uint8 private constant CMD_V4_SWAP = 0x10;

    // ── V4 inner action bytes (Actions.sol in v4-periphery) ──────────────────

    uint8 private constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 private constant ACT_SWAP_EXACT_IN        = 0x07;
    uint8 private constant ACT_SETTLE               = 0x0b;  // ERC20: router holds tokens
    uint8 private constant ACT_SETTLE_ALL           = 0x0c;  // native: uses msg.value
    uint8 private constant ACT_TAKE                 = 0x0e;  // deliver to explicit recipient

    // OPEN_DELTA = 0: sentinel that tells TAKE to take all available credit.
    uint256 private constant OPEN_DELTA = 0;

    // ── V4 struct definitions ─────────────────────────────────────────────────

    /// @dev Identifies a V4 pool. Mirrors v4-core PoolKey.
    struct PoolKey {
        address currency0;   // lower token address; address(0) = native BNB
        address currency1;   // higher token address
        uint24  fee;         // LP fee tier, e.g. 500, 3000, 10000
        int24   tickSpacing; // e.g. 10, 60, 200
        address hooks;       // address(0) = no hooks
    }

    /// @dev One hop in a multi-hop path. Mirrors v4-periphery PathKey.
    ///      The pool for hop i connects the previous currency to intermediateCurrency.
    ///      The last PathKey.intermediateCurrency is the final output currency.
    struct PathKey {
        address intermediateCurrency;
        uint24  fee;
        int24   tickSpacing;
        address hooks;
        bytes   hookData;   // "" for pools without hooks
    }

    // ── State ────────────────────────────────────────────────────────────────

    address public immutable universalRouter;
    string  private _name;

    // ── Errors ───────────────────────────────────────────────────────────────

    error InvalidPath();

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address aggregator_, address router_, string memory name_)
        BaseAdapter(aggregator_)
    {
        if (router_ == address(0)) revert ZeroAddress();
        universalRouter = router_;
        _name = name_;
    }

    function name() external view override returns (string memory) { return _name; }

    // ── execute ──────────────────────────────────────────────────────────────

    /**
     * @dev Pre-condition (BNB input):   netIn BNB in msg.value.
     *      Pre-condition (ERC20 input): netIn of tokenIn already held by this adapter.
     */
    function execute(
        address        tokenIn,
        uint256        netIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata adapterData
    ) external payable override onlyAggregator returns (uint256 amountOut) {

        bool isMultiHop = abi.decode(adapterData, (bool));

        uint256 actualIn;
        bytes memory actions;
        bytes[] memory aParams;
        uint256 deadline;

        if (!isMultiHop) {
            (
                , PoolKey memory poolKey,
                bool zeroForOne,
                bytes memory hookData,
                uint256 dl
            ) = abi.decode(adapterData, (bool, PoolKey, bool, bytes, uint256));
            deadline = dl;
            actualIn = tokenIn == address(0) ? netIn : _selfBalance(tokenIn);
            (actions, aParams) = _buildSingle(tokenIn, tokenOut, poolKey, zeroForOne, actualIn, minOut, hookData);

        } else {
            (, PathKey[] memory path, uint256 dl) = abi.decode(adapterData, (bool, PathKey[], uint256));
            if (path.length == 0) revert InvalidPath();
            deadline = dl;
            actualIn = tokenIn == address(0) ? netIn : _selfBalance(tokenIn);
            (actions, aParams) = _buildMulti(tokenIn, tokenOut, path, actualIn, minOut);
        }

        // ERC20 input: pre-transfer to UniversalRouter so SETTLE(payerIsUser=false) can pull it.
        if (tokenIn != address(0)) {
            _safeTransfer(tokenIn, universalRouter, actualIn);
        }

        // Snapshot output balance before swap
        uint256 snapBefore = tokenOut == address(0)
            ? address(this).balance
            : _selfBalance(tokenOut);

        // Build and fire UniversalRouter call
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, aParams);
        IUniversalRouterV4(universalRouter).execute{value: msg.value}(commands, inputs, deadline);

        // Measure output, assert slippage, deliver to `to`
        if (tokenOut == address(0)) {
            amountOut = address(this).balance - snapBefore;
            if (amountOut < minOut) revert InsufficientOutput();
            _sendNative(to, amountOut);
        } else {
            amountOut = _selfBalance(tokenOut) - snapBefore;
            if (amountOut < minOut) revert InsufficientOutput();
            _safeTransfer(tokenOut, to, amountOut);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL BUILDERS
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Builds actions + params for a single-hop exact-input V4 swap.
    function _buildSingle(
        address tokenIn,
        address tokenOut,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 actualIn,
        uint256 minOut,
        bytes memory hookData
    ) internal view returns (bytes memory actions, bytes[] memory aParams) {
        aParams = new bytes[](3);

        // params[0]: ExactInputSingleParams
        aParams[0] = abi.encode(
            poolKey,
            zeroForOne,
            uint128(actualIn),
            uint128(minOut),
            uint256(0),    // minHopPriceX36 = 0 (no price limit)
            hookData
        );

        // params[2]: TAKE — output currency to this adapter (OPEN_DELTA = take all credit)
        aParams[2] = abi.encode(tokenOut, address(this), OPEN_DELTA);

        if (tokenIn == address(0)) {
            // Native BNB input: SETTLE_ALL settles outstanding native debt using msg.value.
            actions = abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE);
            aParams[1] = abi.encode(address(0), actualIn);  // SETTLE_ALL(native, maxAmount)
        } else {
            // ERC20 input: router holds pre-transferred tokens; payerIsUser=false.
            actions = abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE, ACT_TAKE);
            aParams[1] = abi.encode(tokenIn, actualIn, false);  // SETTLE(token, amount, payerIsUser)
        }
    }

    /// @dev Builds actions + params for a multi-hop exact-input V4 swap.
    function _buildMulti(
        address tokenIn,
        address tokenOut,
        PathKey[] memory path,
        uint256 actualIn,
        uint256 minOut
    ) internal view returns (bytes memory actions, bytes[] memory aParams) {
        aParams = new bytes[](3);

        // Per-hop price limits (all zero = no limit)
        uint256[] memory minHopPrices = new uint256[](path.length);

        // params[0]: ExactInputParams
        aParams[0] = abi.encode(
            tokenIn,       // currencyIn (address(0) = native)
            path,
            minHopPrices,
            uint128(actualIn),
            uint128(minOut)
        );

        // params[2]: TAKE — output currency to this adapter
        aParams[2] = abi.encode(tokenOut, address(this), OPEN_DELTA);

        if (tokenIn == address(0)) {
            actions = abi.encodePacked(ACT_SWAP_EXACT_IN, ACT_SETTLE_ALL, ACT_TAKE);
            aParams[1] = abi.encode(address(0), actualIn);
        } else {
            actions = abi.encodePacked(ACT_SWAP_EXACT_IN, ACT_SETTLE, ACT_TAKE);
            aParams[1] = abi.encode(tokenIn, actualIn, false);
        }
    }
}
