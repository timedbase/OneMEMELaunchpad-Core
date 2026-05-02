// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

interface IUniversalRouterV4 {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title  GenericV4Adapter
 * @notice Adapter for any Uniswap V4-compatible DEX via its UniversalRouter. Deploy one instance per DEX.
 *         Single-hop: adapterData = abi.encode(false, PoolKey, bool zeroForOne, bytes hookData, uint256 deadline)
 *         Multi-hop:  adapterData = abi.encode(true, PathKey[], uint256 deadline)
 *         address(0) = native BNB in all currency fields.
 *         Note: fee-on-transfer input tokens are not supported — V4 PoolManager records
 *         the declared amountIn as debt; a FoT deduction leaves the router short on SETTLE.
 */
contract GenericV4Adapter is BaseAdapter {

    uint8 private constant CMD_V4_SWAP              = 0x10;
    uint8 private constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 private constant ACT_SWAP_EXACT_IN        = 0x07;
    uint8 private constant ACT_SETTLE               = 0x0b;
    uint8 private constant ACT_SETTLE_ALL           = 0x0c;
    uint8 private constant ACT_TAKE                 = 0x0e;
    uint256 private constant OPEN_DELTA             = 0;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24  fee;
        int24   tickSpacing;
        address hooks;
    }

    struct PathKey {
        address intermediateCurrency;
        uint24  fee;
        int24   tickSpacing;
        address hooks;
        bytes   hookData;
    }

    address public immutable universalRouter;
    string  private _name;

    error InvalidPath();

    constructor(address aggregator_, address router_, string memory name_)
        BaseAdapter(aggregator_)
    {
        if (router_ == address(0)) revert ZeroAddress();
        universalRouter = router_;
        _name = name_;
    }

    function name() external view override returns (string memory) { return _name; }

    function execute(
        address        tokenIn,
        uint256        netIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata adapterData
    ) external payable override onlyAggregator returns (uint256 amountOut) {
        uint256 actualIn = tokenIn == address(0) ? netIn : _selfBalance(tokenIn);
        if (!abi.decode(adapterData, (bool)))
            amountOut = _execSingle(tokenIn, actualIn, tokenOut, minOut, to, adapterData);
        else
            amountOut = _execMulti(tokenIn, actualIn, tokenOut, minOut, to, adapterData);
    }

    function _execSingle(
        address        tokenIn,
        uint256        actualIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata adapterData
    ) internal returns (uint256) {
        (bytes memory actions, bytes[] memory aParams, uint256 deadline) =
            _prepSingle(tokenIn, tokenOut, actualIn, minOut, adapterData);
        return _fireRouter(tokenIn, tokenOut, minOut, to, actualIn, actions, aParams, deadline);
    }

    function _execMulti(
        address        tokenIn,
        uint256        actualIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata adapterData
    ) internal returns (uint256) {
        (bytes memory actions, bytes[] memory aParams, uint256 deadline) =
            _prepMulti(tokenIn, tokenOut, actualIn, minOut, adapterData);
        return _fireRouter(tokenIn, tokenOut, minOut, to, actualIn, actions, aParams, deadline);
    }

    function _prepSingle(
        address        tokenIn,
        address        tokenOut,
        uint256        actualIn,
        uint256        minOut,
        bytes calldata data
    ) internal view returns (bytes memory actions, bytes[] memory aParams, uint256 deadline) {
        (, PoolKey memory poolKey, bool zeroForOne, bytes memory hookData, uint256 dl) =
            abi.decode(data, (bool, PoolKey, bool, bytes, uint256));
        deadline = dl;
        (actions, aParams) = _buildSingle(tokenIn, tokenOut, poolKey, zeroForOne, actualIn, minOut, hookData);
    }

    function _prepMulti(
        address        tokenIn,
        address        tokenOut,
        uint256        actualIn,
        uint256        minOut,
        bytes calldata data
    ) internal view returns (bytes memory actions, bytes[] memory aParams, uint256 deadline) {
        (, PathKey[] memory path, uint256 dl) = abi.decode(data, (bool, PathKey[], uint256));
        if (path.length == 0) revert InvalidPath();
        deadline = dl;
        (actions, aParams) = _buildMulti(tokenIn, tokenOut, path, actualIn, minOut);
    }

    function _fireRouter(
        address        tokenIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        uint256        actualIn,
        bytes memory   actions,
        bytes[] memory aParams,
        uint256        deadline
    ) internal returns (uint256 amountOut) {
        if (tokenIn != address(0)) _safeTransfer(tokenIn, universalRouter, actualIn);
        uint256 snapBefore = tokenOut == address(0) ? address(this).balance : _selfBalance(tokenOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, aParams);
        IUniversalRouterV4(universalRouter).execute{value: msg.value}(
            abi.encodePacked(CMD_V4_SWAP), inputs, deadline
        );
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

    function _buildSingle(
        address tokenIn, address tokenOut,
        PoolKey memory poolKey, bool zeroForOne,
        uint256 actualIn, uint256 minOut, bytes memory hookData
    ) internal view returns (bytes memory actions, bytes[] memory aParams) {
        aParams = new bytes[](3);
        aParams[0] = abi.encode(poolKey, zeroForOne, uint128(actualIn), uint128(minOut), uint256(0), hookData);
        aParams[2] = abi.encode(tokenOut, address(this), OPEN_DELTA);
        if (tokenIn == address(0)) {
            actions    = abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE);
            aParams[1] = abi.encode(address(0), actualIn);
        } else {
            actions    = abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE, ACT_TAKE);
            // payerIsUser=false: tokens are pre-transferred to the router by this adapter.
            aParams[1] = abi.encode(tokenIn, actualIn, false);
        }
    }

    function _buildMulti(
        address tokenIn, address tokenOut,
        PathKey[] memory path, uint256 actualIn, uint256 minOut
    ) internal view returns (bytes memory actions, bytes[] memory aParams) {
        aParams = new bytes[](3);
        uint256[] memory minHopPrices = new uint256[](path.length);
        aParams[0] = abi.encode(tokenIn, path, minHopPrices, uint128(actualIn), uint128(minOut));
        aParams[2] = abi.encode(tokenOut, address(this), OPEN_DELTA);
        if (tokenIn == address(0)) {
            actions    = abi.encodePacked(ACT_SWAP_EXACT_IN, ACT_SETTLE_ALL, ACT_TAKE);
            aParams[1] = abi.encode(address(0), actualIn);
        } else {
            actions    = abi.encodePacked(ACT_SWAP_EXACT_IN, ACT_SETTLE, ACT_TAKE);
            // payerIsUser=false: tokens are pre-transferred to the router by this adapter.
            aParams[1] = abi.encode(tokenIn, actualIn, false);
        }
    }
}
