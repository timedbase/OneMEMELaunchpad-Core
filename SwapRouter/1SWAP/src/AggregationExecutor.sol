// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransfer} from "./libraries/SafeTransfer.sol";

// ─────────────────────────────────────────────────────────────────────────────
// File-level types — importable by offchain builders and tests
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @notice A single atomic execution step.
 *
 * The off-chain API builds one Step per router call and ABI-encodes the array
 * into `executionData`. The executor never interprets route semantics; it only
 * validates the target whitelist and verifies balance deltas.
 *
 * @param target        Whitelisted router / AMM / bonding-curve to call.
 * @param value         Native BNB to forward with the call (0 if ERC-20 only).
 * @param callData      Fully-encoded router calldata built off-chain.
 * @param approveToken  ERC-20 to approve to `target` before the call.
 *                      address(0) → skip approval (e.g. native BNB steps).
 * @param approveAmt    Exact amount to approve.  Executor resets to 0 after.
 * @param tokenOut      Token this step outputs.  address(0) → native BNB.
 * @param minDelta      Minimum required balance increase for `tokenOut`.
 *                      Reverts with InsufficientOutput if not met.
 */
struct Step {
    address target;
    uint256 value;
    bytes   callData;
    address approveToken;
    uint256 approveAmt;
    address tokenOut;
    uint256 minDelta;
}

// ─────────────────────────────────────────────────────────────────────────────
// File-level errors
// ─────────────────────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────────────────────
// File-level events
// ─────────────────────────────────────────────────────────────────────────────

event Swapped(
    address indexed user,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256         amountIn,
    uint256         amountOut,
    address         recipient
);
event TargetAdded(address indexed target);
event TargetRemoved(address indexed target);
event ExecutorPaused(address indexed by);
event ExecutorUnpaused(address indexed by);
event OwnershipTransferInitiated(address indexed proposed);
event OwnershipTransferred(address indexed previous, address indexed next);

// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title  AggregationExecutor — 1SWAP
 * @author OneMEME
 * @notice Calldata-driven, balance-differential swap aggregation executor.
 *
 *         Core guarantees:
 *         1. NEVER trusts router return values — every output is verified via
 *            before/after balanceOf() snapshots (handles FOT and rebasing tokens).
 *         2. Only whitelisted targets can be called — no arbitrary code execution.
 *         3. Exact-approval + immediate reset — no lingering allowances (USDT-safe).
 *         4. Fully stateless between executions — all routing state is in calldata.
 *
 * @dev    Off-chain API builds a Step[] for each route, ABI-encodes it, and
 *         passes it as `executionData`.  The contract decodes and runs each step
 *         sequentially, enforcing per-step minDelta and a final minAmountOut.
 *
 *         Native BNB semantics:
 *         - tokenIn  == address(0) → pull from msg.value
 *         - tokenOut == address(0) → deliver native BNB to recipient
 *         - step.tokenOut == address(0) → measure address(this).balance delta
 *         - step.value > 0 → forward that BNB with the step call;
 *           delta formula adds step.value back so it reflects what was RECEIVED,
 *           not the net change (prevents underflow when sending-and-receiving BNB).
 *
 *         WBNB wrap/unwrap:
 *         Steps can target WBNB directly (deposit / withdraw) — just whitelist it.
 *         The off-chain API inserts wrap/unwrap steps wherever the route needs them.
 */
contract AggregationExecutor {
    using SafeTransfer for address;

    // ─── Reentrancy ───────────────────────────────────────────────────────────
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _status = _NOT_ENTERED;

    // ─── Ownership ────────────────────────────────────────────────────────────
    address public owner;
    address public pendingOwner;

    // ─── Pause ────────────────────────────────────────────────────────────────
    bool private _isPaused;

    // ─── Immutables ───────────────────────────────────────────────────────────
    /// @notice WBNB contract address — stored for off-chain convenience; not used
    ///         in execution logic (WBNB steps are handled like any other target).
    address public immutable WBNB;

    // ─── Target whitelist ─────────────────────────────────────────────────────
    /// @notice Only addresses in this mapping may be called during execution.
    mapping(address => bool) public allowedTargets;

    // ─── Modifiers ────────────────────────────────────────────────────────────

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

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param wbnb_         WBNB contract on the target chain (BSC: 0xbb4C…095c).
     * @param initialOwner  Address that receives ownership; will manage the whitelist.
     */
    constructor(address wbnb_, address initialOwner) {
        if (wbnb_ == address(0) || initialOwner == address(0)) revert ZeroAddress();
        WBNB  = wbnb_;
        owner = initialOwner;
    }

    receive() external payable {}

    // ─── Core execution ───────────────────────────────────────────────────────

    /**
     * @notice Execute a multi-step swap route.
     *
     * @param tokenIn        Input token.  address(0) = native BNB (use msg.value).
     * @param amountIn       Amount to pull from msg.sender (ignored when native).
     * @param tokenOut       Final output token.  address(0) = native BNB.
     * @param minAmountOut   Minimum acceptable final output; reverts if not met.
     * @param recipient      Receives the final output.  Must not be address(0).
     * @param deadline       Unix timestamp after which the call reverts.
     * @param executionData  ABI-encoded Step[] produced by the off-chain API.
     *
     * @return amountOut     Actual amount delivered to `recipient`.
     */
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

        // ── 1. Pull tokenIn ─────────────────────────────────────────────────
        // Balance-delta pattern: actual received may be less than amountIn for
        // fee-on-transfer tokens.  We record actualIn for the Swapped event.
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

        // ── 2. Decode and execute steps ─────────────────────────────────────
        Step[] memory steps = abi.decode(executionData, (Step[]));
        uint256 n = steps.length;
        if (n == 0) revert EmptyRoute();
        _executeSteps(steps, n);

        // ── 3. Verify final balance and deliver ──────────────────────────────
        amountOut = tokenOut == address(0)
            ? address(this).balance
            : SafeTransfer.balanceOf(tokenOut, address(this));

        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        _deliver(tokenOut, recipient, amountOut);

        emit Swapped(msg.sender, tokenIn, tokenOut, actualIn, amountOut, recipient);
    }

    // ─── Internal execution engine ────────────────────────────────────────────

    /**
     * @dev  Separated from execute() to keep that function's stack frame under
     *       the 16-slot EVM limit.
     */
    function _executeSteps(Step[] memory steps, uint256 n) internal {
        for (uint256 i; i < n; ) {
            Step memory step = steps[i];

            // ── Whitelist gate ──────────────────────────────────────────────
            if (!allowedTargets[step.target]) revert RouterNotWhitelisted(step.target);

            // ── Exact approval (USDT-safe: zero → amount) ───────────────────
            if (step.approveToken != address(0)) {
                SafeTransfer.safeApprove(step.approveToken, step.target, 0);
                SafeTransfer.safeApprove(step.approveToken, step.target, step.approveAmt);
            }

            // ── Pre-call balance snapshot ───────────────────────────────────
            uint256 snapBefore = step.tokenOut == address(0)
                ? address(this).balance
                : SafeTransfer.balanceOf(step.tokenOut, address(this));

            // ── Execute — bubble revert reason on failure ───────────────────
            (bool ok, bytes memory ret) = step.target.call{value: step.value}(step.callData);
            if (!ok) {
                // Propagate the exact revert payload from the router so the
                // caller can decode the underlying error.
                assembly { revert(add(ret, 32), mload(ret)) }
            }

            // ── Post-call delta verification ────────────────────────────────
            // For native BNB steps: add step.value back so delta reflects
            // what was received (not the net BNB change after paying step.value).
            //   delta = afterBal + step.value − snapBefore
            //         = (snapBefore − step.value + bnbReceived) + step.value − snapBefore
            //         = bnbReceived   ← always ≥ 0, no underflow
            uint256 delta;
            if (step.tokenOut == address(0)) {
                delta = address(this).balance + step.value - snapBefore;
            } else {
                delta = SafeTransfer.balanceOf(step.tokenOut, address(this)) - snapBefore;
            }
            if (delta < step.minDelta) revert InsufficientOutput(delta, step.minDelta);

            // ── Reset approval — no lingering allowances ─────────────────────
            if (step.approveToken != address(0)) {
                SafeTransfer.safeApprove(step.approveToken, step.target, 0);
            }

            unchecked { ++i; }
        }
    }

    /// @dev Transfer output to recipient.  Reverts on failed native send.
    function _deliver(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeSendFailed();
        } else {
            SafeTransfer.safeTransfer(token, to, amount);
        }
    }

    // ─── Target whitelist management ──────────────────────────────────────────

    /// @notice Whitelist a single target address.
    function addTarget(address target) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[target] = true;
        emit TargetAdded(target);
    }

    /// @notice Whitelist multiple target addresses in one transaction.
    function addTargets(address[] calldata targets) external onlyOwner {
        uint256 len = targets.length;
        for (uint256 i; i < len; ) {
            if (targets[i] == address(0)) revert ZeroAddress();
            allowedTargets[targets[i]] = true;
            emit TargetAdded(targets[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Remove a target from the whitelist.
    function removeTarget(address target) external onlyOwner {
        allowedTargets[target] = false;
        emit TargetRemoved(target);
    }

    // ─── Pause ────────────────────────────────────────────────────────────────

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

    // ─── Ownership (two-step) ─────────────────────────────────────────────────

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

    // ─── Emergency rescue ─────────────────────────────────────────────────────

    /// @notice Rescue ERC-20 tokens accidentally sent to or stuck in the contract.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        SafeTransfer.safeTransfer(token, to, amount);
    }

    /// @notice Rescue native BNB stuck in the contract.
    function rescueNative(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }
}
