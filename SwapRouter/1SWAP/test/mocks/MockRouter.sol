// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/**
 * @notice Configurable mock router for unit tests.
 *
 * Supports four swap modes:
 *   swapTokens       — ERC-20 in, ERC-20 out
 *   swapTokensForBNB — ERC-20 in, native BNB out
 *   swapBNBForTokens — native BNB in, ERC-20 out  (payable)
 *   revertWith       — unconditionally revert (for revert-bubbling tests)
 */
contract MockRouter {
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

    /// @notice Revert with an encoded custom error — used for typed-error bubble tests.
    function revertWithCustomError() external pure {
        // Encode a fake custom error: MockError(uint256 code)
        assembly {
            // selector = keccak256("MockError(uint256)")[0:4]
            let ptr := mload(0x40)
            mstore(ptr,        0x1b6b3a6200000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr,4), 42)
            revert(ptr, 36)
        }
    }
}

/**
 * @notice Mock router that attempts reentrancy into the executor on call.
 *         Used to verify the nonReentrant guard fires correctly.
 */
contract MockReentrantRouter {
    address public executor;
    bytes   public reentrantCall;

    constructor(address executor_, bytes memory reentrantCall_) {
        executor     = executor_;
        reentrantCall = reentrantCall_;
    }

    fallback() external payable {
        // Attempt to re-enter the executor
        (bool ok,) = executor.call(reentrantCall);
        // We expect this to fail with Reentrancy — propagate the result
        require(!ok, "MockReentrantRouter: reentrancy should have failed");
    }

    receive() external payable {}
}

/**
 * @notice Mock router that is intentionally NOT whitelisted.
 *         Any call to it should revert at the whitelist gate.
 */
contract MockUnwhitelistedRouter {
    function doSomething() external pure returns (uint256) {
        return 42;
    }
}
