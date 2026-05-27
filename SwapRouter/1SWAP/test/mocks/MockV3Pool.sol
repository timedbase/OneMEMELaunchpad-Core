// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniV3Factory} from "../../src/interfaces/IUniV3Factory.sol";
import {IUniV3Pool}    from "../../src/interfaces/IUniV3Pool.sol";

/**
 * @notice Proper mock V3 factory: maps (token0, token1, fee) → pool.
 *         Used as the main test suite factory so multiple pools/routers
 *         can be registered with distinct (t0, t1, fee) triplets.
 */
contract MockV3Factory is IUniV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) private _pools;

    function registerPool(address t0, address t1, uint24 fee, address pool) external {
        _pools[t0][t1][fee] = pool;
        _pools[t1][t0][fee] = pool;
    }

    function getPool(address t0, address t1, uint24 fee) external view returns (address) {
        return _pools[t0][t1][fee];
    }
}

/**
 * @notice Simplified mock factory that always returns the same address regardless
 *         of input — useful for V3 callback validation tests where there is only
 *         one pool under test.
 */
contract ConfigurableV3Factory is IUniV3Factory {
    address public poolToReturn;

    constructor(address pool_) { poolToReturn = pool_; }

    function getPool(address, address, uint24) external view returns (address) {
        return poolToReturn;
    }
}

interface ICallbackTarget {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/**
 * @notice Mock V3 pool: implements IUniV3Pool (token0/token1/fee) and provides
 *         a simple swap() that sends a pre-configured output token to the caller.
 *         Also exposes trigger helpers to fire the V3 callbacks on a target.
 */
contract MockV3Pool is IUniV3Pool {
    address public token0;
    address public token1;
    uint24  public fee;

    address private _outToken;
    uint256 private _outAmount;

    constructor(address t0, address t1, uint24 fee_) {
        token0 = t0;
        token1 = t1;
        fee    = fee_;
    }

    /// @dev Pre-load the output the pool emits on swap().
    function prepareOutput(address outToken, uint256 outAmount) external {
        _outToken  = outToken;
        _outAmount = outAmount;
    }

    /// @dev Minimal swap: sends _outAmount of _outToken to `recipient`.
    function swap(uint256, uint256, address recipient, bytes calldata) external {
        if (_outAmount > 0) {
            (bool ok,) = _outToken.call(
                abi.encodeWithSignature("transfer(address,uint256)", recipient, _outAmount)
            );
            require(ok, "MockV3Pool: transfer failed");
        }
    }

    /// @dev Triggers the Uniswap V3 callback on `target`.
    function triggerUniCallback(
        address target,
        int256  amount0Delta,
        int256  amount1Delta,
        bytes calldata data
    ) external {
        ICallbackTarget(target).uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    /// @dev Triggers the PancakeSwap V3 callback on `target`.
    function triggerCakeCallback(
        address target,
        int256  amount0Delta,
        int256  amount1Delta,
        bytes calldata data
    ) external {
        ICallbackTarget(target).pancakeV3SwapCallback(amount0Delta, amount1Delta, data);
    }
}
