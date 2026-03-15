// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/ILaunchpadToken.sol";
import "./tokens/StandardToken.sol";
import "./tokens/TaxToken.sol";
import "./tokens/ReflectionToken.sol";

interface IPancakeRouter02 {
    function factory() external pure returns (address);
    function WETH()    external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

/// @dev Implemented by TaxToken and ReflectionToken — exits bonding phase after liquidity is seeded.
interface IPostMigrate {
    function postMigrateSetup() external;
}

/**
 * @title LaunchpadFactory — OneMEME
 * @notice Creates and manages meme-token launches via a virtual-liquidity
 *         bonding curve, migrates to PancakeSwap, and handles creator vesting.
 *
 * ─── Fees & parameters ────────────────────────────────────────────────────
 *   creationFee          Fixed creation fee in BNB wei.
 *   platformFee          BPS portion of each trade fee sent to feeRecipient.
 *   charityFee           BPS portion of each trade fee sent to charityWallet.
 *   Total trade fee      = platformFee + charityFee  (max 250 BPS = 2.5 %).
 *   defaultVirtualBNB    Virtual BNB seeded into the bonding curve at launch.
 *   defaultMigrationTarget  BNB that must be raised before DEX migration.
 *
 *   All values are stored and used in BNB wei.  They are locked into
 *   TokenConfig at creation time.  Subsequent owner/manager updates only
 *   affect future launches.
 *
 * ─── Supply options (18 decimals) ─────────────────────────────────────────
 *   ONE      =           1 × 10^18
 *   THOUSAND =       1,000 × 10^18
 *   MILLION  =   1,000,000 × 10^18
 *   BILLION  = 1,000,000,000 × 10^18
 *
 * ─── Token distribution ───────────────────────────────────────────────────
 *   38 %  liquidity  (added to DEX at migration, LP permanently locked)
 *    5 %  creator    (optional, 12-month linear vest inside token contract)
 *   57 %  bonding curve  (if creator allocation enabled)
 *   62 %  bonding curve  (if no creator allocation)
 *
 * ─── Bonding curve ────────────────────────────────────────────────────────
 *   Constant-product AMM with virtual BNB liquidity:
 *     k          = virtualBNB × bcTokensTotal   (invariant, set at launch)
 *     poolBNB    = virtualBNB + raisedBNB
 *     poolTokens = bcTokensTotal − bcTokensSold
 *
 *   The crossing buy that reaches migrationTarget sells ALL remaining BC
 *   tokens and refunds any excess BNB, guaranteeing full curve exhaustion.
 *
 * ─── Decaying antibot ─────────────────────────────────────────────────────
 *   penaltyBPS = 10000 × (tradingBlock − block.number)
 *                       ÷ (tradingBlock − creationBlock)
 *   tokensToDeadWallet = tokensOut × penaltyBPS / 10000
 *   Applies to ALL buyers within the antibot window.  The only exempt buy
 *   is the atomic early buy embedded in createToken/createTT/createRFL
 *   (skipAntibot = true).
 *
 * ─── Creator vesting ──────────────────────────────────────────────────────
 *   Linear over 12 months from launch timestamp.
 *   The token contract acts as its own vesting escrow.
 *   Claimable by the current token owner; transferable via ownership transfer.
 *   Tracked separately from accumulated taxes to prevent accidental swap.
 *
 * ─── Vanity addresses ─────────────────────────────────────────────────────
 *   Every clone is deployed via CREATE2 with a user-provided salt bound to
 *   msg.sender.  The resulting address must end in 0x1111.
 *   Mine off-chain: `predictTokenAddress(creator, salt, impl)` until match.
 */
contract LaunchpadFactory {

    // ─────────────────────────────────────────────────────────────────────
    // TYPES
    // ─────────────────────────────────────────────────────────────────────

    enum TokenType    { STANDARD, TAX, REFLECTION }
    enum SupplyOption { ONE, THOUSAND, MILLION, BILLION }

    struct Alloc {
        uint256 supply;
        uint256 liqTokens;
        uint256 creatorTokens;
        uint256 bcTokens;
    }

    struct TokenConfig {
        address   token;
        TokenType tokenType;
        address   creator;

        uint256 totalSupply;
        uint256 liquidityTokens;   // 38 %
        uint256 creatorTokens;     // 5 % or 0
        uint256 bcTokensTotal;
        uint256 bcTokensSold;

        // AMM state — all values in wei
        uint256 virtualBNB;
        uint256 k;                 // virtualBNB × bcTokensTotal (invariant)
        uint256 raisedBNB;
        uint256 migrationTarget;

        address pair;              // PancakeSwap pair — created at launch, liquidity added at migration

        bool    antibotEnabled;
        uint256 creationBlock;
        uint256 tradingBlock;      // creationBlock + antibotBlocks (10 – 199)

        bool migrated;
    }

    struct BaseParams {
        string       name;
        string       symbol;
        SupplyOption supplyOption;
        bool         enableCreatorAlloc;
        bool         enableAntibot;
        uint256      antibotBlocks;         // 10 – 199; ignored if antibot disabled
        /**
         * @notice Off-chain metadata URI (IPFS/HTTPS).
         *         JSON shape: { name, description, image, external_link }
         *         Updatable post-deployment via token.setMetaURI().
         */
        string       metaURI;
        /**
         * @notice Salt for CREATE2 vanity addressing.
         *         The on-chain salt is keccak256(abi.encode(msg.sender, salt)).
         *         Mine off-chain via predictTokenAddress() until address ends 0x1111.
         */
        bytes32      salt;
    }

    struct CreateTTParams {
        string       name;
        string       symbol;
        string       metaURI;
        SupplyOption supplyOption;
        bool         enableCreatorAlloc;
        bool         enableAntibot;
        uint256      antibotBlocks;
        bytes32      salt;
        // wallets/taxes/swapThreshold default to owner/0/0.1% — configurable post-deployment on the token.
    }

    struct CreateRFLParams {
        string       name;
        string       symbol;
        string       metaURI;
        SupplyOption supplyOption;
        bool         enableCreatorAlloc;
        bool         enableAntibot;
        uint256      antibotBlocks;
        bytes32      salt;
        // wallets/swapThreshold default to owner/0.1% — taxes configurable post-deployment on the token.
    }

    // ─────────────────────────────────────────────────────────────────────
    // STATE
    // ─────────────────────────────────────────────────────────────────────

    address public owner;

    address public immutable standardImpl;
    address public immutable taxImpl;
    address public immutable reflectionImpl;

    address public pancakeRouter;

    uint256 public creationFee;  // BNB wei
    uint256 public platformFee;  // bps — goes to feeRecipient
    uint256 public charityFee;   // bps — goes to charityWallet
    address public feeRecipient;
    address public charityWallet; // address(0) → charity portion redirected to feeRecipient

    uint256 public defaultVirtualBNB;      // BNB wei — bonding curve seed
    uint256 public defaultMigrationTarget; // BNB wei — raise target

    mapping(address => bool) public managers;

    mapping(address => TokenConfig) public tokens;
    address[] public allTokens;
    mapping(address => address[]) private _tokensByCreator;

    uint256 private constant LIQUIDITY_BPS      = 3800;
    uint256 private constant CREATOR_BPS        =  500;
    uint256 private constant BPS_DENOM          = 10000;
    uint256 private constant MAX_TOTAL_FEE      =  250; // 2.5 %

    /// @notice Suggested default creation fee: 0.0011 BNB.
    uint256 public  constant DEFAULT_CREATION_FEE = 0.0011 ether;
    address private constant DEAD               = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant ANTIBOT_MIN_BLOCKS =  10;
    uint256 private constant ANTIBOT_MAX_BLOCKS = 199;

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    // Running sum of all active tc.raisedBNB.  Used to isolate stray BNB for rescueBNB().
    uint256 private _totalRaisedBNB;

    address public pendingOwner;

    // ─────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotPendingOwner();
    error Unauthorized();
    error Reentrancy();
    error ZeroAddress();
    error ZeroAmount();
    error FeeExceedsMax();
    error InsufficientCreationFee(uint256 required, uint256 provided);
    error UnknownToken();
    error AlreadyMigrated();
    error ExceedsSoldSupply();
    error InsufficientPoolBNB();
    error SlippageTooLittleBNB();
    error SlippageTooFewTokens();
    error MigrationTargetNotReached();
    error CloneFailed();
    error VanityAddressRequired();
    error BNBTransferFailed();
    error RefundFailed();
    error AntibotBlocksOutOfRange();

    // ─────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────

    event TokenCreated(
        address indexed token,
        TokenType       tokenType,
        address indexed creator,
        uint256         totalSupply,
        bool            antibotEnabled,
        uint256         tradingBlock
    );
    event TokenBought(
        address indexed token,
        address indexed buyer,
        uint256 bnbIn,
        uint256 tokensOut,
        uint256 tokensToDead,
        uint256 raisedBNB
    );
    event TokenSold(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 bnbOut,
        uint256 raisedBNB
    );
    event TokenMigrated(
        address indexed token,
        address indexed pair,
        uint256 liquidityBNB,
        uint256 liquidityTokens
    );
    event DefaultParamsUpdated(uint256 virtualBNB, uint256 migrationTarget);
    event CreationFeeUpdated(uint256 fee);
    event RouterUpdated(address router);
    event FeeRecipientUpdated(address recipient);
    event CharityWalletUpdated(address wallet);
    event PlatformFeeUpdated(uint256 feeBps);
    event CharityFeeUpdated(uint256 feeBps);
    event ManagerAdded(address indexed manager);
    event ManagerRemoved(address indexed manager);
    event OwnershipTransferProposed(address indexed current, address indexed proposed);
    event OwnershipTransferred(address indexed prev, address indexed next);

    // ─────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyOwnerOrManager() {
        if (msg.sender != owner && !managers[msg.sender]) revert Unauthorized();
        _;
    }
    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ─────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @param router_               PancakeSwap V2 router
     * @param feeRecipient_         Address that receives platform fees
     * @param creationFee_          Token creation fee in BNB wei
     * @param platformFee_          Platform trade fee in bps
     * @param charityFee_           Charity trade fee in bps
     * @param defaultVirtualBNB_    Default virtual BNB seeded into bonding curve in BNB wei
     * @param defaultMigrationTarget_ Default BNB raise target before DEX migration in BNB wei
     */
    constructor(
        address router_,
        address feeRecipient_,
        uint256 creationFee_,
        uint256 platformFee_,
        uint256 charityFee_,
        uint256 defaultVirtualBNB_,
        uint256 defaultMigrationTarget_
    ) {
        if (router_       == address(0)) revert ZeroAddress();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (platformFee_ + charityFee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();
        if (defaultVirtualBNB_      == 0) revert ZeroAmount();
        if (defaultMigrationTarget_ == 0) revert ZeroAmount();

        owner                  = msg.sender;
        pancakeRouter          = router_;
        feeRecipient           = feeRecipient_;
        creationFee            = creationFee_;
        platformFee            = platformFee_;
        charityFee             = charityFee_;
        defaultVirtualBNB      = defaultVirtualBNB_;
        defaultMigrationTarget = defaultMigrationTarget_;
        _status                = _NOT_ENTERED;

        standardImpl   = address(new StandardToken());
        taxImpl        = address(new TaxToken());
        reflectionImpl = address(new ReflectionToken());
    }

    // ─────────────────────────────────────────────────────────────────────
    // TOKEN CREATION
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a Standard ERC-20 token.
     *         msg.value must cover the creation fee in BNB.
     *         Any excess BNB is used as an immediate antibot-exempt buy.
     */
    function createToken(BaseParams memory p) external payable nonReentrant returns (address token) {
        uint256 earlyBuy = _collectCreationFee();
        token = _cloneCreate2(standardImpl, p.salt);

        Alloc memory a = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);

        StandardToken(token).initForLaunchpad(p.name, p.symbol, a.supply, address(this), msg.sender, p.metaURI);
        _registerToken(token, TokenType.STANDARD, a, address(0), p.enableAntibot, p.antibotBlocks);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);

        emit TokenCreated(token, TokenType.STANDARD, msg.sender, a.supply,
            p.enableAntibot, tokens[token].tradingBlock);
    }

    /**
     * @notice Create a Tax Token.
     *         msg.value must cover the creation fee in BNB.
     *         Any excess BNB is used as an immediate antibot-exempt buy.
     */
    function createTT(CreateTTParams memory p) external payable nonReentrant returns (address payable token) {
        uint256 earlyBuy = _collectCreationFee();
        token = payable(_cloneCreate2(taxImpl, p.salt));

        Alloc memory a = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);

        TaxToken(token).initForLaunchpad(
            p.name, p.symbol, a.supply, address(this), msg.sender, p.metaURI, pancakeRouter
        );
        _registerToken(token, TokenType.TAX, a, TaxToken(token).pancakePair(), p.enableAntibot, p.antibotBlocks);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);

        emit TokenCreated(token, TokenType.TAX, msg.sender, a.supply,
            p.enableAntibot, tokens[token].tradingBlock);
    }

    /**
     * @notice Create a Reflection Token.
     *         msg.value must cover the creation fee in BNB.
     *         Any excess BNB is used as an immediate antibot-exempt buy.
     *         Taxes start at 0 % — the token owner must call setBuyTaxes /
     *         setSellTaxes post-deployment to enable reflection.
     */
    function createRFL(CreateRFLParams memory p) external payable nonReentrant returns (address payable token) {
        uint256 earlyBuy = _collectCreationFee();
        token = payable(_cloneCreate2(reflectionImpl, p.salt));

        Alloc memory a = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);

        ReflectionToken(token).initForLaunchpad(
            p.name, p.symbol, a.supply, address(this), msg.sender, p.metaURI, pancakeRouter
        );
        _registerToken(token, TokenType.REFLECTION, a, ReflectionToken(token).pancakePair(), p.enableAntibot, p.antibotBlocks);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);

        emit TokenCreated(token, TokenType.REFLECTION, msg.sender, a.supply,
            p.enableAntibot, tokens[token].tradingBlock);
    }

    // ─────────────────────────────────────────────────────────────────────
    // BONDING CURVE — BUY
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Buy tokens on the bonding curve.
     * @param token_  Token address (must not be migrated)
     * @param minOut  Minimum tokens to receive (slippage guard)
     */
    function buy(address token_, uint256 minOut) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        _executeBuy(token_, msg.sender, msg.value, minOut, false);
    }

    // ─────────────────────────────────────────────────────────────────────
    // BONDING CURVE — SELL
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Sell tokens back to the bonding curve for BNB.
     * @param token_    Token address
     * @param amountIn  Token amount to sell
     * @param minBNBOut Minimum BNB to receive (slippage guard)
     */
    function sell(address token_, uint256 amountIn, uint256 minBNBOut) external nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (amountIn == 0)          revert ZeroAmount();
        if (tc.bcTokensSold < amountIn) revert ExceedsSoldSupply();

        ILaunchpadToken(token_).transferFrom(msg.sender, address(this), amountIn);

        uint256 poolBNB       = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens    = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 newPoolTokens = poolTokens + amountIn;
        uint256 newPoolBNB    = tc.k / newPoolTokens;
        uint256 grossBNB      = poolBNB - newPoolBNB;
        if (grossBNB > tc.raisedBNB) revert InsufficientPoolBNB();

        uint256 totalFee = platformFee + charityFee;
        uint256 fee    = (grossBNB * totalFee) / BPS_DENOM;
        uint256 netBNB = grossBNB - fee;
        if (netBNB < minBNBOut) revert SlippageTooLittleBNB();

        tc.raisedBNB    -= grossBNB;
        _totalRaisedBNB -= grossBNB;
        tc.bcTokensSold -= amountIn;

        (bool ok,) = payable(msg.sender).call{value: netBNB}("");
        if (!ok) revert BNBTransferFailed();

        _dispatchFee(fee);
        emit TokenSold(token_, msg.sender, amountIn, netBNB, tc.raisedBNB);
    }

    // ─────────────────────────────────────────────────────────────────────
    // MIGRATION
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Migrate a completed bonding curve to PancakeSwap.
     *         Permissionless once raisedBNB ≥ migrationTarget.
     */
    function migrate(address token_) external nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0))            revert UnknownToken();
        if (tc.migrated)                       revert AlreadyMigrated();
        if (tc.raisedBNB < tc.migrationTarget) revert MigrationTargetNotReached();

        _doMigrate(tc, token_);
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Core buy logic — shared by createToken (early buy) and buy().
     *
     *      Migration-cap guarantee: if bnbIn is enough to reach or exceed the
     *      migration target, we cap the effective BNB to exactly what is needed,
     *      sell ALL remaining BC tokens to the buyer, and refund the rest.
     *      This ensures the bonding curve is fully exhausted at the target.
     *
     * @param skipAntibot  Only true for the atomic early buy inside createToken /
     *                     createTT / createRFL.  All subsequent buy() calls —
     *                     including those from the creator — receive the full
     *                     decaying penalty.
     */
    function _executeBuy(
        address token_,
        address buyer,
        uint256 bnbIn,
        uint256 minOut,
        bool    skipAntibot
    ) internal {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();

        uint256 poolBNB    = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;

        // grossNeeded = ceil(bnbNeeded / (1 - totalFee%))
        // After fee deduction, net BNB collected equals exactly migrationTarget.
        uint256 totalFee    = platformFee + charityFee;
        uint256 bnbNeeded   = tc.migrationTarget - tc.raisedBNB;
        uint256 grossNeeded = totalFee == 0
            ? bnbNeeded
            : (bnbNeeded * BPS_DENOM + (BPS_DENOM - totalFee) - 1) / (BPS_DENOM - totalFee);

        uint256 refund;
        uint256 fee;
        uint256 netBNB;
        uint256 tokensOut;

        if (bnbIn >= grossNeeded) {
            refund    = bnbIn - grossNeeded;
            fee       = (grossNeeded * totalFee) / BPS_DENOM;
            netBNB    = grossNeeded - fee;
            tokensOut = poolTokens;
        } else {
            fee       = (bnbIn * totalFee) / BPS_DENOM;
            netBNB    = bnbIn - fee;
            uint256 newPoolBNB = poolBNB + netBNB;
            tokensOut = poolTokens - (tc.k / newPoolBNB);
            if (tokensOut > poolTokens) tokensOut = poolTokens;
        }

        if (tokensOut == 0)     revert ZeroAmount();
        if (tokensOut < minOut) revert SlippageTooFewTokens();

        tc.raisedBNB    += netBNB;
        _totalRaisedBNB += netBNB;
        tc.bcTokensSold += tokensOut;

        _dispatchFee(fee);

        uint256 tokensToUser = tokensOut;
        uint256 tokensToDead = 0;

        if (!skipAntibot && tc.antibotEnabled && block.number < tc.tradingBlock) {
            uint256 blocksPassed = block.number - tc.creationBlock;
            uint256 totalBlocks  = tc.tradingBlock - tc.creationBlock;
            uint256 penaltyBPS   = BPS_DENOM - (blocksPassed * BPS_DENOM / totalBlocks);
            tokensToDead = (tokensOut * penaltyBPS) / BPS_DENOM;
            tokensToUser = tokensOut - tokensToDead;
        }

        if (tokensToDead > 0) ILaunchpadToken(token_).transfer(DEAD, tokensToDead);
        if (tokensToUser  > 0) ILaunchpadToken(token_).transfer(buyer, tokensToUser);

        if (refund > 0) {
            (bool ok,) = payable(buyer).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }

        emit TokenBought(token_, buyer, bnbIn - refund, tokensOut, tokensToDead, tc.raisedBNB);

        if (!tc.migrated && tc.raisedBNB >= tc.migrationTarget) {
            _doMigrate(tc, token_);
        }
    }

    /// @dev Shared migration logic — called from migrate() and _executeBuy().
    function _doMigrate(TokenConfig storage tc, address token_) internal {
        tc.migrated = true;

        uint256 migrationBNB = tc.raisedBNB;
        uint256 liqTokens    = tc.liquidityTokens;

        _totalRaisedBNB -= migrationBNB;

        address pair_ = tc.pair;

        ILaunchpadToken(token_).approve(pancakeRouter, liqTokens);

        // LP tokens sent to dead wallet — permanently locked.
        // Minimums at 99 % to protect against pre-created pair sandwich attacks.
        uint256 amountTokenMin = liqTokens    * 9900 / 10000;
        uint256 amountETHMin   = migrationBNB * 9900 / 10000;
        IPancakeRouter02(pancakeRouter).addLiquidityETH{value: migrationBNB}(
            token_, liqTokens, amountTokenMin, amountETHMin, DEAD, block.timestamp + 300
        );

        // StandardToken has no DEX-specific setup; only TAX and REFLECTION tokens need it.
        if (tc.tokenType != TokenType.STANDARD) {
            IPostMigrate(token_).postMigrateSetup();
        }

        // Safety net: burn any unsold BC tokens (should be zero via migration-cap,
        // but handles edge cases such as a direct migrate() call).
        uint256 unsold = tc.bcTokensTotal - tc.bcTokensSold;
        if (unsold > 0) ILaunchpadToken(token_).transfer(DEAD, unsold);

        tc.raisedBNB = 0;
        emit TokenMigrated(token_, pair_, migrationBNB, liqTokens);
    }

    /// @dev Deduct creation fee, dispatch it immediately, and return the excess as early buy.
    function _collectCreationFee() internal returns (uint256 earlyBuy) {
        if (msg.value < creationFee) revert InsufficientCreationFee(creationFee, msg.value);
        earlyBuy = msg.value - creationFee;
        _dispatchFee(creationFee);
    }

    function _computeAlloc(uint256 supply, bool hasCreator) internal pure returns (Alloc memory a) {
        a.supply        = supply;
        a.liqTokens     = (supply * LIQUIDITY_BPS) / BPS_DENOM;
        a.creatorTokens = hasCreator ? (supply * CREATOR_BPS) / BPS_DENOM : 0;
        a.bcTokens      = supply - a.liqTokens - a.creatorTokens;
    }

    function _supplyFromOption(SupplyOption opt) internal pure returns (uint256) {
        if (opt == SupplyOption.ONE)      return 1e18;
        if (opt == SupplyOption.THOUSAND) return 1_000e18;
        if (opt == SupplyOption.MILLION)  return 1_000_000e18;
        return 1_000_000_000e18;
    }

    /**
     * @dev Deploy an EIP-1167 minimal proxy via CREATE2.
     *      The actual salt is keccak256(abi.encode(msg.sender, userSalt)),
     *      binding it to the creator to prevent cross-sender front-running.
     *      The resulting address MUST end in 0x1111.
     */
    function _cloneCreate2(address implementation, bytes32 userSalt) internal returns (address instance) {
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

    /// @dev Register token config and set up creator vesting if applicable.
    function _registerToken(
        address      token_,
        TokenType    tokenType_,
        Alloc memory a,
        address      pair_,
        bool         enableAntibot_,
        uint256      antibotBlocks_
    ) internal {
        uint256 vBNB = defaultVirtualBNB;
        uint256 mTgt = defaultMigrationTarget;

        uint256 antibotBlocks = 0;
        if (enableAntibot_) {
            if (antibotBlocks_ < ANTIBOT_MIN_BLOCKS || antibotBlocks_ > ANTIBOT_MAX_BLOCKS)
                revert AntibotBlocksOutOfRange();
            antibotBlocks = antibotBlocks_;
        }

        TokenConfig storage tc = tokens[token_];
        tc.token            = token_;
        tc.tokenType        = tokenType_;
        tc.creator          = msg.sender;
        tc.totalSupply      = a.supply;
        tc.liquidityTokens  = a.liqTokens;
        tc.creatorTokens    = a.creatorTokens;
        tc.bcTokensTotal    = a.bcTokens;
        tc.bcTokensSold     = 0;
        tc.virtualBNB       = vBNB;
        tc.k                = vBNB * a.bcTokens;
        tc.raisedBNB        = 0;
        tc.migrationTarget  = mTgt;
        tc.antibotEnabled   = enableAntibot_;
        tc.creationBlock    = block.number;
        tc.tradingBlock     = block.number + antibotBlocks;
        tc.migrated         = false;

        allTokens.push(token_);
        _tokensByCreator[msg.sender].push(token_);

        tc.pair = pair_;

        if (a.creatorTokens > 0) {
            ILaunchpadToken(token_).transfer(token_, a.creatorTokens);
            ILaunchpadToken(token_).setupVesting(msg.sender, a.creatorTokens);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // OWNER ADMIN
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Update the default bonding curve parameters in BNB wei.
     *         Only affects tokens created after this call.
     */
    function setDefaultParams(uint256 virtualBNB_, uint256 migrationTarget_) external onlyOwnerOrManager {
        if (virtualBNB_      == 0) revert ZeroAmount();
        if (migrationTarget_ == 0) revert ZeroAmount();
        defaultVirtualBNB      = virtualBNB_;
        defaultMigrationTarget = migrationTarget_;
        emit DefaultParamsUpdated(virtualBNB_, migrationTarget_);
    }

    /// @notice Set the creation fee in BNB wei.  May be set to zero.
    function setCreationFee(uint256 fee_) external onlyOwnerOrManager {
        creationFee = fee_;
        emit CreationFeeUpdated(fee_);
    }

    /// @notice Set the platform fee in bps.  Combined charityFee + platformFee must not exceed 250 (2.5 %).
    function setPlatformFee(uint256 fee_) external onlyOwner {
        if (fee_ + charityFee > MAX_TOTAL_FEE) revert FeeExceedsMax();
        platformFee = fee_;
        emit PlatformFeeUpdated(fee_);
    }

    /// @notice Set the charity fee in bps.  Combined charityFee + platformFee must not exceed 250 (2.5 %).
    function setCharityFee(uint256 fee_) external onlyOwner {
        if (platformFee + fee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();
        charityFee = fee_;
        emit CharityFeeUpdated(fee_);
    }

    function setFeeRecipient(address rec_) external onlyOwner {
        if (rec_ == address(0)) revert ZeroAddress();
        feeRecipient = rec_;
        emit FeeRecipientUpdated(rec_);
    }

    function setRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        // Validate the router exposes the expected PancakeSwap V2 interface.
        IPancakeRouter02(router_).factory();
        IPancakeRouter02(router_).WETH();
        pancakeRouter = router_;
        emit RouterUpdated(router_);
    }

    /// @notice Propose a new owner.  The candidate must call acceptOwnership() to confirm.
    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert ZeroAddress();
        pendingOwner = newOwner_;
        emit OwnershipTransferProposed(owner, newOwner_);
    }

    /// @notice Accept a pending ownership transfer.  Must be called by pendingOwner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner        = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Add an address as a manager.  Managers may update creationFee and default params.
    function addManager(address manager_) external onlyOwner {
        if (manager_ == address(0)) revert ZeroAddress();
        managers[manager_] = true;
        emit ManagerAdded(manager_);
    }

    /// @notice Remove a manager.
    function removeManager(address manager_) external onlyOwner {
        managers[manager_] = false;
        emit ManagerRemoved(manager_);
    }

    /**
     * @notice Set the charity wallet address.
     *         The `charityFee` bps portion of each fee is routed here.
     *         Set to address(0) to redirect the charity portion to feeRecipient.
     */
    function setCharityWallet(address wallet_) external onlyOwner {
        charityWallet = wallet_;
        emit CharityWalletUpdated(wallet_);
    }

    /// @notice Sweep any BNB not accounted for by active bonding-curve pools to feeRecipient.
    function rescueBNB() external onlyOwner {
        if (address(this).balance <= _totalRaisedBNB) revert ZeroAmount();
        uint256 stray = address(this).balance - _totalRaisedBNB;
        _safeSendBNB(feeRecipient, stray);
    }

    // ─────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Tokens received for a given BNB input (after trade fee).
     *         Accounts for the migration cap — if bnbIn crosses the target,
     *         the full remaining pool is returned.
     * @return tokensOut  Token amount the buyer would receive
     * @return feeBNB     Platform fee deducted from bnbIn
     */
    function getAmountOut(address token_, uint256 bnbIn)
        external view
        returns (uint256 tokensOut, uint256 feeBNB)
    {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0) || tc.migrated) return (0, 0);

        uint256 poolBNB    = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 totalFee   = platformFee + charityFee;
        uint256 bnbNeeded  = tc.migrationTarget - tc.raisedBNB;
        uint256 grossNeeded = totalFee == 0
            ? bnbNeeded
            : (bnbNeeded * BPS_DENOM + (BPS_DENOM - totalFee) - 1) / (BPS_DENOM - totalFee);

        if (bnbIn >= grossNeeded) {
            feeBNB    = (grossNeeded * totalFee) / BPS_DENOM;
            tokensOut = poolTokens;
        } else {
            feeBNB    = (bnbIn * totalFee) / BPS_DENOM;
            uint256 netBNB = bnbIn - feeBNB;
            tokensOut = poolTokens - (tc.k / (poolBNB + netBNB));
            if (tokensOut > poolTokens) tokensOut = poolTokens;
        }
    }

    /**
     * @notice BNB received for selling a given token amount (after trade fee).
     * @return bnbOut   BNB the seller would receive
     * @return feeBNB   Platform fee deducted from gross BNB
     */
    function getAmountOutSell(address token_, uint256 tokensIn)
        external view
        returns (uint256 bnbOut, uint256 feeBNB)
    {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0) || tc.migrated || tc.bcTokensSold < tokensIn) return (0, 0);
        uint256 poolBNB     = tc.virtualBNB + tc.raisedBNB;
        uint256 poolToks    = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 newPoolToks = poolToks + tokensIn;
        uint256 grossBNB    = poolBNB - (tc.k / newPoolToks);
        if (grossBNB > tc.raisedBNB) return (0, 0);
        feeBNB = (grossBNB * (platformFee + charityFee)) / BPS_DENOM;
        bnbOut = grossBNB - feeBNB;
    }

    /**
     * @notice Spot price on the bonding curve: BNB per whole token (×1e18).
     */
    function getSpotPrice(address token_) external view returns (uint256 price) {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        uint256 poolBNB    = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        if (poolTokens == 0) return type(uint256).max;
        price = (poolBNB * 1e18) / poolTokens;
    }

    /**
     * @notice Predict the CREATE2 address for a given creator, salt, and implementation.
     *         Use off-chain to mine a salt whose resulting address ends in 0x1111.
     *
     * @param creator_   Address that will call the create function
     * @param userSalt_  Salt value passed in BaseParams.salt
     * @param impl_      Implementation: standardImpl / taxImpl / reflectionImpl
     */
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

    // ─────────────────────────────────────────────────────────────────────
    // FEE DISPATCH
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Route `amount` to charityWallet and feeRecipient in proportion to their
     *      respective fee settings.  If charityWallet is unset or charityFee is 0,
     *      the full amount goes to feeRecipient.
     *      Fees are sent immediately — nothing is held in the factory.
     */
    function _dispatchFee(uint256 amount) private {
        if (amount == 0) return;
        uint256 cFee    = charityFee;
        uint256 total   = cFee + platformFee;
        address charity = charityWallet;
        if (charity != address(0) && cFee > 0 && total > 0) {
            uint256 charityAmt = amount * cFee / total;
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

    // ─────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────

    function totalTokensLaunched() external view returns (uint256) { return allTokens.length; }

    function getTokensByCreator(address creator_) external view returns (address[] memory) {
        return _tokensByCreator[creator_];
    }

    function tokenCountByCreator(address creator_) external view returns (uint256) {
        return _tokensByCreator[creator_].length;
    }

    receive() external payable {}
}
