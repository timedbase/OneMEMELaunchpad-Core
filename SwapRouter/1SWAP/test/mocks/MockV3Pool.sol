// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniV3Factory} from "../../src/interfaces/IUniV3Factory.sol";
import {IUniV3Pool}    from "../../src/interfaces/IUniV3Pool.sol";

/// @dev Minimal mock factory used for V3 callback validation tests.
contract MockV3Factory is IUniV3Factory {
    mapping(address => address) public poolByAddress;

    function registerPool(address pool) external {
        poolByAddress[pool] = pool;
    }

    /// @dev Returns the registered pool if all three args match (simplified — just checks pool exists).
    function getPool(address, address, uint24) external view returns (address) {
        // For testing we return a sentinel. Caller overrides per test.
        return address(0);
    }
}

/// @dev A configurable mock factory that always returns a pre-set pool address.
contract ConfigurableV3Factory is IUniV3Factory {
    address public poolToReturn;

    constructor(address pool_) { poolToReturn = pool_; }

    function getPool(address, address, uint24) external view returns (address) {
        return poolToReturn;
    }
}

/// @dev Mock V3 pool that exposes token0/token1/fee and can trigger a callback on OneDex.
interface ICallbackTarget {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

contract MockV3Pool is IUniV3Pool {
    address public token0;
    address public token1;
    uint24  public fee;

    constructor(address t0, address t1, uint24 fee_) {
        token0 = t0;
        token1 = t1;
        fee    = fee_;
    }

    /// @dev Triggers the Uniswap V3 callback on `target` with the given deltas and data.
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
