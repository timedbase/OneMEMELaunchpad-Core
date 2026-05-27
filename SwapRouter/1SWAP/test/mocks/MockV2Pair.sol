// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Configurable mock V2 factory for auto-validation tests.
contract MockV2Factory {
    mapping(address => mapping(address => address)) private _pairs;

    function setPair(address tokenA, address tokenB, address pair) external {
        _pairs[tokenA][tokenB] = pair;
        _pairs[tokenB][tokenA] = pair;
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[tokenA][tokenB];
    }
}

/// @dev Mock V2 pair. Exposes token0/token1 for _validateTarget; on swap() sends tokenOut.
contract MockV2Pair {
    address public token0;
    address public token1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    /// @dev Minimal V2 swap: sends amount0Out of token0 and amount1Out of token1 to `to`.
    ///      The caller must have pre-transferred the input token before calling.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount1Out > 0) {
            (bool ok,) = token1.call(
                abi.encodeWithSignature("transfer(address,uint256)", to, amount1Out)
            );
            require(ok, "MockV2Pair: token1 transfer failed");
        }
        if (amount0Out > 0) {
            (bool ok,) = token0.call(
                abi.encodeWithSignature("transfer(address,uint256)", to, amount0Out)
            );
            require(ok, "MockV2Pair: token0 transfer failed");
        }
    }
}
