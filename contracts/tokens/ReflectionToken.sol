// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "../interfaces/ILaunchpadToken.sol";

interface IPancakeRouter02RFL {
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

interface IPancakeFactoryRFL {
    function createPair(address tokenA, address tokenB) external returns (address);
    function getPair(address tokenA, address tokenB)   external view returns (address);
}

/**
 * @title ReflectionToken  (OneMEME Launchpad)
 * @notice ERC-20 with RFI-style reflection rewards distributed passively to
 *         all non-excluded holders.
 *         Deployed as a minimal-proxy clone by LaunchpadFactory.
 *
 * Lifecycle (same as TaxToken):
 *   1. initForLaunchpad() – mints entire supply to factory (excluded from
 *      reflection), bonding-curve phase active.
 *   2. Factory transfers tokens to buyers; no reflection or fees during BC
 *      phase (factory excluded from fee).
 *   3. enableTrading(pair, router) – pair set, bonding phase off, DEX trading
 *      with full reflection & tax logic begins.
 */
contract ReflectionToken is ILaunchpadToken {

    // ─── errors ────────────────────────────────────────────────────────
    error NotOwner();
    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error ExceedsMax();
    error ExceedsAllowance();
    error AlreadyExcluded();
    error NotExcluded();
    error BNBTransferFailed();

    // ─── ownership / init ───────────────────────────────────────────────
    address private _owner;
    address private _factory;
    bool    private _initialized;
    bool    private _inBondingPhase;

    // ─── ERC-20 metadata ────────────────────────────────────────────────
    string  private _name;
    string  private _symbol;
    string  private _metaURI;
    uint8   private constant DECIMALS = 18;

    // ─── reflection accounting ──────────────────────────────────────────
    uint256 private _tTotal;   // token-space supply
    uint256 private _rTotal;   // reflection-space supply
    uint256 private constant MAX_UINT = ~uint256(0);

    mapping(address => uint256) private _rOwned; // reflection balance
    mapping(address => uint256) private _tOwned; // token balance (excluded only)
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool)    private _isExcludedFromFee;
    mapping(address => bool)    private _isExcludedFromReflection;
    address[]                   private _excluded; // reflection-excluded list

    uint256 private _tFeeTotal; // cumulative reflection distributed

    // ─── tax config ─────────────────────────────────────────────────────
    uint256 public buyMarketingTax;
    uint256 public buyTeamTax;
    uint256 public buyLiquidityTax;
    uint256 public buyBurnTax;
    uint256 public buyReflectionTax;

    uint256 public sellMarketingTax;
    uint256 public sellTeamTax;
    uint256 public sellLiquidityTax;
    uint256 public sellBurnTax;
    uint256 public sellReflectionTax;

    uint256 public constant MAX_TOTAL_TAX = 2500; // 25 %

    uint256 public swapThreshold;

    address public marketingWallet;
    address public teamWallet;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ─── DEX state ──────────────────────────────────────────────────────
    IPancakeRouter02RFL public pancakeRouter;
    address             public pancakePair;

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
    event WalletsUpdated(address marketing, address team);
    event BuyTaxesUpdated(uint256 marketing, uint256 team, uint256 lp, uint256 burn, uint256 reflection);
    event SellTaxesUpdated(uint256 marketing, uint256 team, uint256 lp, uint256 burn, uint256 reflection);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnb);
    event ExcludedFromReflection(address indexed account);
    event IncludedInReflection(address indexed account);
    event TradingEnabled(address pair, address router);
    event MetaURIUpdated(string uri);
    event VestingSetup(address indexed creator, uint256 amount);
    event VestingClaimed(address indexed creator, uint256 amount);

    modifier lockSwap()   { inSwap = true; _; inSwap = false; }
    modifier onlyOwner()  { if (msg.sender != _owner)   revert NotOwner();   _; }
    modifier onlyFactory(){ if (msg.sender != _factory) revert NotFactory(); _; }

    // ─────────────────────────────────────────────────────────────────────
    // INIT
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice One-shot initialiser called by the factory.
     * @param wallets_      [marketing, team]
     * @param buyTaxes_     [marketing, team, liquidity, burn, reflection] bps
     * @param sellTaxes_    [marketing, team, liquidity, burn, reflection] bps
     */
    function initForLaunchpad(
        string    calldata name_,
        string    calldata symbol_,
        uint256            totalSupply_,
        address            factory_,
        address[2] calldata wallets_,
        uint256[5] calldata buyTaxes_,
        uint256[5] calldata sellTaxes_,
        uint256            swapThreshold_,
        address            tokenOwner_,
        string    calldata metaURI_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (factory_    == address(0)) revert ZeroAddress();
        if (tokenOwner_ == address(0)) revert ZeroAddress();
        if (wallets_[0] == address(0) || wallets_[1] == address(0)) revert ZeroAddress();

        _initialized    = true;
        _inBondingPhase = true;
        _factory        = factory_;
        _owner          = tokenOwner_;

        _name   = name_;
        _symbol = symbol_;
        _tTotal = totalSupply_;
        _rTotal = MAX_UINT - (MAX_UINT % _tTotal);

        marketingWallet = wallets_[0];
        teamWallet      = wallets_[1];

        buyMarketingTax  = buyTaxes_[0]; buyTeamTax       = buyTaxes_[1];
        buyLiquidityTax  = buyTaxes_[2]; buyBurnTax       = buyTaxes_[3];
        buyReflectionTax = buyTaxes_[4];
        if (_sumBuy() > MAX_TOTAL_TAX) revert ExceedsMax();

        sellMarketingTax  = sellTaxes_[0]; sellTeamTax       = sellTaxes_[1];
        sellLiquidityTax  = sellTaxes_[2]; sellBurnTax       = sellTaxes_[3];
        sellReflectionTax = sellTaxes_[4];
        if (_sumSell() > MAX_TOTAL_TAX) revert ExceedsMax();

        swapThreshold = swapThreshold_;
        swapEnabled   = false;

        // Fee exclusions
        _isExcludedFromFee[factory_]      = true;
        _isExcludedFromFee[tokenOwner_]   = true;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[wallets_[0]]   = true;
        _isExcludedFromFee[wallets_[1]]   = true;
        _isExcludedFromFee[BURN_ADDRESS]  = true;

        // Reflection exclusions (factory holds all tokens — must use _tOwned)
        _rOwned[factory_] = _rTotal;
        _excludeFromReflectionInternal(factory_);
        _excludeFromReflectionInternal(address(this));
        _excludeFromReflectionInternal(BURN_ADDRESS);

        _metaURI = metaURI_;

        emit Transfer(address(0), factory_, _tTotal);
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
     * @notice Called by factory after DEX migration.
     *         Sets pair, excludes it from reflection, enables trading.
     */
    function enableTrading(address pair_, address router_) external override onlyFactory {
        require(_inBondingPhase,       "Trading already enabled");
        require(pair_   != address(0), "Zero pair");
        require(router_ != address(0), "Zero router");

        pancakeRouter   = IPancakeRouter02RFL(router_);
        pancakePair     = pair_;
        _inBondingPhase = false;
        swapEnabled     = true;

        _isExcludedFromFee[pair_] = true;
        if (!_isExcludedFromReflection[pair_]) {
            _excludeFromReflectionInternal(pair_);
        }

        emit TradingEnabled(pair_, router_);
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC-20
    // ─────────────────────────────────────────────────────────────────────

    function name()        public view returns (string memory) { return _name;   }
    function symbol()      public view returns (string memory) { return _symbol; }
    function decimals()    public pure returns (uint8)         { return DECIMALS;}
    function totalSupply() public view override returns (uint256) { return _tTotal; }
    function owner()       public view returns (address) { return _owner; }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcludedFromReflection[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

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
    // REFLECTION HELPERS
    // ─────────────────────────────────────────────────────────────────────

    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        if (rAmount > _rTotal) revert ExceedsMax();
        return rAmount / _getRate();
    }

    function reflectionFromToken(uint256 tAmount) public view returns (uint256) {
        if (tAmount > _tTotal) revert ExceedsMax();
        return tAmount * _getRate();
    }

    function totalFeesReflected() public view returns (uint256) { return _tFeeTotal; }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply / tSupply;
    }

    function _getCurrentSupply() private view returns (uint256 rSupply, uint256 tSupply) {
        rSupply = _rTotal;
        tSupply = _tTotal;
        uint256 len = _excluded.length;
        for (uint256 i; i < len; ) {
            address ex = _excluded[i];
            if (_rOwned[ex] > rSupply || _tOwned[ex] > tSupply) return (_rTotal, _tTotal);
            unchecked { rSupply -= _rOwned[ex]; tSupply -= _tOwned[ex]; ++i; }
        }
        if (rSupply < _rTotal / _tTotal) return (_rTotal, _tTotal);
    }

    // ─────────────────────────────────────────────────────────────────────
    // TRANSFER LOGIC
    // ─────────────────────────────────────────────────────────────────────

    struct FeeValues {
        uint256 tReflection;
        uint256 tBurn;
        uint256 tToContract;
        uint256 tTotal;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        bool takeFee = !(_isExcludedFromFee[from] || _isExcludedFromFee[to]);

        if (!_inBondingPhase && swapEnabled && takeFee && !inSwap && from != pancakePair) {
            uint256 cb = balanceOf(address(this));
            if (cb >= swapThreshold) swapAndDistribute(cb);
        }

        _tokenTransfer(from, to, amount, takeFee);
    }

    function _calcFees(uint256 tAmount, bool isBuy, bool isSell) private view returns (FeeValues memory f) {
        if (isBuy) {
            f.tReflection  = (tAmount * buyReflectionTax) / 10000;
            f.tBurn        = (tAmount * buyBurnTax)       / 10000;
            f.tToContract  = (tAmount * (buyMarketingTax + buyTeamTax + buyLiquidityTax)) / 10000;
        } else if (isSell) {
            f.tReflection  = (tAmount * sellReflectionTax) / 10000;
            f.tBurn        = (tAmount * sellBurnTax)        / 10000;
            f.tToContract  = (tAmount * (sellMarketingTax + sellTeamTax + sellLiquidityTax)) / 10000;
        }
        f.tTotal = f.tReflection + f.tBurn + f.tToContract;
    }

    function _tokenTransfer(address sender, address recipient, uint256 tAmount, bool takeFee) private {
        FeeValues memory f;
        if (takeFee) f = _calcFees(tAmount, sender == pancakePair, recipient == pancakePair);

        uint256 tTransferAmount = tAmount - f.tTotal;
        uint256 currentRate     = _getRate();
        uint256 rAmount         = tAmount * currentRate;
        uint256 rTransferAmount = rAmount - (f.tTotal * currentRate);

        // Sender update
        if (_isExcludedFromReflection[sender]) { _tOwned[sender] -= tAmount; }
        _rOwned[sender] -= rAmount;

        // Recipient update
        if (_isExcludedFromReflection[recipient]) { _tOwned[recipient] += tTransferAmount; }
        _rOwned[recipient] += rTransferAmount;

        emit Transfer(sender, recipient, tTransferAmount);
        _processFees(sender, f, currentRate);
    }

    function _processFees(address sender, FeeValues memory f, uint256 rate) private {
        if (f.tReflection > 0) {
            _rTotal    -= f.tReflection * rate;
            _tFeeTotal += f.tReflection;
        }
        if (f.tBurn > 0) {
            uint256 rBurn = f.tBurn * rate;
            _rOwned[BURN_ADDRESS] += rBurn;
            _tOwned[BURN_ADDRESS] += f.tBurn;
            emit Transfer(sender, BURN_ADDRESS, f.tBurn);
        }
        if (f.tToContract > 0) {
            uint256 rContract = f.tToContract * rate;
            _rOwned[address(this)] += rContract;
            _tOwned[address(this)] += f.tToContract;
            emit Transfer(sender, address(this), f.tToContract);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // SWAP & DISTRIBUTE
    // ─────────────────────────────────────────────────────────────────────

    function swapAndDistribute(uint256 tokenAmount) private lockSwap {
        uint256 totalBuy  = buyMarketingTax  + buyTeamTax  + buyLiquidityTax;
        uint256 totalSell = sellMarketingTax + sellTeamTax + sellLiquidityTax;
        uint256 totalTax  = totalBuy + totalSell;
        if (totalTax == 0) return;

        uint256 lpTokens = (tokenAmount * (buyLiquidityTax + sellLiquidityTax)) / totalTax;
        uint256 halfLP   = lpTokens / 2;
        uint256 toSwap   = tokenAmount - halfLP;

        uint256 initBNB = address(this).balance;
        _swapTokensForBNB(toSwap);
        uint256 gotBNB  = address(this).balance - initBNB;

        uint256 denom = totalTax - (buyLiquidityTax + sellLiquidityTax) / 2;
        if (denom == 0) return;

        uint256 bnbLP        = (gotBNB * ((buyLiquidityTax + sellLiquidityTax) / 2)) / denom;
        uint256 bnbMarketing = (gotBNB * (buyMarketingTax + sellMarketingTax))        / denom;
        uint256 bnbTeam      =  gotBNB - bnbLP - bnbMarketing;

        if (halfLP > 0 && bnbLP > 0) {
            _addLiquidity(halfLP, bnbLP);
            emit SwapAndLiquify(halfLP, bnbLP);
        }
        _safeSendBNB(marketingWallet, bnbMarketing);
        _safeSendBNB(teamWallet,      bnbTeam);
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
        if (owner_ == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // REFLECTION EXCLUSION
    // ─────────────────────────────────────────────────────────────────────

    function _excludeFromReflectionInternal(address account) private {
        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcludedFromReflection[account] = true;
        _excluded.push(account);
        emit ExcludedFromReflection(account);
    }

    function excludeFromReflection(address account) external onlyOwner {
        if (_isExcludedFromReflection[account]) revert AlreadyExcluded();
        _excludeFromReflectionInternal(account);
    }

    function includeInReflection(address account) external onlyOwner {
        if (!_isExcludedFromReflection[account]) revert NotExcluded();
        uint256 len = _excluded.length;
        for (uint256 i; i < len; ) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[len - 1];
                _excluded.pop();
                break;
            }
            unchecked { ++i; }
        }
        _tOwned[account]                   = 0;
        _isExcludedFromReflection[account] = false;
        emit IncludedInReflection(account);
    }

    // ─────────────────────────────────────────────────────────────────────
    // OWNER ADMIN
    // ─────────────────────────────────────────────────────────────────────

    function setBuyTaxes(uint256 mkt, uint256 team, uint256 lp, uint256 burn, uint256 rfl) external onlyOwner {
        if (mkt + team + lp + burn + rfl > MAX_TOTAL_TAX) revert ExceedsMax();
        buyMarketingTax = mkt; buyTeamTax = team; buyLiquidityTax = lp;
        buyBurnTax = burn; buyReflectionTax = rfl;
        emit BuyTaxesUpdated(mkt, team, lp, burn, rfl);
    }

    function setSellTaxes(uint256 mkt, uint256 team, uint256 lp, uint256 burn, uint256 rfl) external onlyOwner {
        if (mkt + team + lp + burn + rfl > MAX_TOTAL_TAX) revert ExceedsMax();
        sellMarketingTax = mkt; sellTeamTax = team; sellLiquidityTax = lp;
        sellBurnTax = burn; sellReflectionTax = rfl;
        emit SellTaxesUpdated(mkt, team, lp, burn, rfl);
    }

    function setWallets(address mkt, address team) external onlyOwner {
        if (mkt == address(0) || team == address(0)) revert ZeroAddress();
        marketingWallet = mkt; teamWallet = team;
        emit WalletsUpdated(mkt, team);
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
        uint256 cb = balanceOf(address(this));
        if (cb == 0) revert ZeroAmount();
        swapAndDistribute(cb);
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

    function getTotalBuyTax()  public view returns (uint256) { return _sumBuy();  }
    function getTotalSellTax() public view returns (uint256) { return _sumSell(); }

    function _sumBuy()  private view returns (uint256) {
        return buyMarketingTax + buyTeamTax + buyLiquidityTax + buyBurnTax + buyReflectionTax;
    }
    function _sumSell() private view returns (uint256) {
        return sellMarketingTax + sellTeamTax + sellLiquidityTax + sellBurnTax + sellReflectionTax;
    }

    function isExcludedFromFee(address a)        public view returns (bool) { return _isExcludedFromFee[a]; }
    function isExcludedFromReflection(address a) public view returns (bool) { return _isExcludedFromReflection[a]; }
    function excludedCount()                     public view returns (uint256) { return _excluded.length; }
    function excludedAt(uint256 i)               public view returns (address) { return _excluded[i]; }
    function inBondingPhase()                    public view returns (bool) { return _inBondingPhase; }

    // ─────────────────────────────────────────────────────────────────────
    // CREATOR VESTING  (self-custodied in this contract)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Called once by the factory after transferring creator tokens here.
     *         address(this) is excluded from both fees and reflection, so the
     *         tokens are held in _tOwned and transferred cleanly to the creator.
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
