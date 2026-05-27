// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/**
 * @notice Configurable mock router for unit tests.
 *
 * Exposes token0/token1/fee so _validateTarget treats it as a V3 pool.
 * The test suite registers it in a MockV3Factory keyed by (token0, token1, fee).
 *
 * Supports four swap modes:
 *   swapTokens       — ERC-20 in, ERC-20 out   (approve/pull style — V3 router)
 *   swapTokensForBNB — ERC-20 in, native BNB out
 *   swapBNBForTokens — native BNB in, ERC-20 out (payable)
 *   revertWith       — unconditionally revert (for revert-bubbling tests)
 */
contract MockRouter {
    // V3-pool identity fields so _validateTarget accepts this contract.
    address public token0;
    address public token1;
    uint24  public fee;

    constructor(address t0, address t1, uint24 fee_) {
        token0 = t0;
        token1 = t1;
        fee    = fee_;
    }

    receive() external payable {}

    /// @notice Pull `amountIn` tokenIn from caller, give `amountOut` tokenOut.
    function swapTokens(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    ) external {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).transfer(msg.sender, amountOut);
    }

    /// @notice Pull `amountIn` tokenIn from caller, send `bnbOut` BNB.
    function swapTokensForBNB(
        address tokenIn,
        uint256 amountIn,
        uint256 bnbOut
    ) external {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = msg.sender.call{value: bnbOut}("");
        require(ok, "MockRouter: BNB send failed");
    }

    /// @notice Accept BNB, give `amountOut` tokenOut to caller.
    function swapBNBForTokens(address tokenOut, uint256 amountOut) external payable {
        MockERC20(tokenOut).transfer(msg.sender, amountOut);
    }

    /// @notice Unconditionally revert with a custom string — used for revert-bubble tests.
    function revertWith(string calldata reason) external pure {
        revert(reason);
    }
}

/**
 * @notice Mock pool that attempts reentrancy into the executor when any swap is called.
 *         Exposes token0/token1/fee so _validateTarget accepts it as a V3 pool.
 *         Register it in MockV3Factory with a distinct (token0, token1, fee) triplet.
 */
contract ReentrantPool {
    address public token0;
    address public token1;
    uint24  public fee;

    address private _executor;
    bytes   private _reentrantCall;

    constructor(address t0, address t1, uint24 fee_, address executor_, bytes memory reentrantCall_) {
        token0        = t0;
        token1        = t1;
        fee           = fee_;
        _executor     = executor_;
        _reentrantCall = reentrantCall_;
    }

    /// @dev Any unrecognised call (including the swap calldata) triggers the fallback,
    ///      which attempts reentrancy. The nonReentrant guard must reject it (ok == false).
    fallback() external payable {
        (bool ok,) = _executor.call(_reentrantCall);
        require(!ok, "ReentrantPool: reentrancy should have been blocked");
    }

    receive() external payable {}
}

/**
 * @notice Mock target that does NOT implement token0() / token1().
 *         Any attempt to route through it must revert at _validateTarget.
 */
contract MockUnwhitelistedRouter {
    function doSomething() external pure returns (uint256) {
        return 42;
    }
}
