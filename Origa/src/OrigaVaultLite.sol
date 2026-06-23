// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC721Min {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC1155Min {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

// Single-signer vault — direct, immediate execution, no proposal/approval workflow.
contract OrigaVaultLite {

    error AlreadyInitialized();
    error NotOwner();
    error ZeroAddress();
    error ExecutionFailed();

    bool    private _initialized;
    address public  owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Executed(address indexed target, uint256 value, bytes data, bool success);
    event NativeSent(address indexed to, uint256 amount);
    event ERC20Sent(address indexed token, address indexed to, uint256 amount);
    event ERC721Sent(address indexed token, address indexed to, uint256 tokenId);
    event ERC1155Sent(address indexed token, address indexed to, uint256 id, uint256 amount);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor() { _initialized = true; } // blocks direct use of the implementation

    function init(address owner_) external {
        if (_initialized)         revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroAddress();
        _initialized = true;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // Arbitrary calldata against any target — escape hatch for anything the named asset
    // functions below don't cover.
    function execute(address target, uint256 value, bytes calldata data)
        external onlyOwner returns (bytes memory result)
    {
        bool ok;
        (ok, result) = target.call{value: value}(data);
        emit Executed(target, value, data, ok);
        if (!ok) revert ExecutionFailed();
    }

    // ── Asset management ─────────────────────────────────────────────────────────────────

    function sendNative(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert ExecutionFailed();
        emit NativeSent(to, amount);
    }

    function sendERC20(address token, address to, uint256 amount) external onlyOwner {
        _safeTransferERC20(token, to, amount);
        emit ERC20Sent(token, to, amount);
    }

    function sendERC721(address token, address to, uint256 tokenId) external onlyOwner {
        IERC721Min(token).safeTransferFrom(address(this), to, tokenId);
        emit ERC721Sent(token, to, tokenId);
    }

    function sendERC1155(address token, address to, uint256 id, uint256 amount, bytes calldata data) external onlyOwner {
        IERC1155Min(token).safeTransferFrom(address(this), to, id, amount, data);
        emit ERC1155Sent(token, to, id, amount);
    }

    // transfer(address,uint256) via low-level call — tolerates non-standard ERC-20s (e.g.
    // USDT) that don't return a bool.
    function _safeTransferERC20(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert ExecutionFailed();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external pure returns (bytes4)
    {
        return 0xbc197c81;
    }

    receive() external payable {}
}
