// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title 1Dex — Aggregation Executor

import {SafeTransfer} from "./libraries/SafeTransfer.sol";
import {IPermit2}     from "./interfaces/IPermit2.sol";

struct Step {
    address target;
    uint256 value;
    bytes   callData;
    address approveToken;
    uint256 approveAmt;
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
event TargetAdded(address indexed target);
event TargetRemoved(address indexed target);
event ExecutorPaused(address indexed by);
event ExecutorUnpaused(address indexed by);
event OwnershipTransferInitiated(address indexed proposed);
event OwnershipTransferred(address indexed previous, address indexed next);

contract OneDex {
    using SafeTransfer for address;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _status = _NOT_ENTERED;

    uint256 public constant FEE_BPS = 50; // 0.5 %

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    bool    private _isPaused;

    address public immutable WBNB;
    address public immutable PERMIT2;

    mapping(address => bool) public allowedTargets;

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

    constructor(address wbnb_, address initialOwner, address permit2_, address feeRecipient_) {
        if (wbnb_ == address(0) || initialOwner == address(0) || permit2_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        WBNB         = wbnb_;
        PERMIT2      = permit2_;
        owner        = initialOwner;
        feeRecipient = feeRecipient_;
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

        // Fee on input: deducted before steps so the off-chain route sees the reduced amount.
        if (feeOnInput) _collectFee(tokenIn, actualIn);

        _executeSteps(steps, n);

        amountOut = tokenOut == address(0)
            ? address(this).balance
            : SafeTransfer.balanceOf(tokenOut, address(this));

        // Fee on output: deducted from gross output; minAmountOut is checked against net.
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

    function _executeSteps(Step[] memory steps, uint256 n) internal {
        for (uint256 i; i < n; ) {
            Step memory step = steps[i];

            if (!allowedTargets[step.target]) revert RouterNotWhitelisted(step.target);

            // USDT-safe: zero → amount
            if (step.approveToken != address(0)) {
                SafeTransfer.safeApprove(step.approveToken, step.target, 0);
                SafeTransfer.safeApprove(step.approveToken, step.target, step.approveAmt);
            }

            uint256 snapBefore = step.tokenOut == address(0)
                ? address(this).balance
                : SafeTransfer.balanceOf(step.tokenOut, address(this));

            (bool ok, bytes memory ret) = step.target.call{value: step.value}(step.callData);
            if (!ok) {
                assembly { revert(add(ret, 32), mload(ret)) }
            }

            // When a step both sends and receives native BNB, afterBal is already reduced by
            // step.value, so: delta = afterBal + step.value - snapBefore = bnbReceived.
            uint256 delta;
            if (step.tokenOut == address(0)) {
                delta = address(this).balance + step.value - snapBefore;
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

    // ── Fee management ────────────────────────────────────────────────────────

    function setFeeRecipient(address recipient_) external onlyOwner {
        if (recipient_ == address(0)) revert ZeroAddress();
        feeRecipient = recipient_;
        emit FeeRecipientUpdated(recipient_);
    }

    // ── Target whitelist ──────────────────────────────────────────────────────

    function addTarget(address target) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[target] = true;
        emit TargetAdded(target);
    }

    function addTargets(address[] calldata targets) external onlyOwner {
        uint256 len = targets.length;
        for (uint256 i; i < len; ) {
            if (targets[i] == address(0)) revert ZeroAddress();
            allowedTargets[targets[i]] = true;
            emit TargetAdded(targets[i]);
            unchecked { ++i; }
        }
    }

    function removeTarget(address target) external onlyOwner {
        allowedTargets[target] = false;
        emit TargetRemoved(target);
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
