// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title 1Dex — Aggregation Executor

import {SafeTransfer}  from "./libraries/SafeTransfer.sol";
import {IPermit2}      from "./interfaces/IPermit2.sol";
import {IUniV2Factory} from "./interfaces/IUniV2Factory.sol";
import {IUniV2Pair}    from "./interfaces/IUniV2Pair.sol";
import {IUniV3Factory} from "./interfaces/IUniV3Factory.sol";
import {IUniV3Pool}    from "./interfaces/IUniV3Pool.sol";

/// @dev Passed as `data` in every V3 swap call so the callback can pay the pool.
struct SwapCallbackData {
    address tokenIn;
    uint256 amountIn;
    address payer;   // always address(this) — OneDex holds the tokens
}

struct Step {
    address target;
    uint256 value;
    bytes   callData;
    address approveToken;      // approve before calling target (V3 pool style)
    uint256 approveAmt;
    address preTransferToken;  // transfer into target before calling (V2 pair style)
    uint256 preTransferAmt;    // 0 = skip
    address tokenOut;
    uint256 minDelta;
}

error Reentrancy();
error Paused();
error NotOwner();
error NotPendingOwner();
error ZeroAddress();
error ZeroAmount();
error EmptyRoute();
error DeadlineExpired();
error RouterNotWhitelisted(address target);
error InsufficientOutput(uint256 actual, uint256 minimum);
error NativeSendFailed();
error NativeNotPermitted();

event Swapped(
    address indexed user,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256         amountIn,
    uint256         amountOut,
    address         recipient
);
event FeeCollected(address indexed token, uint256 amount);
event FeeRecipientUpdated(address indexed recipient);
event ExecutorPaused(address indexed by);
event ExecutorUnpaused(address indexed by);
event OwnershipTransferInitiated(address indexed proposed);
event OwnershipTransferred(address indexed previous, address indexed next);

contract OneDex {
    using SafeTransfer for address;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _status = _NOT_ENTERED;

    uint256 public constant FEE_BPS = 30; // 0.3 %

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    bool    private _isPaused;

    address public immutable WBNB;
    address public immutable PERMIT2;
    address public immutable UNI_V2_FACTORY;
    address public immutable CAKE_V2_FACTORY;
    address public immutable UNI_V3_FACTORY;
    address public immutable CAKE_V3_FACTORY;

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier whenNotPaused() {
        if (_isPaused) revert Paused();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address wbnb_,
        address permit2_,
        address feeRecipient_,
        address uniV2Factory_,
        address cakeV2Factory_,
        address uniV3Factory_,
        address cakeV3Factory_
    ) {
        if (wbnb_ == address(0) || permit2_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        WBNB            = wbnb_;
        PERMIT2         = permit2_;
        UNI_V2_FACTORY  = uniV2Factory_;
        CAKE_V2_FACTORY = cakeV2Factory_;
        UNI_V3_FACTORY  = uniV3Factory_;
        CAKE_V3_FACTORY = cakeV3Factory_;
        owner           = msg.sender;
        feeRecipient    = feeRecipient_;
    }

    receive() external payable {}

    // ── Entry points ──────────────────────────────────────────────────────────

    function execute(
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minAmountOut,
        address        recipient,
        uint256        deadline,
        bytes calldata executionData
    ) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0))    revert ZeroAddress();

        uint256 actualIn;
        if (tokenIn == address(0)) {
            actualIn = msg.value;
            if (actualIn == 0) revert ZeroAmount();
        } else {
            uint256 before = SafeTransfer.balanceOf(tokenIn, address(this));
            SafeTransfer.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
            actualIn = SafeTransfer.balanceOf(tokenIn, address(this)) - before;
            if (actualIn == 0) revert ZeroAmount();
        }

        amountOut = _swap(tokenIn, actualIn, tokenOut, minAmountOut, recipient, executionData);
        emit Swapped(msg.sender, tokenIn, tokenOut, actualIn, amountOut, recipient);
    }

    function executeWithPermit2(
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minAmountOut,
        address        recipient,
        uint256        deadline,
        bytes calldata executionData,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0))    revert ZeroAddress();
        if (tokenIn   == address(0))    revert NativeNotPermitted();

        uint256 actualIn = _pullPermit2(tokenIn, amountIn, permit, signature);

        amountOut = _swap(tokenIn, actualIn, tokenOut, minAmountOut, recipient, executionData);
        emit Swapped(msg.sender, tokenIn, tokenOut, actualIn, amountOut, recipient);
    }

    function _pullPermit2(
        address tokenIn,
        uint256 amountIn,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) internal returns (uint256 actualIn) {
        uint256 before = SafeTransfer.balanceOf(tokenIn, address(this));
        IPermit2(PERMIT2).permitTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: amountIn}),
            msg.sender,
            signature
        );
        actualIn = SafeTransfer.balanceOf(tokenIn, address(this)) - before;
        if (actualIn == 0) revert ZeroAmount();
    }

    // ── Core swap logic ───────────────────────────────────────────────────────

    function _swap(
        address tokenIn,
        uint256 actualIn,
        address tokenOut,
        uint256 minAmountOut,
        address recipient,
        bytes calldata executionData
    ) internal returns (uint256 amountOut) {
        (bool feeOnInput, Step[] memory steps) = abi.decode(executionData, (bool, Step[]));
        uint256 n = steps.length;
        if (n == 0) revert EmptyRoute();

        if (feeOnInput) _collectFee(tokenIn, actualIn);

        _executeSteps(steps, n);

        amountOut = tokenOut == address(0)
            ? address(this).balance
            : SafeTransfer.balanceOf(tokenOut, address(this));

        if (!feeOnInput) amountOut -= _collectFee(tokenOut, amountOut);

        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        _deliver(tokenOut, recipient, amountOut);
    }

    function _collectFee(address token, uint256 basis) internal returns (uint256 fee) {
        address fr = feeRecipient;
        fee = (basis * FEE_BPS) / 10_000;
        if (fee == 0) return 0;
        _deliver(token, fr, fee);
        emit FeeCollected(token, fee);
    }

    /// @dev Reverts if `target` is not a canonical V2 pair or V3 pool
    ///      from one of the four trusted factory immutables.
    ///
    /// Logic:
    ///   1. Call target.token0()  — succeeds on both V2 pairs and V3 pools.
    ///   2. Call target.fee()     — only V3 pools have this; reverts on V2 pairs.
    ///   3. Use the result to route to the correct factory type.
    ///   4. Ask the factory if it recognises this address as its own pair/pool.
    function _validateTarget(address target) internal view {
        address t0;
        address t1;

        try IUniV2Pair(target).token0() returns (address _t0) {
            t0 = _t0;
        } catch {
            revert RouterNotWhitelisted(target);
        }
        t1 = IUniV2Pair(target).token1();

        try IUniV3Pool(target).fee() returns (uint24 fee) {
            // ── V3 pool path ──────────────────────────────────────────────────
            if (UNI_V3_FACTORY  != address(0) &&
                IUniV3Factory(UNI_V3_FACTORY).getPool(t0, t1, fee)  == target) return;
            if (CAKE_V3_FACTORY != address(0) &&
                IUniV3Factory(CAKE_V3_FACTORY).getPool(t0, t1, fee) == target) return;
        } catch {
            // ── V2 pair path ──────────────────────────────────────────────────
            if (UNI_V2_FACTORY  != address(0) &&
                IUniV2Factory(UNI_V2_FACTORY).getPair(t0, t1)  == target) return;
            if (CAKE_V2_FACTORY != address(0) &&
                IUniV2Factory(CAKE_V2_FACTORY).getPair(t0, t1) == target) return;
        }

        revert RouterNotWhitelisted(target);
    }

    function _executeSteps(Step[] memory steps, uint256 n) internal {
        for (uint256 i; i < n; ) {
            Step memory step = steps[i];

            _validateTarget(step.target);

            // V3 pool style: approve target to pull tokens. USDT-safe: zero → amount.
            if (step.approveToken != address(0)) {
                SafeTransfer.safeApprove(step.approveToken, step.target, 0);
                SafeTransfer.safeApprove(step.approveToken, step.target, step.approveAmt);
            }

            // V2 pair style: push tokens into pair before calling swap().
            if (step.preTransferToken != address(0) && step.preTransferAmt > 0) {
                SafeTransfer.safeTransfer(step.preTransferToken, step.target, step.preTransferAmt);
            }

            uint256 snapBefore = step.tokenOut == address(0)
                ? address(this).balance
                : SafeTransfer.balanceOf(step.tokenOut, address(this));

            uint256 sendValue = step.value == type(uint256).max
                ? address(this).balance
                : step.value;
            (bool ok, bytes memory ret) = step.target.call{value: sendValue}(step.callData);
            if (!ok) {
                assembly { revert(add(ret, 32), mload(ret)) }
            }

            // When a step both sends and receives native BNB, afterBal is already reduced by
            // sendValue, so: delta = afterBal + sendValue - snapBefore = bnbReceived.
            uint256 delta;
            if (step.tokenOut == address(0)) {
                delta = address(this).balance + sendValue - snapBefore;
            } else {
                delta = SafeTransfer.balanceOf(step.tokenOut, address(this)) - snapBefore;
            }
            if (delta < step.minDelta) revert InsufficientOutput(delta, step.minDelta);

            if (step.approveToken != address(0)) {
                SafeTransfer.safeApprove(step.approveToken, step.target, 0);
            }

            unchecked { ++i; }
        }
    }

    function _deliver(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeSendFailed();
        } else {
            SafeTransfer.safeTransfer(token, to, amount);
        }
    }

    // ── V3 swap callbacks ─────────────────────────────────────────────────────

    function _handleV3Callback(
        int256  amount0Delta,
        int256  amount1Delta,
        bytes calldata data,
        address factory
    ) internal {
        if (factory == address(0)) revert RouterNotWhitelisted(msg.sender);

        SwapCallbackData memory decoded = abi.decode(data, (SwapCallbackData));

        address pool = IUniV3Factory(factory).getPool(
            IUniV3Pool(msg.sender).token0(),
            IUniV3Pool(msg.sender).token1(),
            IUniV3Pool(msg.sender).fee()
        );
        if (msg.sender != pool || pool == address(0)) revert RouterNotWhitelisted(msg.sender);

        uint256 amountOwed = amount0Delta > 0
            ? uint256(amount0Delta)
            : uint256(amount1Delta);

        SafeTransfer.safeTransfer(decoded.tokenIn, msg.sender, amountOwed);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        _handleV3Callback(amount0Delta, amount1Delta, data, UNI_V3_FACTORY);
    }

    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        _handleV3Callback(amount0Delta, amount1Delta, data, CAKE_V3_FACTORY);
    }

    // ── Fee management ────────────────────────────────────────────────────────

    function setFeeRecipient(address recipient_) external onlyOwner {
        if (recipient_ == address(0)) revert ZeroAddress();
        feeRecipient = recipient_;
        emit FeeRecipientUpdated(recipient_);
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    function pause() external onlyOwner {
        _isPaused = true;
        emit ExecutorPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        _isPaused = false;
        emit ExecutorUnpaused(msg.sender);
    }

    function isPaused() external view returns (bool) {
        return _isPaused;
    }

    // ── Ownership (two-step) ──────────────────────────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner        = msg.sender;
        pendingOwner = address(0);
    }

    // ── Emergency rescue ──────────────────────────────────────────────────────

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        SafeTransfer.safeTransfer(token, to, amount);
    }

    function rescueNative(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }
}
