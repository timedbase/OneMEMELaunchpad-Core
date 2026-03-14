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

    error NotOwner();
    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error VestingAlreadySet();
    error NoVesting();
    error NothingToClaim();
    error InsufficientBalance();
    error ExceedsAllowance();

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

    modifier onlyFactory() { if (msg.sender != factory) revert NotFactory(); _; }
    modifier onlyOwner()   { if (msg.sender != _owner)  revert NotOwner();   _; }

    /// @dev Prevents direct initialization of the implementation contract.
    constructor() { _initialized = true; }

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
        if (_initialized)              revert AlreadyInitialized();
        if (factory_    == address(0)) revert ZeroAddress();
        if (tokenOwner_ == address(0)) revert ZeroAddress();
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
        if (vestingCreator != address(0)) revert VestingAlreadySet();
        if (creator_ == address(0))       revert ZeroAddress();
        if (amount_  == 0)                revert ZeroAmount();
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
        if (msg.sender != _owner) revert NotOwner();
        if (vestingTotal == 0)    revert NoVesting();
        uint256 elapsed = block.timestamp - vestingStart;
        if (elapsed > VESTING_DURATION) elapsed = VESTING_DURATION;
        uint256 claimable = (vestingTotal * elapsed / VESTING_DURATION) - vestingClaimed;
        if (claimable == 0) revert NothingToClaim();
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
        if (newOwner == address(0)) revert ZeroAddress();
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
        if (allowed < amount) revert ExceedsAllowance();
        unchecked { _allowances[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL
    // ─────────────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (_balances[from] < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] -= amount;
            _balances[to]   += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        if (owner_ == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }
}
