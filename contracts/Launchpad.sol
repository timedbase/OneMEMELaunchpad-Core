// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/ILaunchpadToken.sol";
import "./interfaces/IPancakeRouter02.sol";

interface IWETH9LP {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV3FactoryLP {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3PoolLP {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16  observationCardinality, uint16 observationCardinalityNext,
        uint32  feeProtocol, bool unlocked // PancakeSwap V3 packs this wider than vanilla Uniswap V3's uint8
    );
}

interface INonfungiblePositionManagerLP {
    struct MintParams {
        address token0;
        address token1;
        uint24  fee;
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params)
        external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface ICreatorVaultLP {
    function registerPosition(
        address token, uint256 tokenId, address feeWallet,
        address token0, address token1, address pool, address positionManager
    ) external;
    function addVesting(address token, address beneficiary, uint256 amount, uint256 duration) external;
}

interface IPancakePairMin {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IStdInit {
    function initForLaunchpad(
        string memory name_, string memory symbol_, uint256 totalSupply_,
        address launchManager_, address tokenOwner_, string memory metaURI_,
        address creatorVault_
    ) external;
}

interface ITaxRflInit {
    function initForLaunchpad(
        string memory name_, string memory symbol_, uint256 totalSupply_,
        address launchManager_, address tokenOwner_, string memory metaURI_,
        address router_, address creatorVault_
    ) external;
    function pancakePair() external view returns (address);
}

// Self-interface used by _finalizeBuy to wrap _doMigrate in a try/catch.
// try/catch only works on external calls; this exposes _doMigrate as one.
interface ILaunchpadSelf {
    function _tryMigrateExternal(address token_) external;
}

/// @notice Single-contract launchpad: token creation (CREATE2 cloning), USD-denominated
///         bonding-curve sizing via a live USDC/WBNB spot price, all per-token AMM state
///         and buy/sell/migrate execution, and DEX migration (V2-and-burn for
///         TaxToken/ReflectionToken, V3-and-lock-in-CreatorVault for StandardToken).
///         Replaces the former BondingCurve + LaunchpadFactory split — there is no
///         cross-contract trust boundary left, so a single owner/timelock governs
///         everything. Not upgradeable by design: a normal immutable contract.
contract Launchpad {

    struct TokenConfig {
        address   token;
        address   creator;

        uint256 totalSupply;
        uint256 liquidityTokens;
        uint256 creatorTokens;
        uint256 bcTokensTotal;
        uint256 bcTokensSold;

        uint256 virtualBNB;
        uint256 k;
        uint256 raisedBNB;
        uint256 migrationTarget;

        address pair;   // V2 pair, or the V3 pool once migrated when useV3 is set
        address router;

        bool    antibotEnabled;
        uint256 creationBlock;
        uint256 tradingBlock;

        bool migrated;
        bool migrationPending; // set when migration-cap buy commits but auto-migration reverts
        bool useV3; // StandardToken migrates to a V3 1% pool, locked in creatorVault;
                    // TaxToken/ReflectionToken keep the existing V2-and-burn path.
    }

    struct Alloc {
        uint256 supply;
        uint256 liqTokens;
        uint256 creatorTokens;
        uint256 bcTokens;
    }

    struct BaseParams {
        string       name;
        string       symbol;
        uint256      totalSupply;           // 18-decimal token amount; bounded by minSupply/maxSupply
        uint256      curveBps;
        uint256      liquidityBps;
        uint256      creatorBps;
        uint256      startMarketCapUSD;     // 18-decimal USD, e.g. 5000e18 = $5,000
        uint256      migrationMarketCapUSD; // 18-decimal USD
        bool         enableAntibot;
        uint256      antibotBlocks;
        uint256      vestingDuration; // seconds; 0 means no creator allocation; minimum 45 days if creatorBps > 0
        string       metaURI;
        bytes32      salt;
    }

    struct CreateTTParams {
        string       name;
        string       symbol;
        string       metaURI;
        uint256      totalSupply;
        uint256      curveBps;
        uint256      liquidityBps;
        uint256      creatorBps;
        uint256      startMarketCapUSD;
        uint256      migrationMarketCapUSD;
        bool         enableAntibot;
        uint256      antibotBlocks;
        uint256      vestingDuration;
        bytes32      salt;
    }

    struct CreateRFLParams {
        string       name;
        string       symbol;
        string       metaURI;
        uint256      totalSupply;
        uint256      curveBps;
        uint256      liquidityBps;
        uint256      creatorBps;
        uint256      startMarketCapUSD;
        uint256      migrationMarketCapUSD;
        bool         enableAntibot;
        uint256      antibotBlocks;
        uint256      vestingDuration;
        bytes32      salt;
    }

    struct BuyResult {
        uint256 refund;
        uint256 fee;
        uint256 tokensOut;
        uint256 netBNBIn;
    }

    uint256 private constant BPS_DENOM          = 10_000;
    uint256 private constant MAX_TOTAL_FEE      =    250; // 2.5 %
    uint256 private constant ANTIBOT_MIN_BLOCKS =     10;
    uint256 private constant ANTIBOT_MAX_BLOCKS =    199;
    address private constant DEAD               = 0x000000000000000000000000000000000000dEaD;

    uint24 private constant V3_FEE_TIER = 10_000;  // 1 % tier; tick spacing 200 on this tier
    int24  private constant V3_MIN_TICK = -887_200; // full-range, aligned to the 1 % tier's spacing
    int24  private constant V3_MAX_TICK =  887_200;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    bytes32 public constant TL_SET_ROUTER             = keccak256("SET_ROUTER");
    bytes32 public constant TL_SET_PLATFORM_FEE       = keccak256("SET_PLATFORM_FEE");
    bytes32 public constant TL_SET_CHARITY_FEE        = keccak256("SET_CHARITY_FEE");
    bytes32 public constant TL_SET_FEE_RECIPIENT      = keccak256("SET_FEE_RECIPIENT");
    bytes32 public constant TL_SET_CHARITY_WALLET     = keccak256("SET_CHARITY_WALLET");
    bytes32 public constant TL_SET_V3_POSITION_MANAGER = keccak256("SET_V3_POSITION_MANAGER");
    bytes32 public constant TL_SET_V3_FACTORY          = keccak256("SET_V3_FACTORY");
    bytes32 public constant TL_SET_USD_QUOTE_PAIR      = keccak256("SET_USD_QUOTE_PAIR");

    // ── Admin ─────────────────────────────────────────────────────────────────────
    address public owner;
    address public pendingOwner;

    address public standardImpl;
    address public taxImpl;
    address public reflectionImpl;
    address public creatorVault;

    // ── DEX config ────────────────────────────────────────────────────────────────
    address public pancakeRouter;
    address public v3PositionManager;
    address public v3Factory;

    // ── USD oracle config ─────────────────────────────────────────────────────────
    address public usdcToken;
    address public usdQuotePair; // must contain usdcToken + WBNB; validated on set

    // ── Allocation guardrails (creator picks curve/liquidity/creator bps per launch) ──
    uint256 public minCurveBps     = 3000; // 30 % minimum on the bonding curve
    uint256 public minLiquidityBps = 1000; // 10 % minimum DEX liquidity at migration
    uint256 public maxCreatorBps   = 2000; // 20 % maximum creator vesting allocation

    // ── Supply guardrails (creator picks an arbitrary totalSupply per launch) ───────
    uint256 public minSupply = 1e18;                   // 1 token minimum
    uint256 public maxSupply = 999_000_000_000_000e18; // 999 trillion tokens maximum

    // ── Fees ──────────────────────────────────────────────────────────────────────
    uint256 public platformFee;
    uint256 public charityFee;
    address public feeRecipient;
    address public charityWallet; // address(0) → charity portion redirected to feeRecipient
    uint256 public creationFee;

    // ── Token registry ────────────────────────────────────────────────────────────
    // The auto-generated public getter for this many fields exceeds the EVM's 16-slot
    // stack limit without viaIR. Use getToken() instead.
    mapping(address => TokenConfig) internal tokens;
    address[] public allTokens;
    mapping(address => address[]) private _tokensByCreator;

    uint256 private _totalRaisedBNB; // sum of all active raisedBNB pools; used by rescueBNB
    uint256 private _status;

    mapping(bytes32 => uint256) public timelockExpiry;

    address private _pendingRouter;
    uint256 private _pendingPlatformFee;
    uint256 private _pendingCharityFee;
    address private _pendingFeeRecipient;
    address private _pendingCharityWallet;
    address private _pendingV3PositionManager;
    address private _pendingV3Factory;
    address private _pendingUsdQuotePair;

    error NotOwner();
    error NotPendingOwner();
    error Reentrancy();
    error ZeroAddress();
    error ZeroAmount();
    error FeeExceedsMax();
    error InsufficientCreationFee(uint256 required, uint256 provided);
    error CloneFailed();
    error VanityAddressRequired();
    error BNBTransferFailed();
    error RefundFailed();
    error DeadlineExpired();
    error TimelockNotQueued();
    error TimelockNotExpired();
    error TransferFailed();
    error UnknownToken();
    error AlreadyMigrated();
    error ExceedsSoldSupply();
    error LiquidityReserveViolation();
    error InsufficientPoolBNB();
    error SlippageTooLittleBNB();
    error SlippageTooFewTokens();
    error MigrationTargetNotReached();
    error ActivePool();
    error AntibotBlocksOutOfRange();
    error PoolAlreadyExists();
    error CreatorVaultNotSet();
    error InvalidAllocation();
    error InvalidMarketCaps();
    error InvalidUsdQuotePair();
    error InvalidSupply();
    error MigrationPending();
    error InsufficientContractBalance();

    event TokenCreated(
        address indexed token,
        address indexed creator,
        uint256         totalSupply,
        uint256         virtualBNB,
        uint256         migrationTarget,
        bool            antibotEnabled,
        uint256         tradingBlock
    );
    event TokenRegistered(
        address indexed token,
        address indexed creator,
        uint256         totalSupply,
        uint256         virtualBNB,
        uint256         migrationTarget
    );
    event TokenBought(
        address indexed token, address indexed buyer,
        uint256 bnbIn, uint256 tokensOut, uint256 tokensToDead, uint256 raisedBNB
    );
    event TokenSold(
        address indexed token, address indexed seller,
        uint256 tokensIn, uint256 bnbOut, uint256 raisedBNB
    );
    event TokenMigrated(
        address indexed token, address indexed pair, uint256 liquidityBNB, uint256 liquidityTokens
    );
    event EmergencyMigrated(
        address indexed token, address indexed to, uint256 bnbAmount, uint256 tokenAmount
    );
    event MigrationFailed(address indexed token);
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event V3PositionManagerUpdated(address indexed oldPM, address indexed newPM);
    event V3FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event UsdQuotePairUpdated(address indexed oldPair, address indexed newPair);
    event AllocationBoundsUpdated(uint256 minCurveBps, uint256 minLiquidityBps, uint256 maxCreatorBps);
    event SupplyBoundsUpdated(uint256 minSupply, uint256 maxSupply);
    event FeesUpdated(uint256 platformFee, uint256 charityFee);
    event FeeRecipientUpdated(address recipient);
    event CharityWalletUpdated(address wallet);
    event CreatorVaultUpdated(address indexed prev, address indexed next);
    event OwnershipTransferProposed(address indexed current, address indexed proposed);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event TimelockQueued(bytes32 indexed actionId, uint256 executeAfter);
    event TimelockExecuted(bytes32 indexed actionId);
    event TimelockCancelled(bytes32 indexed actionId);
    event BNBRescued(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ImplUpdated(string implType, address indexed prev, address indexed next);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(
        address router_,
        address v3PositionManager_,
        address v3Factory_,
        address feeRecipient_,
        uint256 platformFee_,
        uint256 charityFee_,
        address standardImpl_,
        address taxImpl_,
        address reflectionImpl_,
        address creatorVault_,
        address usdcToken_,
        address usdQuotePair_,
        uint256 creationFee_
    ) {
        if (router_             == address(0)) revert ZeroAddress();
        if (v3PositionManager_  == address(0)) revert ZeroAddress();
        if (v3Factory_          == address(0)) revert ZeroAddress();
        if (feeRecipient_       == address(0)) revert ZeroAddress();
        if (platformFee_ + charityFee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();
        if (standardImpl_       == address(0)) revert ZeroAddress();
        if (taxImpl_            == address(0)) revert ZeroAddress();
        if (reflectionImpl_     == address(0)) revert ZeroAddress();
        if (creatorVault_       == address(0)) revert ZeroAddress();
        if (usdcToken_          == address(0)) revert ZeroAddress();

        owner             = msg.sender;
        pancakeRouter     = router_;
        v3PositionManager = v3PositionManager_;
        v3Factory         = v3Factory_;
        feeRecipient      = feeRecipient_;
        platformFee       = platformFee_;
        charityFee        = charityFee_;
        standardImpl      = standardImpl_;
        taxImpl           = taxImpl_;
        reflectionImpl    = reflectionImpl_;
        creatorVault      = creatorVault_;
        usdcToken         = usdcToken_;
        creationFee       = creationFee_;
        _status           = _NOT_ENTERED;

        _setUsdQuotePair(usdcToken_, usdQuotePair_);
    }

    // ── Token creation ────────────────────────────────────────────────────────────

    function createToken(BaseParams memory p) external payable nonReentrant returns (address token) {
        uint256 earlyBuy = _collectCreationFee();
        token = _cloneCreate2(standardImpl, p.salt);

        Alloc memory a = _computeAlloc(p.totalSupply, p.curveBps, p.liquidityBps, p.creatorBps);
        (uint256 vBNB, uint256 migTarget) = _computeBNBTargets(
            p.startMarketCapUSD, p.migrationMarketCapUSD, a.bcTokens, a.liqTokens, a.supply
        );

        IStdInit(token).initForLaunchpad(
            p.name, p.symbol, a.supply, address(this), msg.sender, p.metaURI, creatorVault
        );
        _distribute(token, a, p.vestingDuration);
        uint256 tradingBlock_ = _registerToken(
            token, msg.sender, a, vBNB, migTarget, address(0), true, p.enableAntibot, p.antibotBlocks
        );
        emit TokenCreated(token, msg.sender, a.supply, vBNB, migTarget, p.enableAntibot, tradingBlock_);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);
    }

    function createTT(CreateTTParams memory p) external payable nonReentrant returns (address payable token) {
        uint256 earlyBuy = _collectCreationFee();
        token = payable(_cloneCreate2(taxImpl, p.salt));

        Alloc memory a = _computeAlloc(p.totalSupply, p.curveBps, p.liquidityBps, p.creatorBps);
        (uint256 vBNB, uint256 migTarget) = _computeBNBTargets(
            p.startMarketCapUSD, p.migrationMarketCapUSD, a.bcTokens, a.liqTokens, a.supply
        );

        ITaxRflInit(token).initForLaunchpad(
            p.name, p.symbol, a.supply, address(this), msg.sender, p.metaURI,
            pancakeRouter, creatorVault
        );
        _distribute(token, a, p.vestingDuration);
        // TaxToken keeps the existing V2-and-burn migration path (useV3 = false).
        uint256 tradingBlock_ = _registerToken(
            token, msg.sender, a, vBNB, migTarget, ITaxRflInit(token).pancakePair(), false, p.enableAntibot, p.antibotBlocks
        );
        emit TokenCreated(token, msg.sender, a.supply, vBNB, migTarget, p.enableAntibot, tradingBlock_);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);
    }

    function createRFL(CreateRFLParams memory p) external payable nonReentrant returns (address payable token) {
        uint256 earlyBuy = _collectCreationFee();
        token = payable(_cloneCreate2(reflectionImpl, p.salt));

        Alloc memory a = _computeAlloc(p.totalSupply, p.curveBps, p.liquidityBps, p.creatorBps);
        (uint256 vBNB, uint256 migTarget) = _computeBNBTargets(
            p.startMarketCapUSD, p.migrationMarketCapUSD, a.bcTokens, a.liqTokens, a.supply
        );

        ITaxRflInit(token).initForLaunchpad(
            p.name, p.symbol, a.supply, address(this), msg.sender, p.metaURI,
            pancakeRouter, creatorVault
        );
        _distribute(token, a, p.vestingDuration);
        // ReflectionToken keeps the existing V2-and-burn migration path (useV3 = false).
        uint256 tradingBlock_ = _registerToken(
            token, msg.sender, a, vBNB, migTarget, ITaxRflInit(token).pancakePair(), false, p.enableAntibot, p.antibotBlocks
        );
        emit TokenCreated(token, msg.sender, a.supply, vBNB, migTarget, p.enableAntibot, tradingBlock_);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);
    }

    // ── Trading ───────────────────────────────────────────────────────────────────

    function buy(address token_, uint256 minOut, uint256 deadline) external payable nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (msg.value == 0) revert ZeroAmount();
        _executeBuy(token_, msg.sender, msg.value, minOut, false);
    }

    function sell(address token_, uint256 amountIn, uint256 minBNBOut, uint256 deadline)
        external nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();
        ILaunchpadToken(token_).transferFrom(msg.sender, address(this), amountIn);
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0))   revert UnknownToken();
        if (tc.migrated)              revert AlreadyMigrated();
        if (tc.migrationPending)      revert MigrationPending();
        // Only tokens previously bought can be sold back; liquidityTokens are never
        // part of the BC pool and are always reserved for migration.
        if (amountIn > tc.bcTokensSold) revert ExceedsSoldSupply();
        (uint256 fee, uint256 netBNB) = _computeSell(tc, amountIn, minBNBOut);
        uint256 raisedAfter = tc.raisedBNB;
        (bool ok,) = payable(msg.sender).call{value: netBNB}("");
        if (!ok) revert BNBTransferFailed();
        _dispatchFee(fee);
        emit TokenSold(token_, msg.sender, amountIn, netBNB, raisedAfter);
    }

    function migrate(address token_) external nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (!tc.migrationPending)   revert MigrationTargetNotReached();
        _doMigrate(tc, token_);
    }

    // Entry point for the try/catch in _finalizeBuy. Not guarded by nonReentrant so it
    // can be called while the outer buy() is holding _status = _ENTERED. Only callable
    // by address(this) — any reentrant call from a DEX callback into buy/sell/migrate
    // still hits the outer _ENTERED guard and reverts, keeping the guard effective.
    function _tryMigrateExternal(address token_) external {
        if (msg.sender != address(this)) revert NotOwner();
        TokenConfig storage tc = tokens[token_];
        _doMigrate(tc, token_);
    }

    // Used when a V3 pool has been pre-initialized by an attacker at the predicted token
    // address, causing _getOrCreateV3Pool to revert with PoolAlreadyExists(). The owner
    // receives the raised BNB and liquidity tokens to provision DEX liquidity manually,
    // while all other migration accounting (totalRaisedBNB, postMigrateSetup, unsold burn)
    // runs identically to the normal path so the token's state is fully closed out.
    function emergencyMigrate(address token_) external onlyOwner nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (!tc.migrationPending)   revert MigrationTargetNotReached();

        tc.migrated         = true;
        tc.migrationPending = false;

        uint256 migrationBNB = tc.raisedBNB;
        uint256 liqTokens    = tc.liquidityTokens;
        address to           = owner;

        // Mirror the _computeSell InsufficientPoolBNB guard: never send more than the
        // contract actually holds, even if accounting somehow drifts.
        if (migrationBNB > address(this).balance)
            revert InsufficientContractBalance();

        if (migrationBNB >= _totalRaisedBNB) _totalRaisedBNB = 0;
        else                                 _totalRaisedBNB -= migrationBNB;
        tc.raisedBNB = 0;

        ILaunchpadToken(token_).postMigrateSetup();

        if (liqTokens > 0) {
            if (!IERC20Min(token_).transfer(to, liqTokens)) revert TransferFailed();
        }
        _safeSendBNB(to, migrationBNB);

        emit EmergencyMigrated(token_, to, migrationBNB, liqTokens);
    }

    // ── Governance: instant ───────────────────────────────────────────────────────

    function setCreationFee(uint256 fee_) external onlyOwner {
        emit CreationFeeUpdated(creationFee, fee_);
        creationFee = fee_;
    }

    function setAllocationBounds(uint256 minCurveBps_, uint256 minLiquidityBps_, uint256 maxCreatorBps_) external onlyOwner {
        if (minCurveBps_ + minLiquidityBps_ > BPS_DENOM) revert InvalidAllocation();
        if (maxCreatorBps_ > BPS_DENOM) revert InvalidAllocation();
        minCurveBps     = minCurveBps_;
        minLiquidityBps = minLiquidityBps_;
        maxCreatorBps   = maxCreatorBps_;
        emit AllocationBoundsUpdated(minCurveBps_, minLiquidityBps_, maxCreatorBps_);
    }

    function setSupplyBounds(uint256 minSupply_, uint256 maxSupply_) external onlyOwner {
        if (minSupply_ == 0 || minSupply_ > maxSupply_) revert InvalidSupply();
        minSupply = minSupply_;
        maxSupply = maxSupply_;
        emit SupplyBoundsUpdated(minSupply_, maxSupply_);
    }

    function setStandardImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        emit ImplUpdated("standard", standardImpl, impl_);
        standardImpl = impl_;
    }

    function setTaxImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        emit ImplUpdated("tax", taxImpl, impl_);
        taxImpl = impl_;
    }

    function setReflectionImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        emit ImplUpdated("reflection", reflectionImpl, impl_);
        reflectionImpl = impl_;
    }

    function setCreatorVault(address creatorVault_) external onlyOwner {
        if (creatorVault_ == address(0)) revert ZeroAddress();
        emit CreatorVaultUpdated(creatorVault, creatorVault_);
        creatorVault = creatorVault_;
    }

    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert ZeroAddress();
        pendingOwner = newOwner_;
        emit OwnershipTransferProposed(owner, newOwner_);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner        = msg.sender;
        pendingOwner = address(0);
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        if (timelockExpiry[actionId] == 0) revert TimelockNotQueued();
        timelockExpiry[actionId] = 0;
        emit TimelockCancelled(actionId);
    }

    // ── Governance: 48h timelock ──────────────────────────────────────────────────

    function proposeSetRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        address factory_ = IPancakeRouter02(router_).factory();
        address weth_    = IPancakeRouter02(router_).WETH();
        if (factory_ == address(0) || weth_ == address(0)) revert ZeroAddress();
        _pendingRouter = router_;
        _queueAction(TL_SET_ROUTER);
    }

    function executeSetRouter() external onlyOwner {
        _consumeAction(TL_SET_ROUTER);
        emit RouterUpdated(pancakeRouter, _pendingRouter);
        pancakeRouter = _pendingRouter;
    }

    function proposeSetV3PositionManager(address pm_) external onlyOwner {
        if (pm_ == address(0)) revert ZeroAddress();
        _pendingV3PositionManager = pm_;
        _queueAction(TL_SET_V3_POSITION_MANAGER);
    }

    function executeSetV3PositionManager() external onlyOwner {
        _consumeAction(TL_SET_V3_POSITION_MANAGER);
        emit V3PositionManagerUpdated(v3PositionManager, _pendingV3PositionManager);
        v3PositionManager = _pendingV3PositionManager;
    }

    function proposeSetV3Factory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        _pendingV3Factory = factory_;
        _queueAction(TL_SET_V3_FACTORY);
    }

    function executeSetV3Factory() external onlyOwner {
        _consumeAction(TL_SET_V3_FACTORY);
        emit V3FactoryUpdated(v3Factory, _pendingV3Factory);
        v3Factory = _pendingV3Factory;
    }

    function proposeSetUsdQuotePair(address pair_) external onlyOwner {
        if (pair_ == address(0)) revert ZeroAddress();
        _validateUsdQuotePair(usdcToken, pair_);
        _pendingUsdQuotePair = pair_;
        _queueAction(TL_SET_USD_QUOTE_PAIR);
    }

    function executeSetUsdQuotePair() external onlyOwner {
        _consumeAction(TL_SET_USD_QUOTE_PAIR);
        emit UsdQuotePairUpdated(usdQuotePair, _pendingUsdQuotePair);
        usdQuotePair = _pendingUsdQuotePair;
    }

    function proposeSetPlatformFee(uint256 fee_) external onlyOwner {
        if (fee_ + charityFee > MAX_TOTAL_FEE) revert FeeExceedsMax();
        _pendingPlatformFee = fee_;
        _queueAction(TL_SET_PLATFORM_FEE);
    }

    function executeSetPlatformFee() external onlyOwner {
        _consumeAction(TL_SET_PLATFORM_FEE);
        uint256 pf = _pendingPlatformFee;
        if (pf + charityFee > MAX_TOTAL_FEE) revert FeeExceedsMax();
        platformFee = pf;
        emit FeesUpdated(pf, charityFee);
    }

    function proposeSetCharityFee(uint256 fee_) external onlyOwner {
        if (platformFee + fee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();
        _pendingCharityFee = fee_;
        _queueAction(TL_SET_CHARITY_FEE);
    }

    function executeSetCharityFee() external onlyOwner {
        _consumeAction(TL_SET_CHARITY_FEE);
        uint256 cf = _pendingCharityFee;
        if (platformFee + cf > MAX_TOTAL_FEE) revert FeeExceedsMax();
        charityFee = cf;
        emit FeesUpdated(platformFee, cf);
    }

    function proposeSetFeeRecipient(address rec_) external onlyOwner {
        if (rec_ == address(0)) revert ZeroAddress();
        _pendingFeeRecipient = rec_;
        _queueAction(TL_SET_FEE_RECIPIENT);
    }

    function executeSetFeeRecipient() external onlyOwner {
        _consumeAction(TL_SET_FEE_RECIPIENT);
        feeRecipient = _pendingFeeRecipient;
        emit FeeRecipientUpdated(_pendingFeeRecipient);
    }

    // Propose address(0) to redirect the charity portion to feeRecipient.
    function proposeSetCharityWallet(address wallet_) external onlyOwner {
        _pendingCharityWallet = wallet_;
        _queueAction(TL_SET_CHARITY_WALLET);
    }

    function executeSetCharityWallet() external onlyOwner {
        _consumeAction(TL_SET_CHARITY_WALLET);
        charityWallet = _pendingCharityWallet;
        emit CharityWalletUpdated(_pendingCharityWallet);
    }

    // ── Rescue ────────────────────────────────────────────────────────────────────

    function rescueBNB(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (address(this).balance <= _totalRaisedBNB) revert ZeroAmount();
        uint256 amount = address(this).balance - _totalRaisedBNB;
        _safeSendBNB(to, amount);
        emit BNBRescued(to, amount);
    }

    function rescueToken(address token_, address to) external onlyOwner nonReentrant {
        if (token_ == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        TokenConfig storage tc = tokens[token_];
        if (tc.token != address(0) && !tc.migrated) revert ActivePool();
        uint256 bal = IERC20Min(token_).balanceOf(address(this));
        if (bal == 0) revert ZeroAmount();
        if (!IERC20Min(token_).transfer(to, bal)) revert TransferFailed();
        emit TokenRescued(token_, to, bal);
    }

    // ── Internal: creation / allocation / USD conversion ─────────────────────────

    function _registerToken(
        address token_,
        address creator_,
        Alloc memory a,
        uint256 virtualBNB_,
        uint256 migrationTarget_,
        address pair_,
        bool useV3_,
        bool enableAntibot_,
        uint256 antibotBlocks_
    ) private returns (uint256 tradingBlock_) {
        uint256 antibotBlocks = 0;
        if (enableAntibot_) {
            if (antibotBlocks_ < ANTIBOT_MIN_BLOCKS || antibotBlocks_ > ANTIBOT_MAX_BLOCKS)
                revert AntibotBlocksOutOfRange();
            antibotBlocks = antibotBlocks_;
        }

        TokenConfig storage tc = tokens[token_];
        tc.token           = token_;
        tc.creator         = creator_;
        tc.totalSupply     = a.supply;
        tc.liquidityTokens = a.liqTokens;
        tc.creatorTokens   = a.creatorTokens;
        tc.bcTokensTotal   = a.bcTokens;
        tc.bcTokensSold    = 0;
        tc.virtualBNB      = virtualBNB_;
        tc.k               = virtualBNB_ * a.bcTokens;
        tc.raisedBNB       = 0;
        tc.migrationTarget = migrationTarget_;
        tc.pair            = pair_;
        tc.router          = pancakeRouter; // snapshotted at registration; immune to future setRouter calls
        tc.antibotEnabled  = enableAntibot_;
        tc.creationBlock   = block.number;
        tc.tradingBlock    = block.number + antibotBlocks;
        tc.migrated        = false;
        tc.useV3           = useV3_;

        allTokens.push(token_);
        _tokensByCreator[creator_].push(token_);
        tradingBlock_ = tc.tradingBlock;

        emit TokenRegistered(token_, creator_, a.supply, virtualBNB_, migrationTarget_);
    }

    // The full supply is minted directly to address(this) (this contract is now both
    // the "factory" and the bonding-curve holder), so liqTokens+bcTokens need no
    // transfer at all -- only the optional creator allocation needs to move out, to
    // CreatorVault.
    function _distribute(address token, Alloc memory a, uint256 vestingDuration) private {
        if (a.creatorTokens > 0) {
            address cv = creatorVault;
            IERC20Min(token).transfer(cv, a.creatorTokens);
            ICreatorVaultLP(cv).addVesting(token, msg.sender, a.creatorTokens, vestingDuration);
        }
    }

    function _computeAlloc(
        uint256 supply, uint256 curveBps, uint256 liquidityBps, uint256 creatorBps
    ) private view returns (Alloc memory a) {
        if (supply < minSupply || supply > maxSupply) revert InvalidSupply();
        if (curveBps + liquidityBps + creatorBps != BPS_DENOM) revert InvalidAllocation();
        if (curveBps     < minCurveBps)     revert InvalidAllocation();
        if (liquidityBps < minLiquidityBps) revert InvalidAllocation();
        if (creatorBps   > maxCreatorBps)   revert InvalidAllocation();

        a.supply        = supply;
        a.liqTokens     = (supply * liquidityBps) / BPS_DENOM;
        a.creatorTokens = (supply * creatorBps)   / BPS_DENOM;
        a.bcTokens      = supply - a.liqTokens - a.creatorTokens;
    }

    // Converts creator-chosen $ market-cap targets into the BNB-denominated
    // virtualBNB/migrationTarget fields, using a live spot read of the USDC/WBNB pair.
    // See README "USD-Denominated Launches" for the derivation. Division precedes the
    // final multiply in both terms to keep intermediates within uint256 range without
    // needing a 512-bit mulDiv.
    function _computeBNBTargets(
        uint256 startMarketCapUSD,
        uint256 migrationMarketCapUSD,
        uint256 curveTokens,
        uint256 liqTokens,
        uint256 totalSupply
    ) private view returns (uint256 virtualBNB, uint256 migrationTarget) {
        if (startMarketCapUSD == 0 || migrationMarketCapUSD <= startMarketCapUSD) revert InvalidMarketCaps();
        (uint256 usdcReserve, uint256 wbnbReserve) = _wbnbUsdReserves();
        virtualBNB      = _usdToBNB(startMarketCapUSD,     curveTokens, totalSupply, usdcReserve, wbnbReserve);
        migrationTarget = _usdToBNB(migrationMarketCapUSD, liqTokens,   totalSupply, usdcReserve, wbnbReserve);
        if (virtualBNB == 0 || migrationTarget == 0) revert InvalidMarketCaps();
    }

    function _usdToBNB(
        uint256 marketCapUSD, uint256 tokenAmount, uint256 totalSupply,
        uint256 usdcReserve, uint256 wbnbReserve
    ) private pure returns (uint256) {
        return (marketCapUSD * wbnbReserve / totalSupply) * tokenAmount / usdcReserve;
    }

    function _wbnbUsdReserves() private view returns (uint256 usdcReserve, uint256 wbnbReserve) {
        (uint112 r0, uint112 r1,) = IPancakePairMin(usdQuotePair).getReserves();
        if (r0 == 0 || r1 == 0) revert InvalidUsdQuotePair();
        (usdcReserve, wbnbReserve) = IPancakePairMin(usdQuotePair).token0() == usdcToken
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
    }

    function _setUsdQuotePair(address usdc_, address pair_) private {
        _validateUsdQuotePair(usdc_, pair_);
        usdQuotePair = pair_;
    }

    function _validateUsdQuotePair(address usdc_, address pair_) private view {
        if (pair_ == address(0)) revert ZeroAddress();
        address t0 = IPancakePairMin(pair_).token0();
        // token1 isn't read directly -- WETH() on the configured router must equal the
        // pair's *other* token; cheaper and equally safe to just require token0 == usdc
        // and let getReserves() in _wbnbUsdReserves revert downstream if reserves are 0.
        address weth_ = IPancakeRouter02(pancakeRouter).WETH();
        if (t0 != usdc_ && weth_ != usdc_) revert InvalidUsdQuotePair();
    }

    function _collectCreationFee() private returns (uint256 earlyBuy) {
        uint256 cf = creationFee;
        if (msg.value < cf) revert InsufficientCreationFee(cf, msg.value);
        earlyBuy = msg.value - cf;
        if (cf > 0) _safeSendBNB(feeRecipient, cf);
    }

    // Salt is bound to msg.sender to prevent cross-sender front-running.
    // The resulting address must end in 0x1111 (vanity requirement).
    function _cloneCreate2(address implementation, bytes32 userSalt) private returns (address instance) {
        bytes32 salt = keccak256(abi.encode(msg.sender, userSalt));
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,         0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0))              revert CloneFailed();
        if (uint16(uint160(instance)) != 0x1111) revert VanityAddressRequired();
    }

    function _queueAction(bytes32 actionId) private {
        uint256 unlock = block.timestamp + TIMELOCK_DELAY;
        timelockExpiry[actionId] = unlock;
        emit TimelockQueued(actionId, unlock);
    }

    function _consumeAction(bytes32 actionId) private {
        uint256 expiry = timelockExpiry[actionId];
        if (expiry == 0) revert TimelockNotQueued();
        if (block.timestamp < expiry) revert TimelockNotExpired();
        timelockExpiry[actionId] = 0;
        emit TimelockExecuted(actionId);
    }

    // ── Internal: buy/sell/migrate (bonding-curve math, DEX-agnostic) ─────────────

    function _executeBuy(
        address token_, address buyer, uint256 bnbIn, uint256 minOut, bool skipAntibot
    ) private {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0))  revert UnknownToken();
        if (tc.migrated)             revert AlreadyMigrated();
        if (tc.migrationPending)     revert MigrationPending();
        BuyResult memory r = _calcBuy(tc, bnbIn, minOut);
        _dispatchFee(r.fee);
        _finalizeBuy(tc, token_, buyer, skipAntibot, r);
    }

    function _calcBuy(
        TokenConfig storage tc, uint256 bnbIn, uint256 minOut
    ) private returns (BuyResult memory r) {
        uint256 poolBNB    = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 totalFee   = platformFee + charityFee;
        // Ceiling division ensures net amount covers the migration target after fee deduction.
        uint256 grossNeeded = totalFee == 0
            ? tc.migrationTarget - tc.raisedBNB
            : ((tc.migrationTarget - tc.raisedBNB) * BPS_DENOM
                + (BPS_DENOM - totalFee) - 1)
              / (BPS_DENOM - totalFee);
        uint256 netBNB;

        if (bnbIn >= grossNeeded) {
            // Migration-cap: sell all remaining BC tokens and refund excess BNB.
            r.refund    = bnbIn - grossNeeded;
            r.fee       = (grossNeeded * totalFee) / BPS_DENOM;
            netBNB      = grossNeeded - r.fee;
            r.tokensOut = poolTokens;
            r.netBNBIn  = grossNeeded;
        } else {
            r.fee       = totalFee == 0
                ? 0
                : (bnbIn * totalFee + BPS_DENOM - 1) / BPS_DENOM;
            netBNB      = bnbIn - r.fee;
            r.tokensOut = poolTokens - ((tc.k + poolBNB + netBNB - 1) / (poolBNB + netBNB));
            r.netBNBIn  = bnbIn;
        }

        if (r.tokensOut == 0)         revert ZeroAmount();
        if (r.tokensOut < minOut)     revert SlippageTooFewTokens();
        if (r.tokensOut > poolTokens) revert LiquidityReserveViolation();

        tc.raisedBNB    += netBNB;
        _totalRaisedBNB += netBNB;
        tc.bcTokensSold += r.tokensOut;
    }

    function _finalizeBuy(
        TokenConfig storage tc, address token_, address buyer, bool skipAntibot, BuyResult memory r
    ) private {
        uint256 tokensToDead;
        {
            if (!skipAntibot && tc.antibotEnabled && block.number < tc.tradingBlock) {
                uint256 remaining   = tc.tradingBlock - block.number;
                uint256 totalBlocks = tc.tradingBlock - tc.creationBlock;
                // Ceiling keeps the penalty from rounding down at the boundary block.
                uint256 penaltyBPS  = (remaining * BPS_DENOM + totalBlocks - 1) / totalBlocks;
                if (penaltyBPS > BPS_DENOM) penaltyBPS = BPS_DENOM;
                tokensToDead = (r.tokensOut * penaltyBPS) / BPS_DENOM;
            }
        }

        if (tokensToDead > 0)               ILaunchpadToken(token_).transfer(DEAD, tokensToDead);
        if (r.tokensOut - tokensToDead > 0) ILaunchpadToken(token_).transfer(buyer, r.tokensOut - tokensToDead);

        if (r.refund > 0) {
            (bool ok,) = payable(buyer).call{value: r.refund}("");
            if (!ok) revert RefundFailed();
        }

        emit TokenBought(token_, buyer, r.netBNBIn, r.tokensOut, tokensToDead, tc.raisedBNB);

        if (!tc.migrated && tc.raisedBNB >= tc.migrationTarget) {
            // Try migration in the same tx. If _doMigrateV3 reverts (e.g. pool pre-initialized
            // by an attacker), the buy still commits and migrationPending is set so that
            // migrate() or emergencyMigrate() can be called in a separate tx.
            try ILaunchpadSelf(address(this))._tryMigrateExternal(token_) {
                // migrated successfully in same tx
            } catch {
                tc.migrationPending = true;
                emit MigrationFailed(token_);
            }
        }
    }

    function _doMigrate(TokenConfig storage tc, address token_) private {
        tc.migrated          = true;
        tc.migrationPending  = false;

        uint256 migrationBNB = tc.raisedBNB;
        uint256 liqTokens    = tc.liquidityTokens;

        // Safety nets: accounting invariants always hold, but verify before touching external funds.
        if (ILaunchpadToken(token_).balanceOf(address(this)) < liqTokens)
            revert LiquidityReserveViolation();
        if (migrationBNB > address(this).balance)
            revert InsufficientContractBalance();

        if (migrationBNB >= _totalRaisedBNB) _totalRaisedBNB = 0;
        else                                 _totalRaisedBNB -= migrationBNB;

        address pair_ = tc.useV3
            ? _doMigrateV3(tc, token_, migrationBNB, liqTokens)
            : _doMigrateV2(tc, token_, migrationBNB, liqTokens);

        ILaunchpadToken(token_).postMigrateSetup();
        tc.raisedBNB = 0;
        emit TokenMigrated(token_, pair_, migrationBNB, liqTokens);
    }

    // TaxToken / ReflectionToken path — unchanged. LP tokens sent to dead wallet,
    // permanently locked. 99 % minimums protect against pre-seeded pair sandwich attacks.
    function _doMigrateV2(
        TokenConfig storage tc, address token_, uint256 migrationBNB, uint256 liqTokens
    ) private returns (address pair_) {
        pair_ = tc.pair;
        address router_ = tc.router;
        ILaunchpadToken(token_).approve(router_, liqTokens);
        IPancakeRouter02(router_).addLiquidityETH{value: migrationBNB}(
            token_, liqTokens,
            liqTokens    * 9900 / 10000,
            migrationBNB * 9900 / 10000,
            DEAD, block.timestamp + 300
        );
    }

    // StandardToken path — migrates into a fresh PancakeSwap V3 1 % pool, full-range,
    // minted directly to creatorVault and locked there exactly like spark/SparkLocker.sol
    // locks Spark positions. The creator earns an ongoing share of the pool's own 1 %
    // trading fees instead of the LP being burned outright.
    function _doMigrateV3(
        TokenConfig storage tc, address token_, uint256 migrationBNB, uint256 liqTokens
    ) private returns (address pool) {
        address vault = creatorVault;
        if (vault == address(0)) revert CreatorVaultNotSet();

        address weth_ = IPancakeRouter02(tc.router).WETH();
        IWETH9LP(weth_).deposit{value: migrationBNB}();

        // V3 requires token0 < token1 by address.
        (address token0, address token1, uint256 amount0, uint256 amount1) = token_ < weth_
            ? (token_, weth_, liqTokens,    migrationBNB)
            : (weth_, token_, migrationBNB, liqTokens);

        pool = _getOrCreateV3Pool(token0, token1, amount0, amount1);

        uint256 tokenId = _mintV3Position(token0, token1, amount0, amount1, vault);
        ICreatorVaultLP(vault).registerPosition(
            token_, tokenId, tc.creator, token0, token1, pool, v3PositionManager
        );

        tc.pair = pool;
    }

    // A pool can already exist at this (token0, token1, V3_FEE_TIER) key if someone front-ran
    // createPool() with the token's predictable address — createPool() is permissionless on
    // the DEX factory. An uninitialized shell is harmless: we adopt and initialize it
    // ourselves. Only a pool someone has *already initialized* is a genuine collision, and
    // since StandardToken's bonding-phase transfer restriction blocks anyone from feeding it
    // real token liquidity beforehand, this can only ever be a (non-profitable) DoS attempt.
    function _getOrCreateV3Pool(
        address token0, address token1, uint256 amount0, uint256 amount1
    ) private returns (address pool) {
        address factory_ = v3Factory;
        pool = IUniswapV3FactoryLP(factory_).getPool(token0, token1, V3_FEE_TIER);
        if (pool == address(0)) {
            pool = IUniswapV3FactoryLP(factory_).createPool(token0, token1, V3_FEE_TIER);
        } else {
            (uint160 existingPrice,,,,,,) = IUniswapV3PoolLP(pool).slot0();
            if (existingPrice != 0) revert PoolAlreadyExists();
        }
        IUniswapV3PoolLP(pool).initialize(_sqrtPriceX96(amount0, amount1));
    }

    // Full-range mint — behaves like a V2 LP, absorbing nearly all of both amounts at the
    // ratio the pool was just initialized to. 99 % minimums mirror the V2 path's tolerance.
    function _mintV3Position(
        address token0, address token1, uint256 amount0, uint256 amount1, address vault
    ) private returns (uint256 tokenId) {
        address pm = v3PositionManager;
        _safeApprove(token0, pm, amount0);
        _safeApprove(token1, pm, amount1);
        (tokenId,,,) = INonfungiblePositionManagerLP(pm).mint(
            INonfungiblePositionManagerLP.MintParams({
                token0:         token0,
                token1:         token1,
                fee:            V3_FEE_TIER,
                tickLower:      V3_MIN_TICK,
                tickUpper:      V3_MAX_TICK,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min:     amount0 * 9900 / 10000,
                amount1Min:     amount1 * 9900 / 10000,
                recipient:      vault,
                deadline:       block.timestamp + 300
            })
        );
    }

    // sqrtPriceX96 = sqrt(amount1 / amount0) × 2^96, i.e. price = token1/token0.
    // Two-step to avoid 2^192 overflow:
    //   scaled = (amount1 << 96) / amount0   →  price × 2^96
    //   sqrt(scaled) << 48                   →  sqrt(price) × 2^96  ✓
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) private pure returns (uint160) {
        uint256 scaled = (amount1 << 96) / amount0;
        return uint160(_sqrt(scaled) << 48);
    }

    // Babylonian integer sqrt — returns floor(sqrt(x)).
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) >> 1;
        while (z < y) { y = z; z = (x / z + z) >> 1; }
    }

    // Reset allowance to 0 before setting — handles USDT's non-zero→non-zero restriction.
    function _safeApprove(address token_, address spender, uint256 amount) private {
        (bool reset,) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, 0));
        reset;
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _computeSell(
        TokenConfig storage tc, uint256 amountIn, uint256 minBNBOut
    ) private returns (uint256 fee, uint256 netBNB) {
        uint256 poolBNB     = tc.virtualBNB + tc.raisedBNB;
        uint256 newPoolToks = tc.bcTokensTotal - tc.bcTokensSold + amountIn;
        uint256 newPoolBNB  = (tc.k + newPoolToks - 1) / newPoolToks;
        uint256 grossBNB    = poolBNB > newPoolBNB ? poolBNB - newPoolBNB : 0;
        if (grossBNB > tc.raisedBNB) revert InsufficientPoolBNB();
        uint256 totalFee    = platformFee + charityFee;
        fee    = totalFee == 0 ? 0 : (grossBNB * totalFee + BPS_DENOM - 1) / BPS_DENOM;
        netBNB = grossBNB - fee;
        if (netBNB < minBNBOut) revert SlippageTooLittleBNB();
        tc.raisedBNB -= grossBNB;
        if (grossBNB >= _totalRaisedBNB) _totalRaisedBNB = 0;
        else                             _totalRaisedBNB -= grossBNB;
        tc.bcTokensSold -= amountIn;
    }

    function _dispatchFee(uint256 amount) private {
        if (amount == 0) return;
        uint256 cFee    = charityFee;
        uint256 total   = cFee + platformFee;
        address charity = charityWallet;
        if (charity != address(0) && cFee > 0 && total > 0) {
            uint256 charityAmt = (amount * cFee + total - 1) / total; // ceiling for exact charity share
            _safeSendBNB(charity,      charityAmt);
            _safeSendBNB(feeRecipient, amount - charityAmt);
        } else {
            _safeSendBNB(feeRecipient, amount);
        }
    }

    function _safeSendBNB(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert BNBTransferFailed();
    }

    // ── Views ─────────────────────────────────────────────────────────────────────

    function getAmountOut(address token_, uint256 bnbIn)
        external view
        returns (uint256 tokensOut, uint256 feeBNB)
    {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0) || tc.migrated) return (0, 0);

        uint256 poolBNB     = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens  = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 totalFee    = platformFee + charityFee;
        uint256 grossNeeded = totalFee == 0
            ? tc.migrationTarget - tc.raisedBNB
            : ((tc.migrationTarget - tc.raisedBNB) * BPS_DENOM + (BPS_DENOM - totalFee) - 1)
              / (BPS_DENOM - totalFee);

        if (bnbIn >= grossNeeded) {
            feeBNB    = (grossNeeded * totalFee) / BPS_DENOM;
            tokensOut = poolTokens;
        } else {
            feeBNB         = totalFee == 0 ? 0 : (bnbIn * totalFee + BPS_DENOM - 1) / BPS_DENOM;
            uint256 netBNB = bnbIn - feeBNB;
            tokensOut = poolTokens - ((tc.k + poolBNB + netBNB - 1) / (poolBNB + netBNB));
        }
    }

    function getAmountOutSell(address token_, uint256 tokensIn)
        external view
        returns (uint256 bnbOut, uint256 feeBNB)
    {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0) || tc.migrated || tc.bcTokensSold < tokensIn) return (0, 0);
        uint256 poolBNB     = tc.virtualBNB + tc.raisedBNB;
        uint256 poolToks    = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 newPoolToks = poolToks + tokensIn;
        uint256 newPoolBNB  = (tc.k + newPoolToks - 1) / newPoolToks;
        uint256 grossBNB    = poolBNB > newPoolBNB ? poolBNB - newPoolBNB : 0;
        if (grossBNB > tc.raisedBNB) return (0, 0);
        uint256 totalFee    = platformFee + charityFee;
        feeBNB = totalFee == 0 ? 0 : (grossBNB * totalFee + BPS_DENOM - 1) / BPS_DENOM;
        bnbOut = grossBNB - feeBNB;
    }

    function getSpotPrice(address token_) external view returns (uint256 price) {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        uint256 poolBNB    = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        if (poolTokens == 0) return type(uint256).max;
        price = (poolBNB * 1e18) / poolTokens;
    }

    // Off-chain quoting helper: what would virtualBNB/migrationTarget resolve to right
    // now for given $ targets and allocation, using the live USDC/WBNB spot price.
    function previewBNBTargets(
        uint256 startMarketCapUSD, uint256 migrationMarketCapUSD,
        uint256 supply, uint256 curveBps, uint256 liquidityBps, uint256 creatorBps
    ) external view returns (uint256 virtualBNB, uint256 migrationTarget) {
        Alloc memory a = _computeAlloc(supply, curveBps, liquidityBps, creatorBps);
        (virtualBNB, migrationTarget) = _computeBNBTargets(
            startMarketCapUSD, migrationMarketCapUSD, a.bcTokens, a.liqTokens, a.supply
        );
    }

    function getToken(address token_) external view returns (TokenConfig memory) {
        return tokens[token_];
    }

    function totalTokensLaunched() external view returns (uint256) { return allTokens.length; }

    function getTokensByCreator(address creator_) external view returns (address[] memory) {
        return _tokensByCreator[creator_];
    }

    function tokenCountByCreator(address creator_) external view returns (uint256) {
        return _tokensByCreator[creator_].length;
    }

    function getAntibotBlocksRange() external pure returns (uint256 min, uint256 max) {
        return (ANTIBOT_MIN_BLOCKS, ANTIBOT_MAX_BLOCKS);
    }

    function predictTokenAddress(address creator_, bytes32 userSalt_, address impl_)
        external view
        returns (address predicted)
    {
        bytes32 salt = keccak256(abi.encode(creator_, userSalt_));
        bytes32 initcodeHash;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,         0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl_))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            initcodeHash := keccak256(ptr, 0x37)
        }
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            initcodeHash
        )))));
    }

    receive() external payable {}
}
