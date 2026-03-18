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
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path,
        address to, uint deadline
    ) external;
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPancakeFactoryRFL {
    function createPair(address tokenA, address tokenB) external returns (address);
    function getPair(address tokenA, address tokenB)   external view returns (address);
}

/**
 * @title ReflectionToken  (OneMEME Launchpad)
 * @notice ERC-20 with RFI-style passive reflection and optional custom reflection
 *         token.  Deployed as a minimal-proxy clone by LaunchpadFactory.
 *
 * Lifecycle:
 *   1. initForLaunchpad() — mints entire supply to factory (excluded from
 *      reflection), bonding-curve phase active.  All taxes start at 0 %;
 *      the token owner must call setBuyTaxes / setSellTaxes to enable them.
 *   2. Factory transfers tokens to buyers; no fees during BC phase.
 *   3. postMigrateSetup(pair, router) — pair set, bonding phase off, full
 *      reflection & tax logic begins.
 *
 * Reflection distribution:
 *   - Native mode  (reflectionToken == address(0)): RFI-style, every non-excluded
 *     holder's balance passively increases as _rTotal is reduced.
 *   - Custom mode  (reflectionToken != address(0)): reflection tax is accumulated
 *     and swapped to the set token, then pushed proportionally to all holders
 *     whose balance meets the minimum threshold (default 0.02 % of total supply;
 *     owner may raise this but never lower it below 0.02 %).
 *
 * Vesting:
 *   - Creator tokens (5 % allocation) are held in address(this) as self-escrow.
 *   - _vestingBalance tracks this portion separately from accumulated taxes so
 *     swapAndDistribute never consumes unvested tokens.
 */
contract ReflectionToken is ILaunchpadToken {

    error NotOwner();
    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error ExceedsMax();
    error ExceedsAllowance();
    error AlreadyExcluded();
    error NotExcluded();
    error DexAlreadyConfigured();
    error CannotReflectSelf();
    error CannotRescueOwnToken();
    error VestingAlreadySet();
    error NoVesting();
    error NothingToClaim();
    error InsufficientBalance();
    error BNBTransferFailed();
    error BelowMinReflectionThreshold();
    error SwapThresholdTooLow();
    error ReflectionTransferFailed();
    error TokenRescueFailed();
    error PermitExpired();
    error InvalidSignature();

    address private _owner;
    address private _factory;
    address private _bondingCurve;
    bool    private _initialized;
    bool    private _inBondingPhase;

    string  private _name;
    string  private _symbol;
    string  private _metaURI;
    uint8   private constant DECIMALS = 18;

    uint256 private _tTotal;
    uint256 private _rTotal;
    uint256 private constant MAX_UINT = ~uint256(0);

    mapping(address => uint256) private _rOwned;
    mapping(address => uint256) private _tOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool)    private _isExcludedFromFee;
    mapping(address => bool)    private _isExcludedFromReflection;
    address[]                   private _excluded;

    // ─── EIP-2612 Permit ──────────────────────────────────────────────────
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;
    bytes32 private _DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;

    uint256 private _tFeeTotal;

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

    uint256 public constant MAX_TOTAL_TAX = 1000; // 10 %

    // 0.02 % of total supply — minimum holder balance to qualify for custom reflection.
    // Owner can set reflectionMinBalance higher but never lower than this floor.
    uint256 private constant MIN_REFLECTION_BPS     = 2;   // 0.02 %
    // 0.02 % of total supply — floor for swapThreshold; prevents zero-amount swap DoS.
    uint256 private constant MIN_SWAP_THRESHOLD_BPS = 2;   // 0.02 %
    uint256 private constant BPS_DENOM              = 10000;

    // Hard cap on the push-distribution holder list to prevent OOG in _distributeReflection.
    // At 500 holders, two full iterations cost ~10–15 M gas, safely within BSC's 30 M gas limit.
    // Holders beyond the cap do not participate in custom reflection push-distribution but
    // continue to receive native RFI reflection (if the token is in native mode).
    // The owner can switch to native mode via setReflectionToken(address(0)) at any time.
    uint256 public constant MAX_REFLECTION_HOLDERS = 500;

    uint256 public swapThreshold;

    address public marketingWallet;
    address public teamWallet;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IPancakeRouter02RFL public pancakeRouter;
    address             public pancakePair;

    bool private inSwap;
    bool public  swapEnabled;

    /// @notice address(0) = native RFI mode (default).
    ///         When set, the reflection-tax portion is swapped to this token
    ///         then pushed proportionally to all qualifying holders.
    address public reflectionToken;

    /// @notice Minimum token balance required to receive custom reflection.
    ///         Initialised to 0.02 % of total supply; owner may only raise it.
    uint256 public reflectionMinBalance;

    address[] private _holders;
    mapping(address => uint256) private _holderIndex; // 1-based index; 0 = not in list

    uint256 private _toSwapForReflection;

    address public vestingCreator;
    uint256 public vestingTotal;
    uint256 public vestingStart;
    uint256 public vestingClaimed;
    uint256 private constant VESTING_DURATION = 365 days;

    // Tracks the vesting escrow portion held in address(this).
    // Excluded from swapAndDistribute so tax swaps never consume vested tokens.
    uint256 private _vestingBalance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event WalletsUpdated(address marketing, address team);
    event BuyTaxesUpdated(uint256 marketing, uint256 team, uint256 lp, uint256 burn, uint256 reflection);
    event SellTaxesUpdated(uint256 marketing, uint256 team, uint256 lp, uint256 burn, uint256 reflection);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnb);
    event ExcludedFromReflection(address indexed account);
    event IncludedInReflection(address indexed account);
    event DexConfigured(address pair, address router);
    event MetaURIUpdated(string uri);
    event ReflectionTokenSet(address indexed token);
    event ReflectionMinBalanceSet(uint256 minBalance);
    event CustomReflectionDistributed(uint256 tokensSold, uint256 rewardDistributed, uint256 recipients);
    event VestingSetup(address indexed creator, uint256 amount);
    event VestingClaimed(address indexed owner, uint256 amount);

    modifier lockSwap()   { inSwap = true; _; inSwap = false; }
    modifier onlyOwner()  { if (msg.sender != _owner)   revert NotOwner();   _; }
    modifier onlyFactory()        { if (msg.sender != _factory) revert NotFactory(); _; }
    modifier onlyFactoryOrCurve() { if (msg.sender != _factory && msg.sender != _bondingCurve) revert NotFactory(); _; }

    /// @dev Prevents direct initialization of the implementation contract.
    constructor() { _initialized = true; }

    // ─────────────────────────────────────────────────────────────────────
    // INIT
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice One-shot initialiser called by the factory.
     *         Wallets default to tokenOwner_, swapThreshold defaults to 0.1 % of supply.
     *         All taxes start at 0 % — configure post-deployment via setBuyTaxes / setSellTaxes.
     * @param router_  PancakeSwap V2 router — stored and used to create the pair immediately
     */
    function initForLaunchpad(
        string    calldata name_,
        string    calldata symbol_,
        uint256            totalSupply_,
        address            factory_,
        address            bondingCurve_,
        address            tokenOwner_,
        string    calldata metaURI_,
        address            router_
    ) external {
        if (_initialized)               revert AlreadyInitialized();
        if (factory_      == address(0)) revert ZeroAddress();
        if (bondingCurve_ == address(0)) revert ZeroAddress();
        if (tokenOwner_   == address(0)) revert ZeroAddress();
        if (router_       == address(0)) revert ZeroAddress();

        _initialized    = true;
        _inBondingPhase = true;
        _factory        = factory_;
        _bondingCurve   = bondingCurve_;
        _owner          = tokenOwner_;

        _name   = name_;
        _symbol = symbol_;
        _tTotal = totalSupply_;
        _rTotal = MAX_UINT - (MAX_UINT % _tTotal);

        marketingWallet = tokenOwner_;
        teamWallet      = tokenOwner_;

        swapThreshold = totalSupply_ / 1000;
        swapEnabled   = false;

        reflectionMinBalance = (_tTotal * MIN_REFLECTION_BPS) / BPS_DENOM;

        _isExcludedFromFee[factory_]       = true;
        _isExcludedFromFee[bondingCurve_]  = true;
        _isExcludedFromFee[tokenOwner_]    = true;
        _isExcludedFromFee[address(this)]  = true;
        _isExcludedFromFee[BURN_ADDRESS]   = true;

        // factory holds all tokens and must use _tOwned.
        // BondingCurve is also excluded: it holds large balances and must not
        // receive or skew passive reflection distributions.
        _rOwned[factory_] = _rTotal;
        _excludeFromReflectionInternal(factory_);
        _excludeFromReflectionInternal(bondingCurve_);
        _excludeFromReflectionInternal(address(this));
        _excludeFromReflectionInternal(BURN_ADDRESS);

        _metaURI = metaURI_;

        // Store router and create the PancakeSwap pair immediately.
        // Liquidity is added only at migration; during bonding phase the pair holds nothing.
        pancakeRouter = IPancakeRouter02RFL(router_);
        pancakePair   = IPancakeFactoryRFL(pancakeRouter.factory()).createPair(address(this), pancakeRouter.WETH());
        _isExcludedFromFee[pancakePair] = true;
        _excludeFromReflectionInternal(pancakePair);

        emit Transfer(address(0), factory_, _tTotal);
        emit OwnershipTransferred(address(0), tokenOwner_);

        _cachedChainId    = block.chainid;
        _DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    // ─────────────────────────────────────────────────────────────────────
    // METADATA URI
    // ─────────────────────────────────────────────────────────────────────

    function metaURI() external view override returns (string memory) { return _metaURI; }

    function setMetaURI(string calldata uri_) external override onlyOwner {
        _metaURI = uri_;
        emit MetaURIUpdated(uri_);
    }

    /**
     * @notice Called by the factory after DEX liquidity has been seeded.
     *         Router, pair, and all exclusions are set from initForLaunchpad;
     *         this simply exits the bonding phase and enables normal behaviour.
     */
    function postMigrateSetup() external onlyFactoryOrCurve {
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
            uint256 rawBalance = balanceOf(address(this));
            uint256 taxBalance = rawBalance > _vestingBalance
                ? rawBalance - _vestingBalance
                : 0;
            if (taxBalance > 0 && taxBalance >= swapThreshold) swapAndDistribute(taxBalance);
        }

        _tokenTransfer(from, to, amount, takeFee);
    }

    function _calcFees(uint256 tAmount, bool isBuy, bool isSell) private view returns (FeeValues memory f) {
        if (isBuy) {
            f.tReflection  = (tAmount * buyReflectionTax) / BPS_DENOM;
            f.tBurn        = (tAmount * buyBurnTax)       / BPS_DENOM;
            f.tToContract  = (tAmount * (buyMarketingTax + buyTeamTax + buyLiquidityTax)) / BPS_DENOM;
        } else if (isSell) {
            f.tReflection  = (tAmount * sellReflectionTax) / BPS_DENOM;
            f.tBurn        = (tAmount * sellBurnTax)        / BPS_DENOM;
            f.tToContract  = (tAmount * (sellMarketingTax + sellTeamTax + sellLiquidityTax)) / BPS_DENOM;
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

        if (_isExcludedFromReflection[sender]) { _tOwned[sender] -= tAmount; }
        _rOwned[sender] -= rAmount;

        if (_isExcludedFromReflection[recipient]) { _tOwned[recipient] += tTransferAmount; }
        _rOwned[recipient] += rTransferAmount;

        emit Transfer(sender, recipient, tTransferAmount);
        _processFees(sender, f, currentRate);

        _updateHolderList(sender);
        _updateHolderList(recipient);
    }

    function _processFees(address sender, FeeValues memory f, uint256 rate) private {
        if (f.tReflection > 0) {
            if (reflectionToken == address(0)) {
                // Native RFI: passively increase all holders' balances by reducing _rTotal.
                _rTotal    -= f.tReflection * rate;
                _tFeeTotal += f.tReflection;
            } else {
                // Custom token: accumulate here for swap → push distribution.
                _rOwned[address(this)] += f.tReflection * rate;
                _tOwned[address(this)] += f.tReflection;
                _toSwapForReflection   += f.tReflection;
                emit Transfer(sender, address(this), f.tReflection);
            }
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
        uint256 reflAmount = _toSwapForReflection;
        if (reflAmount > 0 && reflectionToken != address(0)) {
            _toSwapForReflection = 0;
            uint256 preBal   = IERC20Minimal(reflectionToken).balanceOf(address(this));
            _swapForReflectionToken(reflAmount);
            uint256 received = IERC20Minimal(reflectionToken).balanceOf(address(this)) - preBal;
            if (received > 0) {
                emit CustomReflectionDistributed(reflAmount, received, _distributeReflection(received));
            }
            tokenAmount -= reflAmount;
        }

        uint256 lpBPS    = buyLiquidityTax + sellLiquidityTax;
        uint256 totalTax = buyMarketingTax + buyTeamTax + lpBPS
                         + sellMarketingTax + sellTeamTax;
        if (tokenAmount == 0 || totalTax == 0) return;

        uint256 halfLP = (tokenAmount * lpBPS / totalTax) / 2;
        uint256 preBNB = address(this).balance;
        _swapTokensForBNB(tokenAmount - halfLP);
        uint256 gotBNB = address(this).balance - preBNB;

        uint256 denom = totalTax - lpBPS / 2;
        if (denom == 0) return;

        uint256 bnbLP        = (gotBNB * (lpBPS / 2))                          / denom;
        uint256 bnbMarketing = (gotBNB * (buyMarketingTax + sellMarketingTax)) / denom;

        if (halfLP > 0 && bnbLP > 0) {
            _addLiquidity(halfLP, bnbLP);
            emit SwapAndLiquify(halfLP, bnbLP);
        }
        _safeSendBNB(marketingWallet, bnbMarketing);
        _safeSendBNB(teamWallet,      gotBNB - bnbLP - bnbMarketing);
    }

    function _swapTokensForBNB(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeRouter.WETH();
        _approve(address(this), address(pancakeRouter), tokenAmount);
        // amountOutMin = 0: no on-chain oracle is available at swap time.
        // Sandwich risk is accepted; owner may call manualSwap() when conditions are favourable.
        pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
    }

    /// @dev Swaps this-token → WBNB → reflectionToken (single-hop if reflectionToken == WBNB).
    function _swapForReflectionToken(uint256 tokenAmount) private {
        address weth = pancakeRouter.WETH();
        address[] memory path;
        if (reflectionToken == weth) {
            path = new address[](2);
            path[0] = address(this);
            path[1] = weth;
        } else {
            path = new address[](3);
            path[0] = address(this);
            path[1] = weth;
            path[2] = reflectionToken;
        }
        _approve(address(this), address(pancakeRouter), tokenAmount);
        // amountOutMin = 0: no oracle available; sandwich risk is accepted (same as _swapTokensForBNB).
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
    }

    /// @dev Add/remove addr from holder list based on balance.
    ///      Addresses excluded from reflection are never tracked.
    ///      List is capped at MAX_REFLECTION_HOLDERS to prevent OOG in _distributeReflection.
    function _updateHolderList(address addr) private {
        if (addr == address(0) || _isExcludedFromReflection[addr]) return;
        uint256 bal = balanceOf(addr);
        if (bal > 0) {
            if (_holderIndex[addr] == 0 && _holders.length < MAX_REFLECTION_HOLDERS) {
                _holders.push(addr);
                _holderIndex[addr] = _holders.length; // 1-based
            }
        } else {
            uint256 idx = _holderIndex[addr];
            if (idx != 0) {
                uint256 last = _holders.length - 1;
                address lastHolder = _holders[last];
                _holders[idx - 1] = lastHolder;
                _holderIndex[lastHolder] = idx;
                _holders.pop();
                _holderIndex[addr] = 0;
            }
        }
    }

    /// @dev Push `amount` of reflectionToken proportionally to qualifying holders.
    ///      Returns the number of recipients that received a share.
    function _distributeReflection(uint256 amount) private returns (uint256 recipients) {
        uint256 minBal = reflectionMinBalance;
        uint256 len    = _holders.length;
        if (len == 0) return 0;

        uint256 eligibleSupply;
        for (uint256 i; i < len; ) {
            uint256 bal = balanceOf(_holders[i]);
            if (bal >= minBal) eligibleSupply += bal;
            unchecked { ++i; }
        }
        if (eligibleSupply == 0) return 0;

        for (uint256 i; i < len; ) {
            address holder = _holders[i];
            uint256 bal = balanceOf(holder);
            if (bal >= minBal) {
                uint256 share = amount * bal / eligibleSupply;
                if (share > 0) {
                    bool ok = IERC20Minimal(reflectionToken).transfer(holder, share);
                    if (!ok) revert ReflectionTransferFailed();
                    unchecked { ++recipients; }
                }
            }
            unchecked { ++i; }
        }
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
    // EIP-2612 PERMIT
    // ─────────────────────────────────────────────────────────────────────

    /// @notice EIP-712 domain separator.  Recomputed on chain forks.
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

    /// @notice EIP-2612 permit — approve by signature, enabling approve + trade in one tx.
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
        // Also remove from _holders[] so it no longer receives custom reflection.
        uint256 idx = _holderIndex[account];
        if (idx != 0) {
            uint256 last = _holders.length - 1;
            address lastHolder = _holders[last];
            _holders[idx - 1]        = lastHolder;
            _holderIndex[lastHolder] = idx;
            _holders.pop();
            _holderIndex[account]    = 0;
        }
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
        // Re-add to holder list if the account has a balance, so it resumes receiving
        // custom reflection distributions without waiting for a transfer.
        if (balanceOf(account) > 0 && _holderIndex[account] == 0) {
            _holders.push(account);
            _holderIndex[account] = _holders.length; // 1-based
        }
        emit IncludedInReflection(account);
    }

    // ─────────────────────────────────────────────────────────────────────
    // OWNER ADMIN
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Set a custom token to receive reflection rewards.
     *         Pass address(0) to revert to native RFI mode.
     *         Any unswapped accumulation for the previous token is discarded.
     */
    function setReflectionToken(address token_) external onlyOwner {
        if (token_ == address(this)) revert CannotReflectSelf();
        _toSwapForReflection = 0;
        reflectionToken = token_;
        emit ReflectionTokenSet(token_);
    }

    /**
     * @notice Set the minimum token balance a holder must have to receive
     *         custom reflection distributions.
     *         Cannot be set below 0.02 % of total supply (dust protection) and
     *         cannot be decreased from the current value — only increases are allowed.
     */
    function setReflectionMinBalance(uint256 minBalance_) external onlyOwner {
        uint256 floor = (_tTotal * MIN_REFLECTION_BPS) / BPS_DENOM;
        if (minBalance_ < floor) revert BelowMinReflectionThreshold();
        if (minBalance_ < reflectionMinBalance) revert BelowMinReflectionThreshold();
        reflectionMinBalance = minBalance_;
        emit ReflectionMinBalanceSet(minBalance_);
    }

    /// @notice Number of addresses currently tracked in the holder list.
    function holderCount() external view returns (uint256) { return _holders.length; }

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

    function setSwapThreshold(uint256 amount) external onlyOwner {
        if (amount < _tTotal * MIN_SWAP_THRESHOLD_BPS / BPS_DENOM) revert SwapThresholdTooLow();
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
        uint256 rawBalance = balanceOf(address(this));
        uint256 taxBalance = rawBalance > _vestingBalance
            ? rawBalance - _vestingBalance
            : 0;
        if (taxBalance == 0) revert ZeroAmount();
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
        uint256 bal = IERC20Minimal(tokenAddr).balanceOf(address(this));
        bool ok = IERC20Minimal(tokenAddr).transfer(to, bal);
        if (!ok) revert TokenRescueFailed();
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
     *         address(this) is excluded from both fees and reflection, so tokens
     *         are held in _tOwned and transferred cleanly to the owner on claim.
     */
    function setupVesting(address creator_, uint256 amount_) external override onlyFactory {
        if (vestingCreator != address(0)) revert VestingAlreadySet();
        if (creator_ == address(0))       revert ZeroAddress();
        if (amount_  == 0)                revert ZeroAmount();
        vestingCreator  = creator_;
        vestingTotal    = amount_;
        vestingStart    = block.timestamp;
        _vestingBalance = amount_;
        emit VestingSetup(creator_, amount_);
    }

    /**
     * @notice Claim linearly vested tokens.  Callable only by the current token owner.
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
        vestingClaimed  += claimable;
        _vestingBalance -= claimable;
        _transfer(address(this), _owner, claimable);
        emit VestingClaimed(_owner, claimable);
    }

    function claimableVesting() external view returns (uint256) {
        if (vestingTotal == 0) return 0;
        uint256 elapsed = block.timestamp - vestingStart;
        if (elapsed > VESTING_DURATION) elapsed = VESTING_DURATION;
        return (vestingTotal * elapsed / VESTING_DURATION) - vestingClaimed;
    }

    receive() external payable {}
}
