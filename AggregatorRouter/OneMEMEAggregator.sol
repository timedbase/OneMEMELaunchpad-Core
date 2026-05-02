// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/IAdapter.sol";

/**
 * @title  OneMEMEAggregator
 * @notice Platform-agnostic swap aggregator. Executes trades through a registry of pluggable
 *         adapters. All routing is done offchain; the aggregator is a pure executor.
 *         tokenIn/tokenOut == address(0) denotes native BNB.
 */
contract OneMEMEAggregator {

    uint256 private constant FEE_BPS   = 50;
    uint256 private constant BPS_DENOM = 10_000;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    address public owner;
    address public pendingOwner;
    address public feeRecipient;

    struct AdapterEntry {
        address addr;
        bool    enabled;
        string  name;
    }

    mapping(bytes32 => AdapterEntry) public adapters;

    bytes32[] private _adapterIds;

    uint256 private _status = _NOT_ENTERED;

    event Swapped(
        address indexed user,
        bytes32 indexed adapterId,
        address         tokenIn,
        address         tokenOut,
        uint256         grossAmountIn,
        uint256         feeCharged,
        uint256         amountOut
    );
    event AdapterRegistered(bytes32 indexed id, address indexed addr, string adapterName);
    event AdapterEnabled(bytes32 indexed id);
    event AdapterDisabled(bytes32 indexed id);
    event AdapterUpgraded(bytes32 indexed id, address indexed oldAddr, address indexed newAddr);
    event FeeRecipientSet(address indexed previous, address indexed next);
    event OwnershipTransferInitiated(address indexed proposed);
    event OwnershipTransferred(address indexed previous, address indexed next);

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

    constructor(address feeRecipient_) {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        owner        = msg.sender;
        feeRecipient = feeRecipient_;
    }

    receive() external payable {}

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
            if (msg.value == 0) revert NoNativeValue();
            (uint256 fee, uint256 netIn) = _splitFee(msg.value);
            _sendNative(feeRecipient, fee);
            amountOut = IAdapter(adapterAddr).execute{value: netIn}(
                address(0), netIn, tokenOut, minOut, to, adapterData
            );
            emit Swapped(msg.sender, adapterId, address(0), tokenOut, msg.value, fee, amountOut);
        } else {
            uint256 fee;
            (amountOut, fee) = _swapERC20(adapterAddr, tokenIn, amountIn, tokenOut, minOut, to, adapterData);
            emit Swapped(msg.sender, adapterId, tokenIn, tokenOut, amountIn, fee, amountOut);
        }
    }

    // ERC-20 swap extracted to its own stack frame to stay under the 16-slot EVM limit.
    function _swapERC20(
        address        adapterAddr,
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata adapterData
    ) internal returns (uint256 amountOut, uint256 fee) {
        uint256 balBefore = _balanceOf(tokenIn, address(this));
        _pullToken(tokenIn, msg.sender, address(this), amountIn);
        uint256 received = _balanceOf(tokenIn, address(this)) - balBefore;

        uint256 netIn;
        (fee, netIn) = _splitFee(received);
        _safeTransfer(tokenIn, feeRecipient, fee);
        _safeTransfer(tokenIn, adapterAddr, netIn);

        amountOut = IAdapter(adapterAddr).execute(tokenIn, netIn, tokenOut, minOut, to, adapterData);
    }

    function registerAdapter(bytes32 id, address addr, bool enabled) external onlyOwner {
        if (addr == address(0))              revert ZeroAddress();
        if (adapters[id].addr != address(0)) revert AdapterAlreadyExists();
        string memory adapterName = IAdapter(addr).name();
        adapters[id] = AdapterEntry({ addr: addr, enabled: enabled, name: adapterName });
        _adapterIds.push(id);
        emit AdapterRegistered(id, addr, adapterName);
    }

    function enableAdapter(bytes32 id) external onlyOwner {
        if (adapters[id].addr == address(0)) revert AdapterNotFound();
        adapters[id].enabled = true;
        emit AdapterEnabled(id);
    }

    function disableAdapter(bytes32 id) external onlyOwner {
        if (adapters[id].addr == address(0)) revert AdapterNotFound();
        adapters[id].enabled = false;
        emit AdapterDisabled(id);
    }

    function upgradeAdapter(bytes32 id, address newAddr) external onlyOwner {
        if (adapters[id].addr == address(0)) revert AdapterNotFound();
        if (newAddr == address(0))           revert ZeroAddress();
        address oldAddr = adapters[id].addr;
        string memory newName = IAdapter(newAddr).name();
        adapters[id].addr = newAddr;
        adapters[id].name = newName;
        emit AdapterUpgraded(id, oldAddr, newAddr);
    }

    function adapterCount() external view returns (uint256) { return _adapterIds.length; }

    function adapterAt(uint256 index)
        external view
        returns (bytes32 id, address addr, bool enabled, string memory adapterName)
    {
        id = _adapterIds[index];
        AdapterEntry storage e = adapters[id];
        return (id, e.addr, e.enabled, e.name);
    }

    function allAdapterIds() external view returns (bytes32[] memory) { return _adapterIds; }

    function setFeeRecipient(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit FeeRecipientSet(feeRecipient, next);
        feeRecipient = next;
    }

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

    function rescueTokens(address token, address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _safeTransfer(token, recipient, amount);
    }

    function rescueNative(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _sendNative(recipient, amount);
    }

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
            abi.encodeWithSelector(0x23b872dd, from, to_, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _safeTransfer(address token, address to_, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to_, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _sendNative(address to_, uint256 amount) internal {
        (bool ok,) = to_.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }
}
