// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title VestingWallet — OneMEME
 * @notice Single vesting contract shared by all tokens launched through LaunchpadFactory.
 *         The factory transfers creator tokens here and calls addVesting() atomically.
 *         Both TaxToken and ReflectionToken exclude this address during init so transfers
 *         to/from this contract are fee-free and reflection-neutral.
 *
 *         Beneficiaries claim linear 12-month vests via claim(token).
 *         The owner may void any schedule, burning all remaining unvested tokens.
 */
contract VestingWallet {

    uint256 public constant VESTING_DURATION = 365 days;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public owner;
    address public factory;

    struct Schedule {
        uint256 total;
        uint256 start;
        uint256 claimed;
    }

    // token => beneficiary => schedule
    mapping(address => mapping(address => Schedule)) public schedules;

    error NotOwner();
    error NotFactory();
    error AlreadySetup();
    error NoSchedule();
    error NothingToClaim();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();

    event VestingAdded(address indexed token, address indexed beneficiary, uint256 amount);
    event Claimed(address indexed token, address indexed beneficiary, uint256 amount);
    event VestingVoided(address indexed token, address indexed beneficiary, uint256 burned);
    event OwnershipTransferred(address indexed prev, address indexed next);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(address owner_, address factory_) {
        if (owner_   == address(0)) revert ZeroAddress();
        if (factory_ == address(0)) revert ZeroAddress();
        owner   = owner_;
        factory = factory_;
    }

    // ─────────────────────────────────────────────────────────────────────
    // FACTORY
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Called by the factory immediately after transferring `amount` tokens here.
    function addVesting(address token, address beneficiary, uint256 amount) external {
        if (msg.sender != factory)     revert NotFactory();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0)               revert ZeroAmount();
        Schedule storage s = schedules[token][beneficiary];
        if (s.total != 0) revert AlreadySetup();
        s.total = amount;
        s.start = block.timestamp;
        emit VestingAdded(token, beneficiary, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // BENEFICIARY
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Claim linearly vested tokens for the calling address.
    function claim(address token) external {
        Schedule storage s = schedules[token][msg.sender];
        uint256 amount = _claimable(s);
        if (amount == 0) revert NothingToClaim();
        s.claimed += amount;
        bool ok = IERC20Transfer(token).transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();
        emit Claimed(token, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // OWNER
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Void a vesting schedule — burns all remaining unvested tokens immediately.
     *         Any previously claimed tokens are unaffected.
     *         Safe for both standard and tax tokens: this contract is fee-excluded
     *         during token init so the full unvested amount reaches the burn address.
     */
    function voidSchedule(address token, address beneficiary) external onlyOwner {
        Schedule storage s = schedules[token][beneficiary];
        if (s.total == 0) revert NoSchedule();
        uint256 remaining = s.total - s.claimed;
        // Zero schedule before external call (re-entrancy safety).
        s.total   = 0;
        s.start   = 0;
        s.claimed = 0;
        if (remaining > 0) {
            bool ok = IERC20Transfer(token).transfer(BURN_ADDRESS, remaining);
            if (!ok) revert TransferFailed();
        }
        emit VestingVoided(token, beneficiary, remaining);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ─────────────────────────────────────────────────────────────────────
    // VIEWS
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Returns how many tokens `beneficiary` can currently claim for `token`.
    function claimable(address token, address beneficiary) external view returns (uint256) {
        return _claimable(schedules[token][beneficiary]);
    }

    function _claimable(Schedule storage s) private view returns (uint256) {
        if (s.total == 0) return 0;
        uint256 elapsed = block.timestamp - s.start;
        if (elapsed >= VESTING_DURATION) return s.total - s.claimed;
        return (s.total * elapsed / VESTING_DURATION) - s.claimed;
    }
}
