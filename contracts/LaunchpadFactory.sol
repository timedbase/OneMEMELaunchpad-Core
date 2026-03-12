// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/ILaunchpadToken.sol";
import "./tokens/StandardToken.sol";
import "./tokens/TaxToken.sol";
import "./tokens/ReflectionToken.sol";

// ─── External interfaces ──────────────────────────────────────────────────────

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

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @dev Minimal PancakeSwap V2 pair surface needed for TWAP oracle.
interface IPancakeV2Pair {
    function token0()               external view returns (address);
    function token1()               external view returns (address);
    function getReserves()          external view returns (uint112 r0, uint112 r1, uint32 ts);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/**
 * @title LaunchpadFactory — OneMEME
 * @notice Creates and manages meme-token launches via a virtual-liquidity
 *         bonding curve, migrates to PancakeSwap, and handles creator vesting.
 *
 * ─── Price oracle ─────────────────────────────────────────────────────────
 *   Uses the PancakeSwap V2 USDC/WBNB pair as a TWAP oracle (30-min period).
 *   Staleness is measured in blocks (configurable, default 1 440 ≈ 2 h on BSC).
 *   All USD-denominated parameters ($1 creation fee, $2 000 virtual mcap,
 *   $11 000 migration target) are converted to BNB at oracle time.
 *
 * ─── Supply options (18 decimals) ─────────────────────────────────────────
 *   ONE      =           1 × 10^18
 *   THOUSAND =       1,000 × 10^18
 *   MILLION  =   1,000,000 × 10^18
 *   BILLION  = 1,000,000,000 × 10^18
 *
 * ─── Token distribution ───────────────────────────────────────────────────
 *   38 %  liquidity allocation  (added to DEX at migration, LP locked)
 *    5 %  creator allocation    (optional, vested 12 months linearly)
 *   57 %  bonding-curve supply  (if creator enabled)
 *   62 %  bonding-curve supply  (if no creator allocation)
 *
 * ─── Bonding curve ────────────────────────────────────────────────────────
 *   Constant-product AMM with virtual BNB liquidity:
 *     k          = virtualBNB × bcTokensTotal   (set once at launch)
 *     poolBNB    = virtualBNB + raisedBNB
 *     poolTokens = bcTokensTotal − bcTokensSold
 *
 *   The crossing buy that reaches migrationTarget sells ALL remaining BC
 *   tokens and refunds any excess BNB to the buyer, guaranteeing the curve
 *   is fully exhausted at exactly the migration threshold.
 *
 * ─── Decaying antibot ─────────────────────────────────────────────────────
 *   penaltyBPS = 10000 × (tradingBlock − block.number)
 *                       ÷ (tradingBlock − creationBlock)
 *   tokensToDeadWallet = tokensOut × penaltyBPS / 10000
 *   Applies to ALL buyers — including the creator — for any buy() call made
 *   within the antibot window.  The only exempt buy is the atomic early buy
 *   embedded in createToken / createTT / createRFL (skipAntibot = true).
 *
 * ─── Creator vesting ──────────────────────────────────────────────────────
 *   Linear over 12 months from token-creation timestamp.
 *   The token contract itself acts as the vesting escrow.
 *   Claimable by the current token owner (transferable with ownership).
 *
 * ─── Vanity addresses ─────────────────────────────────────────────────────
 *   Every token clone is deployed via CREATE2 with a user-provided salt,
 *   and the resulting address must end in 0x1111 (last 4 hex digits).
 *   Off-chain tool: mine `salt` such that predictTokenAddress(...) ends 1111.
 */
contract LaunchpadFactory {

    // ─────────────────────────────────────────────────────────────────────
    // TYPES
    // ─────────────────────────────────────────────────────────────────────

    enum TokenType    { STANDARD, TAX, REFLECTION }
    enum SupplyOption { ONE, THOUSAND, MILLION, BILLION }

    struct TokenConfig {
        address   token;
        TokenType tokenType;
        address   creator;

        // supply split
        uint256 totalSupply;
        uint256 liquidityTokens;   // 38 %
        uint256 creatorTokens;     // 5 % or 0
        uint256 bcTokensTotal;     // BC allocation
        uint256 bcTokensSold;

        // AMM state (all in BNB wei)
        uint256 virtualBNB;
        uint256 k;                 // virtualBNB × bcTokensTotal  (invariant)
        uint256 raisedBNB;
        uint256 migrationTarget;

        // antibot
        bool    antibotEnabled;
        uint256 creationBlock;
        uint256 tradingBlock;      // creationBlock + offset (10 – 199)

        bool migrated;
    }

    // ─── Params structs ───────────────────────────────────────────────────

    struct BaseParams {
        string       name;
        string       symbol;
        SupplyOption supplyOption;
        bool         enableCreatorAlloc;
        bool         enableAntibot;
        uint256      antibotBlocks;            // 10 – 199; ignored if antibot disabled
        uint256      customVirtualBNBUSD;      // 0 → use factory default ($2 000)
        uint256      customMigrationTargetUSD; // 0 → use factory default ($11 000)
        /**
         * @notice User-supplied salt component for CREATE2 vanity addressing.
         *         Mine off-chain via `predictTokenAddress` until the address
         *         ends in 0x1111.  The actual CREATE2 salt is derived as
         *         keccak256(abi.encode(msg.sender, salt)) to prevent front-running.
         */
        bytes32      salt;
    }

    struct CreateTTParams {
        BaseParams   base;
        address[3]   wallets;    // marketing, team, treasury
        uint256[5]   buyTaxes;   // marketing, team, treasury, burn, lp  (bps)
        uint256[5]   sellTaxes;
        uint256      swapThreshold;
    }

    struct CreateRFLParams {
        BaseParams   base;
        address[2]   wallets;    // marketing, team
        uint256[5]   buyTaxes;   // marketing, team, lp, burn, reflection (bps)
        uint256[5]   sellTaxes;
        uint256      swapThreshold;
    }

    // ─────────────────────────────────────────────────────────────────────
    // TWAP ORACLE STATE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The USDC token used in the oracle pair (for isToken0 derivation).
    address public usdcToken;

    /// @notice PancakeSwap V2 USDC/WBNB pair used as price oracle.
    address public usdcWbnbPair;

    /// @notice true if USDC is token0 in the pair, false if token1.
    bool public usdcIsToken0;

    /// @notice Decimals of the USDC token (6 for Circle USDC, 18 for Binance-peg).
    uint8 public usdcDecimals;

    /// @notice Stored cumulative price at last TWAP update.
    uint256 public priceCumulativeLast;

    /// @notice Pair block-timestamp at last TWAP update (truncated to uint32).
    uint32 public twapTimestampLast;

    /**
     * @notice TWAP price: WBNB wei per 1 USDC unit, stored as UQ112x112.
     *         Compute actual BNB: (twapPriceAvg × usdcUnits) >> 112
     *         Zero until updateTWAP() has been called successfully once.
     */
    uint256 public twapPriceAvg;

    /// @notice Minimum seconds between TWAP price updates (30 minutes).
    uint256 public constant TWAP_PERIOD = 30 minutes;

    /**
     * @notice Maximum number of blocks since the last successful TWAP
     *         computation before the price is considered stale.
     *         Default: 1 440 blocks ≈ 2 hours on BSC (5 s / block).
     *         Configurable by the factory owner via setTwapMaxAgeBlocks().
     */
    uint256 public twapMaxAgeBlocks;

    /**
     * @notice Block number of the last block where the TWAP price was
     *         successfully refreshed (i.e., the 30-min period had elapsed).
     *         Used for block-based staleness check in usdToBNB().
     */
    uint256 public twapLastSuccessBlock;

    /**
     * @notice Block number of the last call to _tryUpdateTWAP().
     *         Used for once-per-block deduplication regardless of success.
     */
    uint256 public lastTwapUpdateBlock;

    // ─────────────────────────────────────────────────────────────────────
    // FACTORY STATE
    // ─────────────────────────────────────────────────────────────────────

    address public owner;

    // Implementation contracts (clone targets)
    address public immutable standardImpl;
    address public immutable taxImpl;
    address public immutable reflectionImpl;

    // DEX
    address public pancakeRouter;

    // Fees — all USD values use 18-decimal fixed point (1e18 = $1.00)
    uint256 public creationFeeUSD;     // default: 1e18  ($1.00)
    uint256 public tradeFee;           // bps, default 100 = 1 %
    address public feeRecipient;
    uint256 public accumulatedFees;    // BNB accumulated, withdrawn by owner

    // Default bonding-curve parameters (USD, 18-decimal)
    uint256 public defaultVirtualBNBUSD;      // default: 2_000e18  ($2 000 virtual mcap)
    uint256 public defaultMigrationTargetUSD; // default: 11_000e18 ($11 000 raise target)

    // Per-token data
    mapping(address => TokenConfig) public tokens;
    address[] public allTokens;

    // Creator index
    mapping(address => address[]) private _tokensByCreator;

    // ─── Constants ───────────────────────────────────────────────────────
    uint256 private constant LIQUIDITY_BPS = 3800;
    uint256 private constant CREATOR_BPS   =  500;
    uint256 private constant BPS_DENOM     = 10000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant ANTIBOT_MIN_BLOCKS =  10;
    uint256 private constant ANTIBOT_MAX_BLOCKS = 199;

    // Reentrancy
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

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
    event TWAPUpdated(uint256 priceAvg, uint256 blockNumber);
    event DefaultParamsUpdated(uint256 virtualBNBUSD, uint256 migrationTargetUSD);
    event FeesWithdrawn(address recipient, uint256 amount);
    event RouterUpdated(address router);
    event FeeRecipientUpdated(address recipient);
    event TradeFeeUpdated(uint256 feeBps);
    event UsdcPairUpdated(address usdcToken, address pair, bool isToken0);
    event TwapMaxAgeBlocksUpdated(uint256 blocks);

    // ─────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ─────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @param router_       PancakeSwap V2 router
     * @param feeRecipient_ Address that receives platform fees
     * @param usdc_         USDC token address (used to derive isToken0)
     * @param usdcWbnbPair_ PancakeSwap V2 USDC/WBNB pair (price oracle)
     * @param usdcDecimals_ USDC decimals: 6 (Circle) or 18 (Binance-peg)
     * @param tradeFee_     Trade fee in bps — recommended default: 100 (1 %)
     *
     * Defaults: creationFee = $1, virtualBNB = $2 000, migrationTarget = $11 000,
     *           twapMaxAgeBlocks = 1 440 (~2 h on BSC).
     */
    constructor(
        address router_,
        address feeRecipient_,
        address usdc_,
        address usdcWbnbPair_,
        uint8   usdcDecimals_,
        uint256 tradeFee_
    ) {
        require(router_       != address(0), "Zero router");
        require(feeRecipient_ != address(0), "Zero fee recipient");
        require(usdc_         != address(0), "Zero USDC");
        require(usdcWbnbPair_ != address(0), "Zero USDC pair");
        require(tradeFee_ <= 500,            "Trade fee > 5 %");
        require(usdcDecimals_ == 6 || usdcDecimals_ == 18, "Unsupported USDC decimals");

        owner                      = msg.sender;
        pancakeRouter              = router_;
        feeRecipient               = feeRecipient_;
        usdcToken                  = usdc_;
        usdcWbnbPair               = usdcWbnbPair_;
        usdcDecimals               = usdcDecimals_;
        tradeFee                   = tradeFee_;
        creationFeeUSD             = 1e18;          // $1.00
        defaultVirtualBNBUSD       = 2_000e18;      // $2 000
        defaultMigrationTargetUSD  = 11_000e18;     // $11 000
        twapMaxAgeBlocks           = 1_440;         // ~2 h at 5 s/block on BSC
        _status                    = _NOT_ENTERED;

        // Derive isToken0 from the pair itself
        usdcIsToken0 = IPancakeV2Pair(usdcWbnbPair_).token0() == usdc_;

        // Snapshot cumulative price so the first updateTWAP() can compute a delta.
        (,, uint32 ts) = IPancakeV2Pair(usdcWbnbPair_).getReserves();
        priceCumulativeLast = usdcIsToken0
            ? IPancakeV2Pair(usdcWbnbPair_).price0CumulativeLast()
            : IPancakeV2Pair(usdcWbnbPair_).price1CumulativeLast();
        twapTimestampLast = ts;

        // Deploy token implementations (clone targets)
        standardImpl   = address(new StandardToken());
        taxImpl        = address(new TaxToken());
        reflectionImpl = address(new ReflectionToken());
    }

    // ─────────────────────────────────────────────────────────────────────
    // TWAP ORACLE
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Manually trigger a TWAP update.
     *         Callable by anyone.  Silently no-ops if the period has not
     *         elapsed yet or if the oracle was already refreshed this block.
     */
    function updateTWAP() external {
        _tryUpdateTWAP();
    }

    /**
     * @dev Attempt to refresh the TWAP price.  Executes at most once per block;
     *      further calls within the same block are silent no-ops.
     *      Also silently skips if TWAP_PERIOD has not yet elapsed.
     *      Never reverts — safe to call from any interaction.
     */
    function _tryUpdateTWAP() internal {
        if (block.number == lastTwapUpdateBlock) return;
        lastTwapUpdateBlock = block.number;

        (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32  blockTimestamp
        ) = _currentCumulativePrices();

        uint32 timeElapsed = blockTimestamp - twapTimestampLast; // uint32 overflow intentional

        if (timeElapsed < TWAP_PERIOD) return;

        uint256 currentCumulative = usdcIsToken0 ? price0Cumulative : price1Cumulative;
        uint256 newPriceAvg = (currentCumulative - priceCumulativeLast) / timeElapsed;

        if (newPriceAvg == 0) return;

        twapPriceAvg        = newPriceAvg;
        priceCumulativeLast = currentCumulative;
        twapTimestampLast   = blockTimestamp;
        twapLastSuccessBlock = block.number;

        emit TWAPUpdated(newPriceAvg, block.number);
    }

    /**
     * @notice Returns the current live spot cumulative prices from the pair,
     *         including any price movement since the pair's last on-chain update.
     *         Mirrors UniswapV2OracleLibrary.currentCumulativePrices (overflow safe).
     */
    function _currentCumulativePrices()
        internal view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        blockTimestamp   = uint32(block.timestamp);
        price0Cumulative = IPancakeV2Pair(usdcWbnbPair).price0CumulativeLast();
        price1Cumulative = IPancakeV2Pair(usdcWbnbPair).price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 pairTs) =
            IPancakeV2Pair(usdcWbnbPair).getReserves();

        if (pairTs != blockTimestamp && reserve0 > 0 && reserve1 > 0) {
            uint32 dt = blockTimestamp - pairTs;
            unchecked {
                price0Cumulative += (uint256(reserve1) << 112) / uint256(reserve0) * dt;
                price1Cumulative += (uint256(reserve0) << 112) / uint256(reserve1) * dt;
            }
        }
    }

    /**
     * @notice Convert a USD amount to BNB wei using the stored TWAP.
     *         Reverts if the TWAP has not been successfully refreshed within
     *         twapMaxAgeBlocks blocks.
     * @param usd18  USD amount with 18-decimal precision (1e18 = $1.00)
     * @return bnb   BNB in wei
     */
    function usdToBNB(uint256 usd18) public view returns (uint256 bnb) {
        require(twapPriceAvg > 0, "TWAP not initialized");
        require(
            block.number - twapLastSuccessBlock <= twapMaxAgeBlocks,
            "TWAP stale"
        );

        uint256 usdcUnits;
        if (usdcDecimals >= 18) {
            usdcUnits = usd18 * (10 ** (usdcDecimals - 18));
        } else {
            usdcUnits = usd18 / (10 ** (18 - usdcDecimals));
        }

        // twapPriceAvg is UQ112x112 (WBNB wei per 1 USDC unit).
        bnb = (twapPriceAvg * usdcUnits) >> 112;
        require(bnb > 0, "TWAP: zero BNB output");
    }

    // ─────────────────────────────────────────────────────────────────────
    // TOKEN CREATION
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a Standard ERC-20 token.
     *         msg.value must cover the $1 creation fee (in BNB at TWAP rate).
     *         Any excess BNB is used as an immediate bonding-curve buy for the
     *         creator (creator is always antibot-exempt).
     */
    function createToken(BaseParams calldata p) external payable nonReentrant returns (address token) {
        _tryUpdateTWAP();
        uint256 earlyBuy = _collectCreationFee();
        token = _cloneCreate2(standardImpl, p.salt);

        (uint256 supply, uint256 liqTokens, uint256 creatorTokens, uint256 bcTokens)
            = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);

        StandardToken(token).initForLaunchpad(p.name, p.symbol, supply, address(this), msg.sender);
        _registerToken(token, TokenType.STANDARD, supply, liqTokens, creatorTokens, bcTokens, p);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);

        emit TokenCreated(token, TokenType.STANDARD, msg.sender, supply,
            p.enableAntibot, tokens[token].tradingBlock);
    }

    /**
     * @notice Create a Tax Token.
     */
    function createTT(CreateTTParams calldata p) external payable nonReentrant returns (address token) {
        _tryUpdateTWAP();
        uint256 earlyBuy = _collectCreationFee();
        token = _cloneCreate2(taxImpl, p.base.salt);

        (uint256 supply, uint256 liqTokens, uint256 creatorTokens, uint256 bcTokens)
            = _computeAlloc(_supplyFromOption(p.base.supplyOption), p.base.enableCreatorAlloc);

        TaxToken(token).initForLaunchpad(
            p.base.name, p.base.symbol, supply, address(this),
            p.wallets, p.buyTaxes, p.sellTaxes, p.swapThreshold, msg.sender
        );
        _registerToken(token, TokenType.TAX, supply, liqTokens, creatorTokens, bcTokens, p.base);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);

        emit TokenCreated(token, TokenType.TAX, msg.sender, supply,
            p.base.enableAntibot, tokens[token].tradingBlock);
    }

    /**
     * @notice Create a Reflection Token.
     */
    function createRFL(CreateRFLParams calldata p) external payable nonReentrant returns (address token) {
        _tryUpdateTWAP();
        uint256 earlyBuy = _collectCreationFee();
        token = _cloneCreate2(reflectionImpl, p.base.salt);

        (uint256 supply, uint256 liqTokens, uint256 creatorTokens, uint256 bcTokens)
            = _computeAlloc(_supplyFromOption(p.base.supplyOption), p.base.enableCreatorAlloc);

        ReflectionToken(token).initForLaunchpad(
            p.base.name, p.base.symbol, supply, address(this),
            p.wallets, p.buyTaxes, p.sellTaxes, p.swapThreshold, msg.sender
        );
        _registerToken(token, TokenType.REFLECTION, supply, liqTokens, creatorTokens, bcTokens, p.base);

        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0, true);

        emit TokenCreated(token, TokenType.REFLECTION, msg.sender, supply,
            p.base.enableAntibot, tokens[token].tradingBlock);
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
        _tryUpdateTWAP();
        require(msg.value > 0, "Zero BNB");
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
        _tryUpdateTWAP();
        TokenConfig storage tc = tokens[token_];
        require(tc.token != address(0),      "Unknown token");
        require(!tc.migrated,                "Already migrated");
        require(amountIn > 0,                "Zero amount");
        require(tc.bcTokensSold >= amountIn, "Exceeds sold supply");

        ILaunchpadToken(token_).transferFrom(msg.sender, address(this), amountIn);

        uint256 poolBNB       = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens    = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 newPoolTokens = poolTokens + amountIn;
        uint256 newPoolBNB    = tc.k / newPoolTokens;
        uint256 grossBNB      = poolBNB - newPoolBNB;
        require(grossBNB <= tc.raisedBNB, "Insufficient pool BNB");

        uint256 fee    = (grossBNB * tradeFee) / BPS_DENOM;
        uint256 netBNB = grossBNB - fee;
        require(netBNB >= minBNBOut, "Slippage: too little BNB");

        tc.raisedBNB    -= grossBNB;
        tc.bcTokensSold -= amountIn;
        accumulatedFees += fee;

        (bool ok,) = payable(msg.sender).call{value: netBNB}("");
        require(ok, "BNB transfer failed");

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
        _tryUpdateTWAP();
        TokenConfig storage tc = tokens[token_];
        require(tc.token != address(0),             "Unknown token");
        require(!tc.migrated,                       "Already migrated");
        require(tc.raisedBNB >= tc.migrationTarget, "Migration target not reached");

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
     *      This ensures the bonding curve is fully exhausted at the target —
     *      no BC tokens are left over to burn at migration.
     *
     * @param skipAntibot  When true the antibot penalty is not applied.
     *                     Only the initial early buy embedded in createToken /
     *                     createTT / createRFL passes true here — that buy is
     *                     part of the atomic creation transaction and is the one
     *                     intentional creator pre-buy.  All subsequent buy()
     *                     calls, including those made by the creator in the same
     *                     or any later antibot block, receive the full penalty.
     */
    function _executeBuy(address token_, address buyer, uint256 bnbIn, uint256 minOut, bool skipAntibot) internal {
        TokenConfig storage tc = tokens[token_];
        require(tc.token != address(0), "Unknown token");
        require(!tc.migrated,           "Already migrated");

        uint256 poolBNB    = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;

        // ── Migration cap ─────────────────────────────────────────────────
        // grossNeeded = ceil(bnbNeeded / (1 - tradeFee%)) — gross BNB that,
        // after fee deduction, yields exactly the net BNB needed to hit target.
        uint256 bnbNeeded   = tc.migrationTarget - tc.raisedBNB;
        uint256 grossNeeded = tradeFee == 0
            ? bnbNeeded
            : (bnbNeeded * BPS_DENOM + (BPS_DENOM - tradeFee) - 1) / (BPS_DENOM - tradeFee);

        uint256 refund;
        uint256 fee;
        uint256 netBNB;
        uint256 tokensOut;

        if (bnbIn >= grossNeeded) {
            // ── Crossing buy: sell all remaining tokens, cap BNB collected ──
            refund    = bnbIn - grossNeeded;
            fee       = (grossNeeded * tradeFee) / BPS_DENOM;
            netBNB    = grossNeeded - fee;  // ≥ bnbNeeded (due to ceil rounding)
            tokensOut = poolTokens;
        } else {
            // ── Normal AMM buy ────────────────────────────────────────────
            fee       = (bnbIn * tradeFee) / BPS_DENOM;
            netBNB    = bnbIn - fee;
            uint256 newPoolBNB = poolBNB + netBNB;
            tokensOut = poolTokens - (tc.k / newPoolBNB);
            if (tokensOut > poolTokens) tokensOut = poolTokens;
        }

        require(tokensOut >= minOut, "Slippage: too few tokens");
        require(tokensOut > 0,       "Zero tokens out");

        accumulatedFees += fee;
        tc.raisedBNB    += netBNB;
        tc.bcTokensSold += tokensOut;

        // ── Decaying antibot ──────────────────────────────────────────────
        // skipAntibot is only true for the atomic early buy inside createToken /
        // createTT / createRFL.  All buy() calls — including those from the
        // creator in the same or any later antibot block — receive the penalty.
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

        // Refund excess BNB before migration (state fully updated, nonReentrant guards)
        if (refund > 0) {
            (bool ok,) = payable(buyer).call{value: refund}("");
            require(ok, "Refund failed");
        }

        emit TokenBought(token_, buyer, bnbIn - refund, tokensOut, tokensToDead, tc.raisedBNB);

        // Auto-migrate if crossing target
        if (!tc.migrated && tc.raisedBNB >= tc.migrationTarget) {
            _doMigrate(tc, token_);
        }
    }

    /// @dev Shared migration logic (called from migrate() and _executeBuy).
    function _doMigrate(TokenConfig storage tc, address token_) internal {
        tc.migrated = true;

        uint256 migrationBNB = tc.raisedBNB;
        uint256 liqTokens    = tc.liquidityTokens;

        ILaunchpadToken(token_).approve(pancakeRouter, liqTokens);

        // LP tokens locked to dead wallet forever
        IPancakeRouter02(pancakeRouter).addLiquidityETH{value: migrationBNB}(
            token_, liqTokens, 0, 0, DEAD, block.timestamp + 300
        );

        address dexFactory = IPancakeRouter02(pancakeRouter).factory();
        address weth_      = IPancakeRouter02(pancakeRouter).WETH();
        address pair_      = IPancakeFactory(dexFactory).getPair(token_, weth_);
        require(pair_ != address(0), "Pair not created");

        ILaunchpadToken(token_).enableTrading(pair_, pancakeRouter);

        // Burn any unsold BC tokens (should be zero after migration-cap enforcement,
        // but kept as a safety net for edge cases such as direct migrate() calls).
        uint256 unsold = tc.bcTokensTotal - tc.bcTokensSold;
        if (unsold > 0) ILaunchpadToken(token_).transfer(DEAD, unsold);

        tc.raisedBNB = 0;
        emit TokenMigrated(token_, pair_, migrationBNB, liqTokens);
    }

    /// @dev Register token config after clone + init.
    function _registerToken(
        address       token_,
        TokenType     tokenType_,
        uint256       supply,
        uint256       liqTokens,
        uint256       creatorTokens,
        uint256       bcTokens,
        BaseParams calldata p
    ) internal {
        uint256 vBNBusd = p.customVirtualBNBUSD      > 0 ? p.customVirtualBNBUSD      : defaultVirtualBNBUSD;
        uint256 mTgtusd = p.customMigrationTargetUSD > 0 ? p.customMigrationTargetUSD : defaultMigrationTargetUSD;

        uint256 vBNB = usdToBNB(vBNBusd);
        uint256 mTgt = usdToBNB(mTgtusd);

        uint256 antibotBlocks = 0;
        if (p.enableAntibot) {
            require(
                p.antibotBlocks >= ANTIBOT_MIN_BLOCKS &&
                p.antibotBlocks <= ANTIBOT_MAX_BLOCKS,
                "Antibot blocks out of range"
            );
            antibotBlocks = p.antibotBlocks;
        }

        TokenConfig storage tc = tokens[token_];
        tc.token            = token_;
        tc.tokenType        = tokenType_;
        tc.creator          = msg.sender;
        tc.totalSupply      = supply;
        tc.liquidityTokens  = liqTokens;
        tc.creatorTokens    = creatorTokens;
        tc.bcTokensTotal    = bcTokens;
        tc.bcTokensSold     = 0;
        tc.virtualBNB       = vBNB;
        tc.k                = vBNB * bcTokens;
        tc.raisedBNB        = 0;
        tc.migrationTarget  = mTgt;
        tc.antibotEnabled   = p.enableAntibot;
        tc.creationBlock    = block.number;
        tc.tradingBlock     = block.number + antibotBlocks;
        tc.migrated         = false;

        allTokens.push(token_);
        _tokensByCreator[msg.sender].push(token_);

        // ── Creator vesting: deposit tokens into the token contract itself ──
        if (creatorTokens > 0) {
            ILaunchpadToken(token_).transfer(token_, creatorTokens);
            ILaunchpadToken(token_).setupVesting(msg.sender, creatorTokens);
        }
    }

    /// @dev Deduct $1 creation fee (BNB equivalent); return excess for early buy.
    function _collectCreationFee() internal returns (uint256 earlyBuy) {
        uint256 feeBNB = usdToBNB(creationFeeUSD);
        require(msg.value >= feeBNB, "Insufficient creation fee");
        accumulatedFees += feeBNB;
        earlyBuy = msg.value - feeBNB;
    }

    function _computeAlloc(uint256 supply, bool hasCreator)
        internal pure
        returns (uint256 total, uint256 liqTokens, uint256 creatorTokens, uint256 bcTokens)
    {
        total         = supply;
        liqTokens     = (supply * LIQUIDITY_BPS) / BPS_DENOM;
        creatorTokens = hasCreator ? (supply * CREATOR_BPS) / BPS_DENOM : 0;
        bcTokens      = supply - liqTokens - creatorTokens;
    }

    function _supplyFromOption(SupplyOption opt) internal pure returns (uint256) {
        if (opt == SupplyOption.ONE)      return 1e18;
        if (opt == SupplyOption.THOUSAND) return 1_000e18;
        if (opt == SupplyOption.MILLION)  return 1_000_000e18;
        return 1_000_000_000e18; // BILLION
    }

    /**
     * @dev Deploy an EIP-1167 minimal proxy via CREATE2.
     *      The actual salt is keccak256(abi.encode(msg.sender, userSalt)) so that
     *      the same userSalt used by different senders produces different addresses,
     *      preventing cross-sender front-running.
     *
     *      The resulting address MUST end in 0x1111 (last 4 hex digits).
     *      Use predictTokenAddress() off-chain to mine a valid salt.
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
        require(instance != address(0),             "Clone failed");
        require(uint16(uint160(instance)) == 0x1111, "Address must end in 1111");
    }

    // ─────────────────────────────────────────────────────────────────────
    // OWNER ADMIN
    // ─────────────────────────────────────────────────────────────────────

    function setDefaultParams(uint256 virtualBNBUSD_, uint256 migrationTargetUSD_) external onlyOwner {
        require(virtualBNBUSD_      > 0, "Zero virtualBNB USD");
        require(migrationTargetUSD_ > 0, "Zero migration target USD");
        defaultVirtualBNBUSD      = virtualBNBUSD_;
        defaultMigrationTargetUSD = migrationTargetUSD_;
        emit DefaultParamsUpdated(virtualBNBUSD_, migrationTargetUSD_);
    }

    function setCreationFeeUSD(uint256 feeUSD_) external onlyOwner {
        require(feeUSD_ > 0, "Zero fee");
        creationFeeUSD = feeUSD_;
    }

    /// @notice Update the trade fee. 100 = 1 % (max 5 %).
    function setTradeFee(uint256 fee_) external onlyOwner {
        require(fee_ <= 500, "Fee > 5 %");
        tradeFee = fee_;
        emit TradeFeeUpdated(fee_);
    }

    function setFeeRecipient(address rec_) external onlyOwner {
        require(rec_ != address(0), "Zero address");
        feeRecipient = rec_;
        emit FeeRecipientUpdated(rec_);
    }

    function setRouter(address router_) external onlyOwner {
        require(router_ != address(0), "Zero address");
        pancakeRouter = router_;
        emit RouterUpdated(router_);
    }

    /**
     * @notice Update the USDC/WBNB oracle pair.
     *         Provide the USDC token address; isToken0 is derived on-chain.
     *         Resets TWAP state — call updateTWAP() before the next token launch.
     */
    function setUsdcPair(address usdc_, address pair_, uint8 decimals_) external onlyOwner {
        require(usdc_ != address(0), "Zero USDC");
        require(pair_ != address(0), "Zero pair");
        require(decimals_ == 6 || decimals_ == 18, "Unsupported decimals");

        bool isToken0 = IPancakeV2Pair(pair_).token0() == usdc_;

        usdcToken    = usdc_;
        usdcWbnbPair = pair_;
        usdcIsToken0 = isToken0;
        usdcDecimals = decimals_;

        // Reset TWAP state — force a fresh updateTWAP() before use
        (,, uint32 ts) = IPancakeV2Pair(pair_).getReserves();
        priceCumulativeLast = isToken0
            ? IPancakeV2Pair(pair_).price0CumulativeLast()
            : IPancakeV2Pair(pair_).price1CumulativeLast();
        twapTimestampLast    = ts;
        twapPriceAvg         = 0;
        twapLastSuccessBlock = 0;

        emit UsdcPairUpdated(usdc_, pair_, isToken0);
    }

    /**
     * @notice Set the maximum age of the TWAP observation in blocks.
     *         Default: 1 440 (~2 h on BSC).  Min: 60 (~5 min).
     */
    function setTwapMaxAgeBlocks(uint256 blocks_) external onlyOwner {
        require(blocks_ >= 60, "Max age too small");
        twapMaxAgeBlocks = blocks_;
        emit TwapMaxAgeBlocksUpdated(blocks_);
    }

    function transferOwnership(address newOwner_) external onlyOwner {
        require(newOwner_ != address(0), "Zero address");
        owner = newOwner_;
    }

    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        require(amount > 0, "Nothing to withdraw");
        accumulatedFees = 0;
        (bool ok,) = payable(feeRecipient).call{value: amount}("");
        require(ok, "BNB transfer failed");
        emit FeesWithdrawn(feeRecipient, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // VIEW / PRICE HELPERS
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Tokens received for a given BNB input (after trade fee).
     *         Accounts for the migration cap: if bnbIn would cross the target,
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
        uint256 bnbNeeded  = tc.migrationTarget - tc.raisedBNB;
        uint256 grossNeeded = tradeFee == 0
            ? bnbNeeded
            : (bnbNeeded * BPS_DENOM + (BPS_DENOM - tradeFee) - 1) / (BPS_DENOM - tradeFee);

        if (bnbIn >= grossNeeded) {
            feeBNB    = (grossNeeded * tradeFee) / BPS_DENOM;
            tokensOut = poolTokens;
        } else {
            feeBNB    = (bnbIn * tradeFee) / BPS_DENOM;
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
        feeBNB = (grossBNB * tradeFee) / BPS_DENOM;
        bnbOut = grossBNB - feeBNB;
    }

    /**
     * @notice Spot price on the bonding curve: BNB per whole token (×1e18).
     */
    function getSpotPrice(address token_) external view returns (uint256 price) {
        TokenConfig storage tc = tokens[token_];
        require(tc.token != address(0), "Unknown token");
        uint256 poolBNB    = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        if (poolTokens == 0) return type(uint256).max;
        price = (poolBNB * 1e18) / poolTokens;
    }

    /**
     * @notice Predict the CREATE2 address that would result from calling
     *         createToken / createTT / createRFL with the given parameters.
     *         Use this off-chain to mine a userSalt whose resulting address
     *         ends in 0x1111.
     *
     * @param creator_   Address that will call the create function (msg.sender)
     * @param userSalt_  The salt value that will be passed in BaseParams.salt
     * @param impl_      Implementation address: standardImpl / taxImpl / reflectionImpl
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

    /// @notice Current creation fee denominated in BNB (refreshed from TWAP).
    function creationFeeBNB() external view returns (uint256) {
        return usdToBNB(creationFeeUSD);
    }

    /// @notice Total tokens launched across all creators.
    function totalTokensLaunched() external view returns (uint256) { return allTokens.length; }

    /**
     * @notice All token addresses created by a given creator, in launch order.
     * @param creator_ Creator wallet address
     */
    function getTokensByCreator(address creator_) external view returns (address[] memory) {
        return _tokensByCreator[creator_];
    }

    /**
     * @notice Number of tokens launched by a given creator.
     */
    function tokenCountByCreator(address creator_) external view returns (uint256) {
        return _tokensByCreator[creator_].length;
    }

    receive() external payable {}
}
