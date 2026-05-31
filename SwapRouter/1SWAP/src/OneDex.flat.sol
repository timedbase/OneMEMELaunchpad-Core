// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// src/interfaces/IPermit2.sol

/**
 * @notice Minimal Permit2 interface — ISignatureTransfer subset only.
 *         Full spec: https://github.com/Uniswap/permit2
 *
 *         Deployed at 0x000000000022D473030F116dDEE9F6B43aC78BA3 on all chains.
 */
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

// src/libraries/SafeTransfer.sol

/**
 * @title  SafeTransfer
 * @notice Low-level token helpers that handle every non-standard ERC-20 variant:
 *         - tokens with no return value (USDT, BNB-pegged)
 *         - tokens that return false on failure
 *         - fee-on-transfer and rebasing (callers use balance-delta accounting)
 *
 * @dev    All functions use raw .call()/.staticcall() and manually decode the
 *         optional bool return value, matching OpenZeppelin SafeERC20 semantics
 *         without the OZ import overhead.
 */
library SafeTransfer {

    error TransferFailed();
    error ApproveFailed();

    // ERC-20 selectors cached as constants to save PUSH32 overhead.
    bytes4 private constant _TRANSFER      = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant _TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 private constant _APPROVE       = 0x095ea7b3; // approve(address,uint256)
    bytes4 private constant _BALANCE_OF    = 0x70a08231; // balanceOf(address)

    /// @notice ERC-20 transfer — handles tokens that return nothing.
    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(_TRANSFER, to, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /// @notice ERC-20 transferFrom — handles tokens that return nothing.
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(_TRANSFER_FROM, from, to, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /**
     * @notice ERC-20 approve — handles tokens that return nothing.
     * @dev    Callers are responsible for the USDT-safe reset-before-set pattern
     *         (call safeApprove(token, spender, 0) before a non-zero amount).
     */
    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(_APPROVE, spender, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert ApproveFailed();
    }

    /**
     * @notice Read token balance via staticcall.
     * @dev    Returns 0 on failure rather than reverting — callers handle zero-balance
     *         semantics (e.g. dust checks).
     */
    function balanceOf(address token, address account) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSelector(_BALANCE_OF, account)
        );
        bal = (ok && ret.length >= 32) ? abi.decode(ret, (uint256)) : 0;
    }
}

// src/OneDex.sol

/// @title 1Dex — Aggregation Executor

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
        address feeRecipient_
    ) {
        if (wbnb_ == address(0) || permit2_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        WBNB         = wbnb_;
        PERMIT2      = permit2_;
        owner        = msg.sender;
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

    function _executeSteps(Step[] memory steps, uint256 n) internal {
        for (uint256 i; i < n; ) {
            Step memory step = steps[i];

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

    function _handleV3Callback(int256 amt0, int256 amt1, bytes calldata data) internal {
        SwapCallbackData memory d = abi.decode(data, (SwapCallbackData));
        uint256 owed = amt0 > 0 ? uint256(amt0) : uint256(amt1);
        SafeTransfer.safeTransfer(d.tokenIn, msg.sender, owed);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        _handleV3Callback(amount0Delta, amount1Delta, data);
    }

    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        _handleV3Callback(amount0Delta, amount1Delta, data);
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

