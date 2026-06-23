// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC721Min {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC1155Min {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

// Shared M-of-N multisig core: on-chain propose -> approve -> execute. Used by OrigaVault,
// OrigaVaultUltra, and OrigaVaultMax. Signer-set/threshold mutation (addSigner/removeSigner/
// setThreshold) lives only in OrigaVaultMax, gated `onlySelf` -- so it can only run through
// this same propose/approve/execute pipeline, requiring the current threshold's approval.
// OrigaVault/OrigaVaultUltra never expose those functions at all, making their signer set
// and threshold immutable for the life of the vault.
//
// Asset management: propose/execute already allow arbitrary calldata against any target, so
// every operation below is also reachable that way -- these named, onlySelf-gated functions
// exist so moving a specific asset class is a clear, typed, auditable operation (its own
// event) rather than something buried in an opaque bytes blob.
abstract contract OrigaMultisigBase {

    error NotSigner();
    error NotSelf();
    error AlreadyApproved();
    error NotApproved();
    error AlreadyExecuted();
    error ProposalNotFound();
    error ThresholdNotMet();
    error ExecutionFailed();
    error InvalidThreshold();
    error DuplicateSigner();
    error SignerNotFound();
    error ZeroAddress();

    struct Proposal {
        address target;
        uint256 value;
        bytes   data;
        uint256 approvals;
        bool    executed;
    }

    address[] public signers;
    mapping(address => bool) public isSigner;
    uint256 public threshold;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasApproved;

    event Proposed(uint256 indexed proposalId, address indexed proposer, address target, uint256 value, bytes data);
    event Approved(uint256 indexed proposalId, address indexed signer, uint256 approvals);
    event ApprovalRevoked(uint256 indexed proposalId, address indexed signer, uint256 approvals);
    event Executed(uint256 indexed proposalId, bool success);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);
    event NativeSent(address indexed to, uint256 amount);
    event ERC20Sent(address indexed token, address indexed to, uint256 amount);
    event ERC721Sent(address indexed token, address indexed to, uint256 tokenId);
    event ERC1155Sent(address indexed token, address indexed to, uint256 id, uint256 amount);

    modifier onlySigner() { if (!isSigner[msg.sender]) revert NotSigner(); _; }
    modifier onlySelf()   { if (msg.sender != address(this)) revert NotSelf(); _; }

    function _initMultisig(address[] memory signers_, uint256 threshold_) internal {
        if (threshold_ == 0 || threshold_ > signers_.length) revert InvalidThreshold();
        for (uint256 i; i < signers_.length; i++) {
            address s = signers_[i];
            if (s == address(0)) revert ZeroAddress();
            if (isSigner[s]) revert DuplicateSigner();
            isSigner[s] = true;
            signers.push(s);
        }
        threshold = threshold_;
    }

    function proposal(uint256 proposalId) external view returns (
        address target, uint256 value, bytes memory data, uint256 approvals, bool executed
    ) {
        if (proposalId >= proposalCount) revert ProposalNotFound();
        Proposal storage p = _proposals[proposalId];
        return (p.target, p.value, p.data, p.approvals, p.executed);
    }

    function signerCount() external view returns (uint256) { return signers.length; }

    // Creating a proposal counts as that signer's first approval.
    function propose(address target, uint256 value, bytes calldata data) external onlySigner returns (uint256 proposalId) {
        proposalId = proposalCount++;
        _proposals[proposalId] = Proposal({ target: target, value: value, data: data, approvals: 0, executed: false });
        emit Proposed(proposalId, msg.sender, target, value, data);
        _approve(proposalId);
    }

    function approve(uint256 proposalId) external onlySigner {
        if (proposalId >= proposalCount) revert ProposalNotFound();
        if (_proposals[proposalId].executed) revert AlreadyExecuted();
        _approve(proposalId);
    }

    function revokeApproval(uint256 proposalId) external onlySigner {
        if (proposalId >= proposalCount) revert ProposalNotFound();
        Proposal storage p = _proposals[proposalId];
        if (p.executed) revert AlreadyExecuted();
        if (!hasApproved[proposalId][msg.sender]) revert NotApproved();
        hasApproved[proposalId][msg.sender] = false;
        p.approvals--;
        emit ApprovalRevoked(proposalId, msg.sender, p.approvals);
    }

    // Anyone may trigger execution once threshold is met -- the security boundary is the
    // approval count, not who pushes the final call.
    function execute(uint256 proposalId) external {
        if (proposalId >= proposalCount) revert ProposalNotFound();
        Proposal storage p = _proposals[proposalId];
        if (p.executed) revert AlreadyExecuted();
        if (p.approvals < threshold) revert ThresholdNotMet();
        p.executed = true;
        (bool ok, ) = p.target.call{value: p.value}(p.data);
        emit Executed(proposalId, ok);
        if (!ok) revert ExecutionFailed();
    }

    function _approve(uint256 proposalId) private {
        if (hasApproved[proposalId][msg.sender]) revert AlreadyApproved();
        hasApproved[proposalId][msg.sender] = true;
        uint256 newApprovals = _proposals[proposalId].approvals + 1;
        _proposals[proposalId].approvals = newApprovals;
        emit Approved(proposalId, msg.sender, newApprovals);
    }

    // ── Asset management ─────────────────────────────────────────────────────────────────
    // Reachable only via execute() calling back into this contract (target = address(this)),
    // same self-call pattern as OrigaVaultMax's signer/threshold governance.

    function sendNative(address to, uint256 amount) external onlySelf {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert ExecutionFailed();
        emit NativeSent(to, amount);
    }

    function sendERC20(address token, address to, uint256 amount) external onlySelf {
        _safeTransferERC20(token, to, amount);
        emit ERC20Sent(token, to, amount);
    }

    function sendERC721(address token, address to, uint256 tokenId) external onlySelf {
        IERC721Min(token).safeTransferFrom(address(this), to, tokenId);
        emit ERC721Sent(token, to, tokenId);
    }

    function sendERC1155(address token, address to, uint256 id, uint256 amount, bytes calldata data) external onlySelf {
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
