// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "../interfaces/ILaunchpadToken.sol";

/**
 * @title StandardToken
 * @notice Plain ERC-20 used by OneMEME launchpad. Deployed as a minimal-proxy
 *         clone by LaunchpadFactory. All tokens are minted to the factory on
 *         init; the factory manages distribution during the bonding-curve phase.
 *         There are no transfer restrictions or taxes on this token type.
 */
contract StandardToken is ILaunchpadToken {

    bool    private _initialized;
    address private _owner;
    address public  factory;

    string  private _name;
    string  private _symbol;
    uint256 private _totalSupply;

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ─── Token metadata URI ───────────────────────────────────────────────
    string private _metaURI;

    // ─── Creator vesting (token contract is its own escrow) ───────────────
    address public vestingCreator;
    uint256 public vestingTotal;
    uint256 public vestingStart;
    uint256 public vestingClaimed;
    uint256 private constant VESTING_DURATION = 365 days;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event MetaURIUpdated(string uri);
    event VestingSetup(address indexed creator, uint256 amount);
    event VestingClaimed(address indexed owner, uint256 amount);

    modifier onlyFactory() {
        require(msg.sender == factory, "Not factory");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Not owner");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // INIT
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Called once by the factory after clone deployment.
     * @param name_       Token name
     * @param symbol_     Token symbol
     * @param totalSupply_ Total supply (18 decimals already scaled by caller)
     * @param factory_    Factory address — receives the entire supply
     */
    function initForLaunchpad(
        string  calldata name_,
        string  calldata symbol_,
        uint256          totalSupply_,
        address          factory_,
        address          tokenOwner_,
        string  calldata metaURI_
    ) external {
        require(!_initialized,          "Already initialized");
        require(factory_    != address(0), "Zero factory");
        require(tokenOwner_ != address(0), "Zero owner");
        _initialized = true;

        factory      = factory_;
        _owner       = tokenOwner_;
        _name        = name_;
        _symbol      = symbol_;
        _totalSupply = totalSupply_;

        _metaURI     = metaURI_;
        _balances[factory_] = totalSupply_;
        emit Transfer(address(0), factory_, totalSupply_);
        emit OwnershipTransferred(address(0), tokenOwner_);
    }

    /**
     * @notice No-op for StandardToken — there is no pair-based fee logic to
     *         unlock.  Exists only to satisfy the ILaunchpadToken interface.
     */
    function enableTrading(address, address) external override onlyFactory {}

    // ─────────────────────────────────────────────────────────────────────
    // METADATA URI
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Off-chain metadata URI — JSON with name, description, image, website, etc.
    function metaURI() external view override returns (string memory) { return _metaURI; }

    /// @notice Update the metadata URI.  Callable only by the token owner.
    function setMetaURI(string calldata uri_) external override onlyOwner {
        _metaURI = uri_;
        emit MetaURIUpdated(uri_);
    }

    /**
     * @notice Called once by the factory after it has transferred the creator
     *         allocation to this contract.  Starts the 12-month linear vest.
     */
    function setupVesting(address creator_, uint256 amount_) external override onlyFactory {
        require(vestingCreator == address(0), "Vesting already set");
        require(creator_ != address(0),       "Zero creator");
        require(amount_  > 0,                 "Zero amount");
        vestingCreator = creator_;
        vestingTotal   = amount_;
        vestingStart   = block.timestamp;
        emit VestingSetup(creator_, amount_);
    }

    /**
     * @notice Claim linearly vested tokens.
     *         Callable only by the current token owner.
     *         If ownership is transferred, the new owner inherits vesting rights.
     *         vestingCreator records the original recipient for transparency only.
     */
    function claimVesting() external {
        require(msg.sender == _owner, "Not owner");
        require(vestingTotal > 0,     "No vesting");
        uint256 elapsed = block.timestamp - vestingStart;
        if (elapsed > VESTING_DURATION) elapsed = VESTING_DURATION;
        uint256 claimable = (vestingTotal * elapsed / VESTING_DURATION) - vestingClaimed;
        require(claimable > 0, "Nothing to claim");
        vestingClaimed += claimable;
        _transfer(address(this), _owner, claimable);
        emit VestingClaimed(_owner, claimable);
    }

    /// @notice How many tokens the current owner can claim right now.
    function claimableVesting() external view returns (uint256) {
        if (vestingTotal == 0) return 0;
        uint256 elapsed = block.timestamp - vestingStart;
        if (elapsed > VESTING_DURATION) elapsed = VESTING_DURATION;
        return (vestingTotal * elapsed / VESTING_DURATION) - vestingClaimed;
    }

    // ─────────────────────────────────────────────────────────────────────
    // OWNERSHIP
    // ─────────────────────────────────────────────────────────────────────

    function owner() external view returns (address) { return _owner; }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC-20
    // ─────────────────────────────────────────────────────────────────────

    function name()        external view returns (string memory) { return _name;   }
    function symbol()      external view returns (string memory) { return _symbol; }
    function decimals()    external pure returns (uint8)         { return 18;      }
    function totalSupply() external view override returns (uint256) { return _totalSupply; }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "Exceeds allowance");
        unchecked { _allowances[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL
    // ─────────────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0) && to != address(0), "Zero address");
        require(_balances[from] >= amount, "Insufficient balance");
        unchecked {
            _balances[from] -= amount;
            _balances[to]   += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        require(owner_ != address(0) && spender != address(0), "Zero address");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }
}
