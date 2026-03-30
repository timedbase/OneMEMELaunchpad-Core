// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

/**
 * @title  IVault
 * @notice Interface for 2-of-3 multisig vault contracts.
 *
 * Vaults are used to:
 *  - CreatorVault: Manage creator allocations and token distributions
 *  - MaintenanceVault: Manage platform maintenance funds and operations
 *
 * Both vault types follow the same 2-of-3 multisig pattern with auto-confirm on proposal.
 */
interface IVault {
    // ─── constants ───────────────────────────────────────────────────────────

    function THRESHOLD() external view returns (uint8);
    function SIGNER_COUNT() external view returns (uint8);

    // ─── signers ─────────────────────────────────────────────────────────────

    function signers(uint256 index) external view returns (address);

    function isSigner(address addr) external view returns (bool);

    // ─── proposals ───────────────────────────────────────────────────────────

    struct Proposal {
        address to;
        uint256 value;
        bytes   data;
        address proposer;
        uint8   confirmCount;
        bool    executed;
        bool    cancelled;
    }

    function confirmed(uint256 proposalId, address signer) external view returns (bool);

    function proposalCount() external view returns (uint256);

    // ─── proposal lifecycle ──────────────────────────────────────────────────

    /**
     * @notice Propose a transaction. Proposer is auto-confirmed (1-of-2).
     * @param  to    Target address of the call.
     * @param  value BNB (wei) to forward with the call.
     * @param  data  Calldata (empty for plain BNB transfers).
     * @return id    Proposal index.
     */
    function propose(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (uint256 id);

    /**
     * @notice Add your confirmation to a pending proposal.
     */
    function confirm(uint256 id) external;

    /**
     * @notice Revoke your confirmation from a pending proposal.
     */
    function revoke(uint256 id) external;

    /**
     * @notice Execute a proposal that has reached the confirmation threshold.
     */
    function execute(uint256 id) external;

    /**
     * @notice Cancel a pending proposal (proposer only).
     */
    function cancel(uint256 id) external;

    /**
     * @notice View a proposal's details.
     */
    function getProposal(uint256 id) external view returns (Proposal memory);

    // ─── events ──────────────────────────────────────────────────────────────

    event Received(address indexed from, uint256 amount);
    event Proposed(uint256 indexed id, address indexed proposer, address to, uint256 value, bytes data);
    event Confirmed(uint256 indexed id, address indexed signer);
    event Revoked(uint256 indexed id, address indexed signer);
    event Executed(uint256 indexed id, address indexed executor);
    event Cancelled(uint256 indexed id, address indexed proposer);
}
