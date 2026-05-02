// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/IAdapter.sol";

/**
 * @title  OneMEMEAggregator
 * @notice Platform-agnostic swap aggregator. Executes trades through a registry
 *         of pluggable adapters — any DEX or trading platform can be added by
 *         deploying a new adapter and calling registerAdapter(). No contract
 *         upgrade needed for new integrations.
 *
 * Fee model
 * ─────────
 *   1% (100 bps) is deducted from the gross input before the swap.
 *   The fee is always collected in the INPUT asset (BNB or ERC-20).
 *   The recipient receives the DEX's full output on the net 99%.
 *
 * Routing model
 * ─────────────
 *   All routing logic and quotes are built offchain. The aggregator is a
 *   pure executor: it charges the fee, selects the adapter, forwards the
 *   net funds, and calls adapter.execute() with the offchain-provided data.
 *
 * Adding a new DEX or platform
 * ────────────────────────────
 *   1. Write a contract that implements IAdapter.
 *   2. Deploy it with this aggregator's address as constructor arg.
 *   3. Call registerAdapter(id, adapterAddress).
 *   No other changes required.
 *
 * Native BNB convention
 * ─────────────────────
 *   tokenIn  == address(0)  →  caller sends BNB as msg.value (amountIn ignored).
 *   tokenOut == address(0)  →  output is delivered as native BNB to `to`.
 */

// ─── Main Contract ────────────────────────────────────────────────────────────

contract OneMEMEAggregator {

    // ── Constants ────────────────────────────────────────────────────────────

    uint256 private constant FEE_BPS   = 100;     // 1%
    uint256 private constant BPS_DENOM = 10_000;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    // ── State ────────────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;
    address public feeRecipient;

    struct AdapterEntry {
        address addr;
        bool    enabled;
        string  name;    // cached from IAdapter(addr).name() at registration
    }

    /// @dev id → adapter. id is an arbitrary bytes32 chosen by the owner,
    ///      e.g. keccak256("PANCAKE_V2") or keccak256("CUSTOM_PLATFORM").
    mapping(bytes32 => AdapterEntry) public adapters;

    /// @dev ordered list of registered adapter IDs for enumeration
    bytes32[] private _adapterIds;

    uint256 private _status = _NOT_ENTERED;

    // ── Events ───────────────────────────────────────────────────────────────

    event Swapped(
        address indexed user,
        bytes32 indexed adapterId,
        address         tokenIn,        // address(0) = native BNB
        address         tokenOut,       // address(0) = native BNB
        uint256         grossAmountIn,
        uint256         feeCharged,
        uint256         amountOut       // exact for V3 adapters; 0 for V2 adapters
    );
    event AdapterRegistered(bytes32 indexed id, address indexed addr, string adapterName);
    event AdapterEnabled(bytes32 indexed id);
    event AdapterDisabled(bytes32 indexed id);
    event AdapterUpgraded(bytes32 indexed id, address indexed oldAddr, address indexed newAddr);
    event FeeRecipientSet(address indexed previous, address indexed next);
    event OwnershipTransferInitiated(address indexed proposed);
    event OwnershipTransferred(address indexed previous, address indexed next);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error ZeroRecipient();
    error Reentrancy();
    error NoNativeValue();
    error DeadlineExpired();
    error TransferFailed();
    error NativeSendFailed();
    error AdapterNotFound();
    error AdapterIsDisabled();
    error AdapterAlreadyExists();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address feeRecipient_) {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        owner        = msg.sender;
        feeRecipient = feeRecipient_;
    }

    /// @dev Required for receiving BNB from adapters and from potential refunds.
    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────
    // CORE SWAP
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Execute a swap through a registered adapter.
     *
     * @param adapterId   Registry key of the adapter to use.
     *                    e.g. keccak256(abi.encodePacked("PANCAKE_V2"))
     * @param tokenIn     Input token. address(0) = native BNB; attach as msg.value.
     * @param amountIn    Gross input amount (ignored when tokenIn == address(0)).
     * @param tokenOut    Output token. address(0) = native BNB output.
     * @param minOut      Minimum acceptable output. Forwarded to the adapter which
     *                    passes it to the DEX. Revert if output < minOut.
     * @param to          Final recipient of the output tokens or BNB.
     * @param deadline    Unix timestamp. Reverts if block.timestamp > deadline.
     *                    Provides time-based slippage protection for all DEX types,
     *                    including V3 (SwapRouter02 removed deadline from its struct).
     *                    V2 adapters additionally enforce deadline inside adapterData
     *                    at the DEX level.
     * @param adapterData Adapter-specific encoded routing params built offchain.
     *                    See the target adapter's natspec for the exact encoding.
     * @return amountOut  Actual output delivered to `to`. Exact for V3 adapters;
     *                    0 for V2 BNB-out swaps (DEX enforces minOut internally).
     */
    function swap(
        bytes32        adapterId,
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        uint256        deadline,
        bytes calldata adapterData
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (to == address(0)) revert ZeroRecipient();

        AdapterEntry storage entry = adapters[adapterId];
        if (entry.addr == address(0)) revert AdapterNotFound();
        if (!entry.enabled)          revert AdapterIsDisabled();

        address adapterAddr = entry.addr;

        if (tokenIn == address(0)) {
            // ── Native BNB input ─────────────────────────────────────────────
            if (msg.value == 0) revert NoNativeValue();
            (uint256 fee, uint256 netIn) = _splitFee(msg.value);
            _sendNative(feeRecipient, fee);

            // Forward net BNB to the adapter via msg.value
            amountOut = IAdapter(adapterAddr).execute{value: netIn}(
                address(0), netIn, tokenOut, minOut, to, adapterData
            );
            emit Swapped(msg.sender, adapterId, address(0), tokenOut, msg.value, fee, amountOut);

        } else {
            // ── ERC-20 input ─────────────────────────────────────────────────
            // Delegated to an internal function to keep the stack depth of this
            // frame below the 16-slot EVM limit when compiled without --via-ir.
            uint256 fee;
            (amountOut, fee) = _swapERC20(
                adapterAddr, tokenIn, amountIn, tokenOut, minOut, to, adapterData
            );
            // Event uses the user-declared amountIn for gross display; fee reflects reality.
            emit Swapped(msg.sender, adapterId, tokenIn, tokenOut, amountIn, fee, amountOut);
        }
    }

    /// @dev ERC-20 swap path extracted to its own stack frame to prevent
    ///      "stack too deep" under legacy (non-IR) codegen.
    function _swapERC20(
        address        adapterAddr,
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata adapterData
    ) internal returns (uint256 amountOut, uint256 fee) {
        // Measure actual received — handles fee-on-transfer tokens correctly.
        uint256 balBefore = _balanceOf(tokenIn, address(this));
        _pullToken(tokenIn, msg.sender, address(this), amountIn);
        uint256 received = _balanceOf(tokenIn, address(this)) - balBefore;

        uint256 netIn;
        (fee, netIn) = _splitFee(received);
        _safeTransfer(tokenIn, feeRecipient, fee);

        // Transfer net tokens directly to the adapter — it owns them on entry to execute().
        _safeTransfer(tokenIn, adapterAddr, netIn);

        amountOut = IAdapter(adapterAddr).execute(
            tokenIn, netIn, tokenOut, minOut, to, adapterData
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADAPTER REGISTRY
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Register a new adapter. The adapter must implement IAdapter.
     *
     * @param id      Unique bytes32 key. Convention: keccak256(abi.encodePacked("DEXNAME")).
     * @param addr    Deployed adapter contract address.
     * @param enabled Whether the adapter is immediately usable for swaps.
     */
    function registerAdapter(bytes32 id, address addr, bool enabled) external onlyOwner {
        if (addr == address(0))            revert ZeroAddress();
        if (adapters[id].addr != address(0)) revert AdapterAlreadyExists();

        string memory adapterName = IAdapter(addr).name();
        adapters[id] = AdapterEntry({ addr: addr, enabled: enabled, name: adapterName });
        _adapterIds.push(id);

        emit AdapterRegistered(id, addr, adapterName);
    }

    /// @notice Enable an adapter so it can be used in swap().
    function enableAdapter(bytes32 id) external onlyOwner {
        if (adapters[id].addr == address(0)) revert AdapterNotFound();
        adapters[id].enabled = true;
        emit AdapterEnabled(id);
    }

    /// @notice Disable an adapter without removing it from the registry.
    function disableAdapter(bytes32 id) external onlyOwner {
        if (adapters[id].addr == address(0)) revert AdapterNotFound();
        adapters[id].enabled = false;
        emit AdapterDisabled(id);
    }

    /**
     * @notice Swap in a new implementation for an existing adapter slot.
     *         Use this to upgrade an adapter without changing its registry ID,
     *         preserving any offchain references to the ID.
     *
     * @param id      Existing adapter ID.
     * @param newAddr New adapter contract (must implement IAdapter).
     */
    function upgradeAdapter(bytes32 id, address newAddr) external onlyOwner {
        if (adapters[id].addr == address(0)) revert AdapterNotFound();
        if (newAddr == address(0))           revert ZeroAddress();

        // Read from the new adapter before writing state (checks-effects-interactions).
        address oldAddr  = adapters[id].addr;
        string memory newName = IAdapter(newAddr).name();

        adapters[id].addr = newAddr;
        adapters[id].name = newName;

        emit AdapterUpgraded(id, oldAddr, newAddr);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // REGISTRY VIEWS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Number of registered adapters (including disabled ones).
    function adapterCount() external view returns (uint256) {
        return _adapterIds.length;
    }

    /// @notice Enumerate registered adapters by index.
    function adapterAt(uint256 index)
        external view
        returns (bytes32 id, address addr, bool enabled, string memory adapterName)
    {
        id = _adapterIds[index];
        AdapterEntry storage e = adapters[id];
        return (id, e.addr, e.enabled, e.name);
    }

    /// @notice Return all registered adapter IDs.
    function allAdapterIds() external view returns (bytes32[] memory) {
        return _adapterIds;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADMIN
    // ─────────────────────────────────────────────────────────────────────────

    function setFeeRecipient(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit FeeRecipientSet(feeRecipient, next);
        feeRecipient = next;
    }

    /// @notice Step 1 — propose a new owner.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(newOwner);
    }

    /// @notice Step 2 — new owner accepts.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner        = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Rescue ERC-20 tokens stuck in this contract.
    function rescueTokens(address token, address recipient, uint256 amount) external onlyOwner {
        _safeTransfer(token, recipient, amount);
    }

    /// @notice Rescue native BNB stuck in this contract.
    function rescueNative(address recipient, uint256 amount) external onlyOwner {
        _sendNative(recipient, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    function _balanceOf(address token, address account) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        bal = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    function _splitFee(uint256 gross) internal pure returns (uint256 fee, uint256 netIn) {
        fee   = (gross * FEE_BPS) / BPS_DENOM;
        netIn = gross - fee;
    }

    function _pullToken(address token, address from, address to_, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to_, amount)  // transferFrom
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _safeTransfer(address token, address to_, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to_, amount)  // transfer
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _sendNative(address to_, uint256 amount) internal {
        (bool ok,) = to_.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }
}
