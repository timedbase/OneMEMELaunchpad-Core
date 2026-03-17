// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "../interfaces/ILaunchpadToken.sol";

interface IPancakeRouter02TT {
    function factory() external pure returns (address);
    function WETH()    external pure returns (address);
    function addLiquidityETH(
        address token, uint amountTokenDesired, uint amountTokenMin,
        uint amountETHMin, address to, uint deadline
    ) external payable returns (uint, uint, uint);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path,
        address to, uint deadline
    ) external;
}

interface IPancakeFactoryTT {
    function createPair(address tokenA, address tokenB) external returns (address);
    function getPair(address tokenA, address tokenB)   external view returns (address);
}

/// @dev Minimal ERC-20 interface used only by rescueTokens().
interface IERC20Rescue {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title TaxToken  (OneMEME Launchpad)
 * @notice ERC-20 with configurable buy/sell taxes.
 *         Deployed as a minimal-proxy clone by LaunchpadFactory.
 *
 * Lifecycle:
 *   1. Factory calls initForLaunchpad() – mints entire supply to factory,
 *      tax params configured, bonding-curve phase active.
 *   2. During bonding-curve phase transfers from/to the factory are fee-free;
 *      swapAndDistribute is suppressed (no DEX pair yet).
 *   3. Factory calls postMigrateSetup(pair, router) after DEX migration –
 *      pancakePair & router set, bonding phase disabled, normal fees begin.
 */
contract TaxToken is ILaunchpadToken {

    // ─── errors ────────────────────────────────────────────────────────
    error NotOwner();
    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error TaxExceedsMax();
    error SwapThresholdTooLow();
    error DexAlreadyConfigured();
    error ExceedsAllowance();
    error InsufficientBalance();
    error NothingToSwap();
    error CannotRescueOwnToken();
    error VestingAlreadySet();
    error NoVesting();
    error NothingToClaim();
    error BNBTransferFailed();
    error TokenRescueFailed();

    address private _owner;
    address private _factory;
    bool    private _initialized;
    bool    private _inBondingPhase;

    string  private _name;
    string  private _symbol;
    string  private _metaURI;
    uint8   private constant DECIMALS = 18;
    uint256 private _totalSupply;

    uint256 public buyMarketingTax;
    uint256 public buyTeamTax;
    uint256 public buyTreasuryTax;
    uint256 public buyBurnTax;
    uint256 public buyLiquidityTax;

    uint256 public sellMarketingTax;
    uint256 public sellTeamTax;
    uint256 public sellTreasuryTax;
    uint256 public sellBurnTax;
    uint256 public sellLiquidityTax;

    uint256 public constant MAX_TOTAL_TAX          = 1000; // 10 %
    uint256 private constant MIN_SWAP_THRESHOLD_BPS = 2;    // 0.02 %
    uint256 private constant BPS_DENOM              = 10000;

    uint256 public swapThreshold;

    address public marketingWallet;
    address public teamWallet;
    address public treasuryWallet;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool)                        private _isExcludedFromFee;

    IPancakeRouter02TT public pancakeRouter;
    address            public pancakePair;

    bool private inSwap;
    bool public  swapEnabled;

    address public vestingCreator;
    uint256 public vestingTotal;
    uint256 public vestingStart;
    uint256 public vestingClaimed;
    uint256 private constant VESTING_DURATION = 365 days;

    // Tracks the vesting escrow portion held inside this contract.
    // Excluded from swapAndDistribute so tax swaps never consume vested tokens.
    uint256 private _vestingBalance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event WalletsUpdated(address marketing, address team, address treasury);
    event BuyTaxesUpdated(uint256 marketing, uint256 team, uint256 treasury, uint256 burn, uint256 lp);
    event SellTaxesUpdated(uint256 marketing, uint256 team, uint256 treasury, uint256 burn, uint256 lp);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnbReceived);
    event DexConfigured(address pair, address router);
    event MetaURIUpdated(string uri);
    event VestingSetup(address indexed creator, uint256 amount);
    event VestingClaimed(address indexed owner, uint256 amount);

    modifier lockSwap()   { inSwap = true; _; inSwap = false; }
    modifier onlyOwner()  { if (msg.sender != _owner)   revert NotOwner();   _; }
    modifier onlyFactory(){ if (msg.sender != _factory) revert NotFactory(); _; }

    /// @dev Prevents direct initialization of the implementation contract.
    constructor() { _initialized = true; }

    // ─────────────────────────────────────────────────────────────────────
    // INIT
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice One-shot initialiser called by the factory immediately after clone
     *         deployment.  All tokens minted to factory_.
     *         Wallets default to tokenOwner_, all taxes start at 0 %,
     *         swapThreshold defaults to 0.1 % of supply.
     * @param tokenOwner_    Address that owns the token after migration
     * @param router_        PancakeSwap V2 router — stored and used to create the pair immediately
     */
    function initForLaunchpad(
        string    calldata name_,
        string    calldata symbol_,
        uint256            totalSupply_,
        address            factory_,
        address            tokenOwner_,
        string    calldata metaURI_,
        address            router_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (factory_    == address(0)) revert ZeroAddress();
        if (tokenOwner_ == address(0)) revert ZeroAddress();
        if (router_     == address(0)) revert ZeroAddress();

        _initialized    = true;
        _inBondingPhase = true;
        _factory        = factory_;
        _owner          = tokenOwner_;

        _name        = name_;
        _symbol      = symbol_;
        _totalSupply = totalSupply_;

        // Wallets default to owner — updatable post-deployment via setWallets().
        marketingWallet = tokenOwner_;
        teamWallet      = tokenOwner_;
        treasuryWallet  = tokenOwner_;

        // All taxes start at 0 % — updatable post-deployment via setBuyTaxes/setSellTaxes().

        // swapThreshold defaults to 0.1 % of supply — updatable post-deployment via setSwapThreshold().
        swapThreshold = totalSupply_ / 1000;
        swapEnabled   = false;

        _isExcludedFromFee[factory_]       = true;
        _isExcludedFromFee[tokenOwner_]    = true;
        _isExcludedFromFee[address(this)]  = true;
        _isExcludedFromFee[BURN_ADDRESS]   = true;

        _metaURI = metaURI_;

        // Store router and create the PancakeSwap pair immediately.
        // Liquidity is added only at migration; during bonding phase the pair holds nothing.
        pancakeRouter = IPancakeRouter02TT(router_);
        pancakePair   = IPancakeFactoryTT(pancakeRouter.factory()).createPair(address(this), pancakeRouter.WETH());
        _isExcludedFromFee[pancakePair] = true;

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
     * @notice Called by the factory after DEX liquidity has been seeded.
     *         Router and pair are already set from initForLaunchpad; this simply
     *         exits the bonding phase and enables normal tax/swap behaviour.
     */
    function postMigrateSetup() external onlyFactory {
        if (!_inBondingPhase) revert DexAlreadyConfigured();
        _inBondingPhase = false;
        swapEnabled     = true;
        emit DexConfigured(pancakePair, address(pancakeRouter));
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC-20
    // ─────────────────────────────────────────────────────────────────────

    function name()        public view returns (string memory) { return _name;   }
    function symbol()      public view returns (string memory) { return _symbol; }
    function decimals()    public pure returns (uint8)         { return DECIMALS;}
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address a) public view override returns (uint256) { return _balances[a]; }
    function owner()       public view returns (address) { return _owner; }

    function allowance(address owner_, address spender) public view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed < amount) revert ExceedsAllowance();
        unchecked { _allowances[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // TRANSFER LOGIC
    // ─────────────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0)                            revert ZeroAmount();
        if (_balances[from] < amount)               revert InsufficientBalance();

        bool takeFee = !(_isExcludedFromFee[from] || _isExcludedFromFee[to]);

        if (!_inBondingPhase && swapEnabled && takeFee && !inSwap && from != pancakePair) {
            uint256 taxBalance = _balances[address(this)] > _vestingBalance
                ? _balances[address(this)] - _vestingBalance
                : 0;
            if (taxBalance > 0 && taxBalance >= swapThreshold) swapAndDistribute(taxBalance);
        }

        _executeTransfer(from, to, amount, takeFee);
    }

    function _executeTransfer(address sender, address recipient, uint256 amount, bool takeFee) private {
        if (!takeFee) {
            _balances[sender]    -= amount;
            _balances[recipient] += amount;
            emit Transfer(sender, recipient, amount);
            return;
        }

        bool isBuy  = (sender   == pancakePair);
        bool isSell = (recipient == pancakePair);

        uint256 burnAmt;
        uint256 taxAmt;

        if (isBuy) {
            burnAmt = (amount * buyBurnTax) / 10000;
            taxAmt  = (amount * (buyMarketingTax + buyTeamTax + buyTreasuryTax + buyLiquidityTax)) / 10000;
        } else if (isSell) {
            burnAmt = (amount * sellBurnTax) / 10000;
            taxAmt  = (amount * (sellMarketingTax + sellTeamTax + sellTreasuryTax + sellLiquidityTax)) / 10000;
        }

        uint256 transferAmt = amount - burnAmt - taxAmt;

        _balances[sender]          -= amount;
        _balances[recipient]       += transferAmt;
        emit Transfer(sender, recipient, transferAmt);

        if (burnAmt > 0) {
            _balances[BURN_ADDRESS] += burnAmt;
            emit Transfer(sender, BURN_ADDRESS, burnAmt);
        }
        if (taxAmt > 0) {
            _balances[address(this)] += taxAmt;
            emit Transfer(sender, address(this), taxAmt);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // SWAP & DISTRIBUTE (post-migration only)
    // ─────────────────────────────────────────────────────────────────────

    function swapAndDistribute(uint256 tokenAmount) private lockSwap {
        uint256 totalBuy  = buyMarketingTax  + buyTeamTax  + buyTreasuryTax  + buyLiquidityTax;
        uint256 totalSell = sellMarketingTax + sellTeamTax + sellTreasuryTax + sellLiquidityTax;
        uint256 totalTax  = totalBuy + totalSell;
        if (totalTax == 0) return;

        uint256 lpTokens = (tokenAmount * (buyLiquidityTax + sellLiquidityTax)) / totalTax;
        uint256 halfLP   = lpTokens / 2;
        uint256 toSwap   = tokenAmount - halfLP;

        uint256 initBNB  = address(this).balance;
        _swapTokensForBNB(toSwap);
        uint256 gotBNB   = address(this).balance - initBNB;

        uint256 denominator = totalTax - (buyLiquidityTax + sellLiquidityTax) / 2;
        if (denominator == 0) return;

        uint256 bnbLP        = (gotBNB * ((buyLiquidityTax + sellLiquidityTax) / 2)) / denominator;
        uint256 bnbMarketing = (gotBNB * (buyMarketingTax + sellMarketingTax))        / denominator;
        uint256 bnbTeam      = (gotBNB * (buyTeamTax      + sellTeamTax))             / denominator;
        uint256 bnbTreasury  =  gotBNB - bnbLP - bnbMarketing - bnbTeam;

        if (halfLP > 0 && bnbLP > 0) {
            _addLiquidity(halfLP, bnbLP);
            emit SwapAndLiquify(halfLP, bnbLP);
        }
        _safeSendBNB(marketingWallet, bnbMarketing);
        _safeSendBNB(teamWallet,      bnbTeam);
        _safeSendBNB(treasuryWallet,  bnbTreasury);
    }

    function _swapTokensForBNB(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeRouter.WETH();
        _approve(address(this), address(pancakeRouter), tokenAmount);
        // amountOutMin = 0: no on-chain oracle is available at swap time.
        // Sandwich risk is accepted; the token owner may call manualSwap() when conditions are favourable.
        pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 bnbAmount) private {
        _approve(address(this), address(pancakeRouter), tokenAmount);
        // Minimums = 0: no oracle available.  LP is sent to burn address so any
        // temporary under-valuation is irreversible but does not benefit an attacker.
        pancakeRouter.addLiquidityETH{value: bnbAmount}(
            address(this), tokenAmount, 0, 0, BURN_ADDRESS, block.timestamp
        );
    }

    function _safeSendBNB(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert BNBTransferFailed();
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        if (owner_ == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // OWNER ADMIN
    // ─────────────────────────────────────────────────────────────────────

    function setBuyTaxes(uint256 mkt, uint256 team, uint256 tsy, uint256 burn, uint256 lp) external onlyOwner {
        if (mkt + team + tsy + burn + lp > MAX_TOTAL_TAX) revert TaxExceedsMax();
        buyMarketingTax = mkt; buyTeamTax = team; buyTreasuryTax = tsy;
        buyBurnTax = burn; buyLiquidityTax = lp;
        emit BuyTaxesUpdated(mkt, team, tsy, burn, lp);
    }

    function setSellTaxes(uint256 mkt, uint256 team, uint256 tsy, uint256 burn, uint256 lp) external onlyOwner {
        if (mkt + team + tsy + burn + lp > MAX_TOTAL_TAX) revert TaxExceedsMax();
        sellMarketingTax = mkt; sellTeamTax = team; sellTreasuryTax = tsy;
        sellBurnTax = burn; sellLiquidityTax = lp;
        emit SellTaxesUpdated(mkt, team, tsy, burn, lp);
    }

    function setWallets(address mkt, address team, address tsy) external onlyOwner {
        if (mkt == address(0) || team == address(0) || tsy == address(0)) revert ZeroAddress();
        marketingWallet = mkt; teamWallet = team; treasuryWallet = tsy;
        emit WalletsUpdated(mkt, team, tsy);
    }

    function setSwapThreshold(uint256 amount) external onlyOwner {
        if (amount < _totalSupply * MIN_SWAP_THRESHOLD_BPS / BPS_DENOM) revert SwapThresholdTooLow();
        swapThreshold = amount;
    }
    function excludeFromFee(address a, bool ex) external onlyOwner { _isExcludedFromFee[a] = ex; }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function manualSwap() external onlyOwner {
        uint256 taxBalance = _balances[address(this)] > _vestingBalance
            ? _balances[address(this)] - _vestingBalance
            : 0;
        if (taxBalance == 0) revert NothingToSwap();
        swapAndDistribute(taxBalance);
    }

    function rescueBNB(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = payable(to).call{value: address(this).balance}("");
        if (!ok) revert BNBTransferFailed();
    }

    function rescueTokens(address tokenAddr, address to) external onlyOwner {
        if (tokenAddr == address(this)) revert CannotRescueOwnToken();
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20Rescue(tokenAddr).balanceOf(address(this));
        bool ok = IERC20Rescue(tokenAddr).transfer(to, bal);
        if (!ok) revert TokenRescueFailed();
    }

    // ─────────────────────────────────────────────────────────────────────
    // VIEWS
    // ─────────────────────────────────────────────────────────────────────

    function getTotalBuyTax()  public view returns (uint256) {
        return buyMarketingTax + buyTeamTax + buyTreasuryTax + buyBurnTax + buyLiquidityTax;
    }
    function getTotalSellTax() public view returns (uint256) {
        return sellMarketingTax + sellTeamTax + sellTreasuryTax + sellBurnTax + sellLiquidityTax;
    }
    function isExcludedFromFee(address a) public view returns (bool) { return _isExcludedFromFee[a]; }
    function inBondingPhase()             public view returns (bool) { return _inBondingPhase; }

    // ─────────────────────────────────────────────────────────────────────
    // CREATOR VESTING  (self-custodied in this contract)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Called once by the factory after transferring creator tokens here.
     *         Starts the 12-month linear vesting schedule.
     */
    function setupVesting(address creator_, uint256 amount_) external override onlyFactory {
        if (vestingCreator != address(0)) revert VestingAlreadySet();
        if (creator_ == address(0))       revert ZeroAddress();
        if (amount_  == 0)                revert ZeroAmount();
        vestingCreator   = creator_;
        vestingTotal     = amount_;
        vestingStart     = block.timestamp;
        _vestingBalance  = amount_;
        emit VestingSetup(creator_, amount_);
    }

    /**
     * @notice Claim linearly vested tokens.  Callable only by the current token owner.
     *         If ownership is transferred, the new owner inherits vesting rights.
     *         vestingCreator records the original recipient for transparency only.
     *         Transfer is fee-free (address(this) is excluded from fees).
     */
    function claimVesting() external {
        if (msg.sender != _owner) revert NotOwner();
        if (vestingTotal == 0)    revert NoVesting();
        uint256 elapsed = block.timestamp - vestingStart;
        if (elapsed > VESTING_DURATION) elapsed = VESTING_DURATION;
        uint256 claimable = (vestingTotal * elapsed / VESTING_DURATION) - vestingClaimed;
        if (claimable == 0) revert NothingToClaim();
        vestingClaimed  += claimable;
        _vestingBalance -= claimable;
        _transfer(address(this), _owner, claimable);
        emit VestingClaimed(_owner, claimable);
    }

    /// @notice How many tokens the creator can claim right now.
    function claimableVesting() external view returns (uint256) {
        if (vestingTotal == 0) return 0;
        uint256 elapsed = block.timestamp - vestingStart;
        if (elapsed > VESTING_DURATION) elapsed = VESTING_DURATION;
        return (vestingTotal * elapsed / VESTING_DURATION) - vestingClaimed;
    }

    receive() external payable {}
}
