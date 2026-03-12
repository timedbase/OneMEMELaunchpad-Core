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
 *   3. Factory calls enableTrading(pair, router) after DEX migration –
 *      pancakePair & router set, bonding phase disabled, normal fees begin.
 */
contract TaxToken is ILaunchpadToken {

    // ─── errors ────────────────────────────────────────────────────────
    error NotOwner();
    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error TaxExceedsMax();
    error BNBTransferFailed();

    // ─── ownership / init ───────────────────────────────────────────────
    address private _owner;
    address private _factory;
    bool    private _initialized;
    bool    private _inBondingPhase;

    // ─── ERC-20 metadata ────────────────────────────────────────────────
    string  private _name;
    string  private _symbol;
    uint8   private constant DECIMALS = 18;
    uint256 private _totalSupply;

    // ─── tax config ─────────────────────────────────────────────────────
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

    uint256 public constant MAX_TOTAL_TAX = 2500; // 25 %

    uint256 public swapThreshold;

    address public marketingWallet;
    address public teamWallet;
    address public treasuryWallet;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ─── balances & allowances ──────────────────────────────────────────
    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool)                        private _isExcludedFromFee;

    // ─── DEX state ──────────────────────────────────────────────────────
    IPancakeRouter02TT public pancakeRouter;
    address            public pancakePair;

    bool private inSwap;
    bool public  swapEnabled;

    // ─── Creator vesting (token contract is its own escrow) ───────────────
    address public vestingCreator;
    uint256 public vestingTotal;
    uint256 public vestingStart;
    uint256 public vestingClaimed;
    uint256 private constant VESTING_DURATION = 365 days;

    // ─── events ─────────────────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event WalletsUpdated(address marketing, address team, address treasury);
    event BuyTaxesUpdated(uint256 marketing, uint256 team, uint256 treasury, uint256 burn, uint256 lp);
    event SellTaxesUpdated(uint256 marketing, uint256 team, uint256 treasury, uint256 burn, uint256 lp);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnbReceived);
    event TradingEnabled(address pair, address router);
    event VestingSetup(address indexed creator, uint256 amount);
    event VestingClaimed(address indexed creator, uint256 amount);

    modifier lockSwap()   { inSwap = true; _; inSwap = false; }
    modifier onlyOwner()  { if (msg.sender != _owner)   revert NotOwner();   _; }
    modifier onlyFactory(){ if (msg.sender != _factory) revert NotFactory(); _; }

    // ─────────────────────────────────────────────────────────────────────
    // INIT
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice One-shot initialiser called by the factory immediately after clone
     *         deployment.  All tokens minted to factory_.
     * @param wallets_       [marketing, team, treasury]
     * @param buyTaxes_      [marketing, team, treasury, burn, liquidity] in bps
     * @param sellTaxes_     [marketing, team, treasury, burn, liquidity] in bps
     * @param swapThreshold_ Min contract token balance before swapAndDistribute
     * @param tokenOwner_    Address that owns the token after migration
     */
    function initForLaunchpad(
        string    calldata name_,
        string    calldata symbol_,
        uint256            totalSupply_,
        address            factory_,
        address[3] calldata wallets_,
        uint256[5] calldata buyTaxes_,
        uint256[5] calldata sellTaxes_,
        uint256            swapThreshold_,
        address            tokenOwner_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (factory_    == address(0)) revert ZeroAddress();
        if (tokenOwner_ == address(0)) revert ZeroAddress();
        for (uint256 i; i < 3; ) { if (wallets_[i] == address(0)) revert ZeroAddress(); unchecked { ++i; } }

        _initialized    = true;
        _inBondingPhase = true;
        _factory        = factory_;
        _owner          = tokenOwner_;

        _name        = name_;
        _symbol      = symbol_;
        _totalSupply = totalSupply_;

        marketingWallet = wallets_[0];
        teamWallet      = wallets_[1];
        treasuryWallet  = wallets_[2];

        buyMarketingTax  = buyTaxes_[0]; buyTeamTax      = buyTaxes_[1];
        buyTreasuryTax   = buyTaxes_[2]; buyBurnTax      = buyTaxes_[3];
        buyLiquidityTax  = buyTaxes_[4];
        if (buyMarketingTax + buyTeamTax + buyTreasuryTax + buyBurnTax + buyLiquidityTax > MAX_TOTAL_TAX)
            revert TaxExceedsMax();

        sellMarketingTax = sellTaxes_[0]; sellTeamTax     = sellTaxes_[1];
        sellTreasuryTax  = sellTaxes_[2]; sellBurnTax     = sellTaxes_[3];
        sellLiquidityTax = sellTaxes_[4];
        if (sellMarketingTax + sellTeamTax + sellTreasuryTax + sellBurnTax + sellLiquidityTax > MAX_TOTAL_TAX)
            revert TaxExceedsMax();

        swapThreshold = swapThreshold_;
        swapEnabled   = false; // enabled after migration

        // Exclude key addresses from fees
        _isExcludedFromFee[factory_]       = true;
        _isExcludedFromFee[tokenOwner_]    = true;
        _isExcludedFromFee[address(this)]  = true;
        _isExcludedFromFee[wallets_[0]]    = true;
        _isExcludedFromFee[wallets_[1]]    = true;
        _isExcludedFromFee[wallets_[2]]    = true;
        _isExcludedFromFee[BURN_ADDRESS]   = true;

        // Mint entire supply to factory
        _balances[factory_] = totalSupply_;
        emit Transfer(address(0), factory_, totalSupply_);
        emit OwnershipTransferred(address(0), tokenOwner_);
    }

    /**
     * @notice Called by factory after DEX liquidity is seeded.
     *         Unlocks normal tax behaviour on PancakeSwap pair.
     */
    function enableTrading(address pair_, address router_) external override onlyFactory {
        require(_inBondingPhase,        "Trading already enabled");
        require(pair_   != address(0),  "Zero pair");
        require(router_ != address(0),  "Zero router");

        pancakeRouter   = IPancakeRouter02TT(router_);
        pancakePair     = pair_;
        _inBondingPhase = false;
        swapEnabled     = true;

        // Exclude pair from fees
        _isExcludedFromFee[pair_] = true;

        emit TradingEnabled(pair_, router_);
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
        require(allowed >= amount, "Exceeds allowance");
        unchecked { _allowances[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // TRANSFER LOGIC
    // ─────────────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0) && to != address(0), "Zero address");
        require(amount > 0 && _balances[from] >= amount, "Invalid amount");

        bool takeFee = !(_isExcludedFromFee[from] || _isExcludedFromFee[to]);

        // Auto-swap only after bonding phase ends and pair exists
        if (!_inBondingPhase && swapEnabled && takeFee && !inSwap && from != pancakePair) {
            uint256 cb = _balances[address(this)];
            if (cb >= swapThreshold) swapAndDistribute(cb);
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
        pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 bnbAmount) private {
        _approve(address(this), address(pancakeRouter), tokenAmount);
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
        require(owner_ != address(0) && spender != address(0), "Zero address");
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

    function setSwapThreshold(uint256 amount)  external onlyOwner { swapThreshold = amount;  }
    function setSwapEnabled(bool enabled)       external onlyOwner { swapEnabled   = enabled; }
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
        require(_balances[address(this)] > 0, "Nothing to swap");
        swapAndDistribute(_balances[address(this)]);
    }

    function rescueBNB() external onlyOwner {
        (bool ok,) = payable(_owner).call{value: address(this).balance}("");
        if (!ok) revert BNBTransferFailed();
    }

    function rescueTokens(address tokenAddr) external onlyOwner {
        require(tokenAddr != address(this), "Cannot rescue own");
        uint256 bal = ILaunchpadToken(tokenAddr).balanceOf(address(this));
        ILaunchpadToken(tokenAddr).transfer(_owner, bal);
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
        require(vestingCreator == address(0), "Vesting already set");
        require(creator_ != address(0),       "Zero creator");
        require(amount_  > 0,                 "Zero amount");
        vestingCreator = creator_;
        vestingTotal   = amount_;
        vestingStart   = block.timestamp;
        emit VestingSetup(creator_, amount_);
    }

    /**
     * @notice Claim linearly vested tokens.  Callable only by the current token owner.
     *         If ownership is transferred, the new owner inherits vesting rights.
     *         vestingCreator records the original recipient for transparency only.
     *         Transfer is fee-free (address(this) is excluded from fees).
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

    /// @notice How many tokens the creator can claim right now.
    function claimableVesting() external view returns (uint256) {
        if (vestingTotal == 0) return 0;
        uint256 elapsed = block.timestamp - vestingStart;
        if (elapsed > VESTING_DURATION) elapsed = VESTING_DURATION;
        return (vestingTotal * elapsed / VESTING_DURATION) - vestingClaimed;
    }

    receive() external payable {}
}
