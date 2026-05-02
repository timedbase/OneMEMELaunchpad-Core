// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "../interfaces/IAdapter.sol";

/**
 * @title  BaseAdapter
 * @notice Abstract base for all OneMEME aggregator adapters.
 *         onlyAggregator guards execute() — funds are pre-transferred before execute() is called.
 */
abstract contract BaseAdapter is IAdapter {

    address public immutable aggregator;

    error NotAggregator();
    error ZeroAddress();
    error TransferFailed();
    error NativeSendFailed();
    error InsufficientOutput();

    modifier onlyAggregator() {
        if (msg.sender != aggregator) revert NotAggregator();
        _;
    }

    constructor(address aggregator_) {
        if (aggregator_ == address(0)) revert ZeroAddress();
        aggregator = aggregator_;
    }

    receive() external payable {}

    // USDT-safe approve: reset to 0 before setting a new value.
    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, 0));
        if (!ok) revert TransferFailed();
        (ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        if (!ok) revert TransferFailed();
    }

    function _selfBalance(address token) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        bal = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    function _balanceOf(address token, address account) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        bal = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    function _resetApproval(address token, address spender) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, 0));
        if (!ok) revert TransferFailed();
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

    function _unwrapAndSend(address wbnb, uint256 amount, address to_) internal {
        (bool ok,) = wbnb.call(abi.encodeWithSignature("withdraw(uint256)", amount));
        if (!ok) revert TransferFailed();
        _sendNative(to_, amount);
    }
}
