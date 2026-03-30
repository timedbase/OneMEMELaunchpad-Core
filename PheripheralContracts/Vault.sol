// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

/**
 * @title  Vault
 * @notice 2-of-3 multisig wallet.
 *
 *  - Any signer can propose a transaction (arbitrary call: target, value, calldata).
 *  - The proposer auto-confirms on proposal (counts as 1 of 2 required).
 *  - Any other signer can add a second confirmation to unlock execution.
 *  - Any signer can execute once the threshold (2) is met.
 *  - Only the proposer can cancel their own pending proposal.
 *  - Any signer can revoke their own prior confirmation.
 *  - Signers are fixed at deployment — they cannot be changed.
 */
contract Vault {

    // ─── constants ───────────────────────────────────────────────────────────

    uint8 public constant THRESHOLD    = 2;
    uint8 public constant SIGNER_COUNT = 3;

    // ─── signers ─────────────────────────────────────────────────────────────

    address[3] public signers;

    modifier onlySigner() {
        require(isSigner(msg.sender), "Vault: not signer");
        _;
    }

    function isSigner(address addr) public view returns (bool) {
        return addr == signers[0] || addr == signers[1] || addr == signers[2];
    }

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

    mapping(uint256 => Proposal)                    private _proposals;
    mapping(uint256 => mapping(address => bool))    public  confirmed;
    uint256 public proposalCount;

    // ─── events ──────────────────────────────────────────────────────────────

    event Received(address indexed from, uint256 amount);
    event Proposed(uint256 indexed id, address indexed proposer, address to, uint256 value, bytes data);
    event Confirmed(uint256 indexed id, address indexed signer);
    event Revoked(uint256 indexed id, address indexed signer);
    event Executed(uint256 indexed id, address indexed executor);
    event Cancelled(uint256 indexed id, address indexed proposer);

    // ─── constructor ─────────────────────────────────────────────────────────

    constructor(address s0, address s1, address s2) {
        require(s0 != address(0) && s1 != address(0) && s2 != address(0), "Vault: zero address");
        require(s0 != s1 && s1 != s2 && s0 != s2, "Vault: duplicate signer");
        signers[0] = s0;
        signers[1] = s1;
        signers[2] = s2;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // ─── proposal lifecycle ──────────────────────────────────────────────────

    /**
     * @notice Propose a transaction.  Proposer is auto-confirmed (1-of-2).
     * @param  to    Target address of the call.
     * @param  value BNB (wei) to forward with the call.
     * @param  data  Calldata (empty for plain BNB transfers).
     * @return id    Proposal index.
     */
    function propose(
        address to,
        uint256 value,
        bytes calldata data
    ) external onlySigner returns (uint256 id) {
        require(to != address(0), "Vault: zero target");

        id = proposalCount++;
        Proposal storage p = _proposals[id];
        p.to      = to;
        p.value   = value;
        p.data    = data;
        p.proposer = msg.sender;

        // Auto-confirm for proposer
        p.confirmCount      = 1;
        confirmed[id][msg.sender] = true;

        emit Proposed(id, msg.sender, to, value, data);
        emit Confirmed(id, msg.sender);
    }

    /**
     * @notice Add your confirmation to a pending proposal.
     */
    function confirm(uint256 id) external onlySigner {
        Proposal storage p = _proposals[id];
        require(id < proposalCount,          "Vault: unknown proposal");
        require(!p.executed,                 "Vault: already executed");
        require(!p.cancelled,                "Vault: cancelled");
        require(!confirmed[id][msg.sender],  "Vault: already confirmed");

        confirmed[id][msg.sender] = true;
        p.confirmCount++;
        emit Confirmed(id, msg.sender);
    }

    /**
     * @notice Revoke your confirmation from a pending proposal.
     */
    function revoke(uint256 id) external onlySigner {
        Proposal storage p = _proposals[id];
        require(!p.executed,                "Vault: already executed");
        require(!p.cancelled,               "Vault: cancelled");
        require(confirmed[id][msg.sender],  "Vault: not confirmed");

        confirmed[id][msg.sender] = false;
        p.confirmCount--;
        emit Revoked(id, msg.sender);
    }

    /**
     * @notice Execute a proposal that has reached the confirmation threshold.
     */
    function execute(uint256 id) external onlySigner {
        Proposal storage p = _proposals[id];
        require(!p.executed,                     "Vault: already executed");
        require(!p.cancelled,                    "Vault: cancelled");
        require(p.confirmCount >= THRESHOLD,     "Vault: insufficient confirmations");
        require(address(this).balance >= p.value,"Vault: insufficient BNB");

        p.executed = true;

        (bool ok,) = p.to.call{value: p.value}(p.data);
        require(ok, "Vault: call failed");

        emit Executed(id, msg.sender);
    }

    /**
     * @notice Cancel a proposal.  Only the original proposer can cancel.
     */
    function cancel(uint256 id) external onlySigner {
        Proposal storage p = _proposals[id];
        require(!p.executed,          "Vault: already executed");
        require(!p.cancelled,         "Vault: already cancelled");
        require(msg.sender == p.proposer, "Vault: not proposer");

        p.cancelled = true;
        emit Cancelled(id, msg.sender);
    }

    // ─── views ───────────────────────────────────────────────────────────────

    function getProposal(uint256 id) external view returns (
        address to,
        uint256 value,
        bytes memory data,
        address proposer,
        uint8   confirmCount,
        bool    executed,
        bool    cancelled,
        bool    canExecute
    ) {
        Proposal storage p = _proposals[id];
        return (
            p.to,
            p.value,
            p.data,
            p.proposer,
            p.confirmCount,
            p.executed,
            p.cancelled,
            !p.executed && !p.cancelled && p.confirmCount >= THRESHOLD
        );
    }

    /// @notice Returns which of the three signers have confirmed a given proposal.
    function getSignerConfirmations(uint256 id) external view returns (bool[3] memory) {
        return [
            confirmed[id][signers[0]],
            confirmed[id][signers[1]],
            confirmed[id][signers[2]]
        ];
    }

    /// @notice Fetch multiple proposals in one call (start inclusive, end exclusive).
    function getProposalRange(uint256 start, uint256 end) external view returns (
        uint256[] memory ids,
        address[] memory tos,
        uint256[] memory values,
        address[] memory proposers,
        uint8[]   memory confirmCounts,
        bool[]    memory executeds,
        bool[]    memory cancelleds
    ) {
        require(end <= proposalCount && start <= end, "Vault: invalid range");
        uint256 len = end - start;
        ids          = new uint256[](len);
        tos          = new address[](len);
        values       = new uint256[](len);
        proposers    = new address[](len);
        confirmCounts= new uint8[](len);
        executeds    = new bool[](len);
        cancelleds   = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 pid = start + i;
            Proposal storage p = _proposals[pid];
            ids[i]          = pid;
            tos[i]          = p.to;
            values[i]       = p.value;
            proposers[i]    = p.proposer;
            confirmCounts[i]= p.confirmCount;
            executeds[i]    = p.executed;
            cancelleds[i]   = p.cancelled;
        }
    }
}
