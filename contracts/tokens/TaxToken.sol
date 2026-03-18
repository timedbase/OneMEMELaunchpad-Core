// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface ILaunchpadToken {
    function postMigrateSetup() external;
    function metaURI() external view returns (string memory);
    function setMetaURI(string calldata uri_) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

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

interface IERC20Rescue {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract TaxToken is ILaunchpadToken {

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
    error BNBTransferFailed();
    error TokenRescueFailed();
    error PermitExpired();
    error InvalidSignature();

    address private _owner;
    address private _factory;
    address private _migrator;
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

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;
    bytes32 private _DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;

    IPancakeRouter02TT public pancakeRouter;
    address            public pancakePair;

    bool private inSwap;
    bool public  swapEnabled;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event WalletsUpdated(address marketing, address team, address treasury);
    event BuyTaxesUpdated(uint256 marketing, uint256 team, uint256 treasury, uint256 burn, uint256 lp);
    event SellTaxesUpdated(uint256 marketing, uint256 team, uint256 treasury, uint256 burn, uint256 lp);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnbReceived);
    event DexConfigured(address pair, address router);
    event MetaURIUpdated(string uri);

    modifier lockSwap()   { inSwap = true; _; inSwap = false; }
    modifier onlyOwner()  { if (msg.sender != _owner)   revert NotOwner();   _; }
    modifier onlyFactory()        { if (msg.sender != _factory) revert NotFactory(); _; }
    modifier onlyFactoryOrCurve() { if (msg.sender != _factory && msg.sender != _migrator) revert NotFactory(); _; }

    // Prevents direct initialization of the implementation contract.
    constructor() { _initialized = true; }

    function initForLaunchpad(
        string    calldata name_,
        string    calldata symbol_,
        uint256            totalSupply_,
        address            factory_,
        address            migrator_,
        address            tokenOwner_,
        string    calldata metaURI_,
        address            router_,
        address            vestingWallet_
    ) external {
        if (_initialized)               revert AlreadyInitialized();
        if (factory_      == address(0)) revert ZeroAddress();
        if (migrator_ == address(0)) revert ZeroAddress();
        if (tokenOwner_   == address(0)) revert ZeroAddress();
        if (router_       == address(0)) revert ZeroAddress();

        _initialized    = true;
        _inBondingPhase = true;
        _factory        = factory_;
        _migrator   = migrator_;
        _owner          = tokenOwner_;

        _name        = name_;
        _symbol      = symbol_;
        _totalSupply = totalSupply_;

        marketingWallet = tokenOwner_;
        teamWallet      = tokenOwner_;
        treasuryWallet  = tokenOwner_;

        swapThreshold = totalSupply_ / 1000;
        swapEnabled   = false;

        _isExcludedFromFee[factory_]       = true;
        _isExcludedFromFee[migrator_]  = true;
        _isExcludedFromFee[tokenOwner_]    = true;
        _isExcludedFromFee[address(this)]  = true;
        _isExcludedFromFee[BURN_ADDRESS]   = true;
        if (vestingWallet_ != address(0)) _isExcludedFromFee[vestingWallet_] = true;

        _metaURI = metaURI_;

        // Pair is created now; liquidity is added only at migration.
        pancakeRouter = IPancakeRouter02TT(router_);
        pancakePair   = IPancakeFactoryTT(pancakeRouter.factory()).createPair(address(this), pancakeRouter.WETH());
        _isExcludedFromFee[pancakePair] = true;

        _balances[factory_] = totalSupply_;
        emit Transfer(address(0), factory_, totalSupply_);
        emit OwnershipTransferred(address(0), tokenOwner_);

        _cachedChainId    = block.chainid;
        _DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    function metaURI() external view override returns (string memory) { return _metaURI; }

    function setMetaURI(string calldata uri_) external override onlyOwner {
        _metaURI = uri_;
        emit MetaURIUpdated(uri_);
    }

    function postMigrateSetup() external onlyFactoryOrCurve {
        if (!_inBondingPhase) revert DexAlreadyConfigured();
        _inBondingPhase = false;
        swapEnabled     = true;
        emit DexConfigured(pancakePair, address(pancakeRouter));
    }

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

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0)                            revert ZeroAmount();
        if (_balances[from] < amount)               revert InsufficientBalance();

        bool takeFee = !(_isExcludedFromFee[from] || _isExcludedFromFee[to]);

        if (!_inBondingPhase && swapEnabled && takeFee && !inSwap && from != pancakePair) {
            uint256 taxBalance = _balances[address(this)];
            if (taxBalance >= swapThreshold) swapAndDistribute(taxBalance);
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

    function swapAndDistribute(uint256 tokenAmount) private lockSwap {
        uint256 lpBPS    = buyLiquidityTax + sellLiquidityTax;
        uint256 totalTax = buyMarketingTax + buyTeamTax + buyTreasuryTax + lpBPS
                         + sellMarketingTax + sellTeamTax + sellTreasuryTax;
        if (totalTax == 0) return;

        uint256 halfLP = (tokenAmount * lpBPS / totalTax) / 2;
        uint256 preBNB = address(this).balance;
        _swapTokensForBNB(tokenAmount - halfLP);
        uint256 gotBNB = address(this).balance - preBNB;

        uint256 denom = totalTax - lpBPS / 2;
        if (denom == 0) return;

        uint256 bnbLP        = (gotBNB * (lpBPS / 2))                            / denom;
        uint256 bnbMarketing = (gotBNB * (buyMarketingTax + sellMarketingTax))   / denom;
        uint256 bnbTeam      = (gotBNB * (buyTeamTax      + sellTeamTax))        / denom;

        if (halfLP > 0 && bnbLP > 0) {
            _addLiquidity(halfLP, bnbLP);
            emit SwapAndLiquify(halfLP, bnbLP);
        }
        _safeSendBNB(marketingWallet, bnbMarketing);
        _safeSendBNB(teamWallet,      bnbTeam);
        _safeSendBNB(treasuryWallet,  gotBNB - bnbLP - bnbMarketing - bnbTeam);
    }

    function _swapTokensForBNB(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeRouter.WETH();
        _approve(address(this), address(pancakeRouter), tokenAmount);
        // amountOutMin = 0: no on-chain oracle available; owner may call manualSwap() when conditions suit.
        pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 bnbAmount) private {
        _approve(address(this), address(pancakeRouter), tokenAmount);
        // Minimums = 0: LP goes to the burn address, so any under-valuation is irreversible
        // and does not benefit an attacker.
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

    // Recomputed on chain forks.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _cachedChainId) return _DOMAIN_SEPARATOR;
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(_name)),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    function permit(
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH, owner_, spender, value, nonces[owner_]++, deadline
        ));
        address signer = ecrecover(
            keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash)),
            v, r, s
        );
        if (signer == address(0) || signer != owner_) revert InvalidSignature();
        _approve(owner_, spender, value);
    }

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
        uint256 taxBalance = _balances[address(this)];
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

    function getTotalBuyTax()  public view returns (uint256) {
        return buyMarketingTax + buyTeamTax + buyTreasuryTax + buyBurnTax + buyLiquidityTax;
    }
    function getTotalSellTax() public view returns (uint256) {
        return sellMarketingTax + sellTeamTax + sellTreasuryTax + sellBurnTax + sellLiquidityTax;
    }
    function isExcludedFromFee(address a) public view returns (bool) { return _isExcludedFromFee[a]; }
    function inBondingPhase()             public view returns (bool) { return _inBondingPhase; }

    receive() external payable {}
}
