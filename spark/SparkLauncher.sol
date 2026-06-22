// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface ISparkToken {
    function initSpark(string calldata name_, string calldata symbol_, string calldata metaURI_, address launcher_) external;
    function renounceOwnership() external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ISparkLocker {
    function registerPosition(
        address token,
        uint256 tokenId,
        address feeWallet,
        address token0,
        address token1,
        address pool,
        address positionManager
    ) external;
}

interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24   tick,
        uint16  observationIndex,
        uint16  observationCardinality,
        uint16  observationCardinalityNext,
        uint8   feeProtocol,
        bool    unlocked
    );
}

interface INonfungiblePositionManager {
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

interface IWETH {
    function deposit() external payable;
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

contract SparkLauncher {

    error NotOwner();
    error UnsupportedQuoteToken();
    error UnsupportedDex();
    error WrongFee();
    error UnexpectedETH();
    error ZeroAddress();
    error ZeroAmount();
    error CloneFailed();
    error PoolAlreadyExists();
    error TransferFailed();
    error ApprovalFailed();

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant POOL_TOKENS  =   999_900_000e18; // 99.99 % seeded one-sided

    uint24 private constant FEE_TIER     = 10_000; // 1 % V3 tier
    int24  private constant MIN_TICK     = -887_200;
    int24  private constant MAX_TICK     =  887_200;
    int24  private constant TICK_SPACING =  200;   // spacing for 1 % tier

    struct DexConfig {
        address positionManager;
        address router;
        bool    enabled;
    }

    struct QuoteToken {
        uint256 launchFee;    // raw units of the token
        uint256 marketCapRef; // reference amount (raw units) targeting the desired launch market cap
        uint8   decimals;
        bool    enabled;
        bool    isNative;     // true → fee paid in ETH, WETH used as quote
    }

    mapping(address => DexConfig)  public dexes;
    mapping(address => QuoteToken) public quoteTokens;

    address      public immutable weth;
    address      public immutable tokenImpl;
    ISparkLocker public immutable locker;
    address      public owner;
    address      public launchFeeWallet; // receives platform launch fees

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address indexed factory,
        address         quoteToken,
        address         feeWallet,
        address         pool,
        uint256         tokenId
    );
    event DexAdded(address indexed factory, address positionManager, address router);
    event DexDisabled(address indexed factory);
    event QuoteTokenAdded(address indexed token, uint256 fee, uint8 decimals, uint256 marketCapRef);
    event QuoteTokenDisabled(address indexed token);
    event LaunchFeeWalletSet(address indexed wallet);
    event LaunchFeeSet(address indexed token, uint256 fee);
    event MarketCapRefSet(address indexed token, uint256 marketCapRef);
    event DecimalsSet(address indexed token, uint8 decimals);
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(
        address weth_,
        address tokenImpl_,
        address locker_,
        address launchFeeWallet_,
        address initialFactory_,
        address initialPositionMgr_,
        address initialRouter_
    ) {
        if (weth_               == address(0)) revert ZeroAddress();
        if (tokenImpl_          == address(0)) revert ZeroAddress();
        if (locker_             == address(0)) revert ZeroAddress();
        if (launchFeeWallet_    == address(0)) revert ZeroAddress();
        if (initialFactory_     == address(0)) revert ZeroAddress();
        if (initialPositionMgr_ == address(0)) revert ZeroAddress();
        if (initialRouter_      == address(0)) revert ZeroAddress();

        owner           = msg.sender;
        weth            = weth_;
        tokenImpl       = tokenImpl_;
        locker          = ISparkLocker(locker_);
        launchFeeWallet = launchFeeWallet_;

        dexes[initialFactory_] = DexConfig({
            positionManager: initialPositionMgr_,
            router:          initialRouter_,
            enabled:         true
        });
        emit DexAdded(initialFactory_, initialPositionMgr_, initialRouter_);

        quoteTokens[weth_] = QuoteToken({
            launchFee:    0.0005 ether,
            marketCapRef: 5e18,          // ~5 ETH market cap at launch
            decimals:     18,
            enabled:      true,
            isNative:     true
        });
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setLaunchFeeWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        launchFeeWallet = wallet;
        emit LaunchFeeWalletSet(wallet);
    }

    function setLaunchFee(address token_, uint256 fee_) external onlyOwner {
        if (!quoteTokens[token_].enabled) revert UnsupportedQuoteToken();
        if (fee_ == 0) revert ZeroAmount();
        quoteTokens[token_].launchFee = fee_;
        emit LaunchFeeSet(token_, fee_);
    }

    function setMarketCapRef(address token_, uint256 ref_) external onlyOwner {
        if (!quoteTokens[token_].enabled) revert UnsupportedQuoteToken();
        if (ref_ == 0) revert ZeroAmount();
        quoteTokens[token_].marketCapRef = ref_;
        emit MarketCapRefSet(token_, ref_);
    }

    function setDecimals(address token_, uint8 decimals_) external onlyOwner {
        if (!quoteTokens[token_].enabled) revert UnsupportedQuoteToken();
        quoteTokens[token_].decimals = decimals_;
        emit DecimalsSet(token_, decimals_);
    }

    function addDex(address factory_, address positionMgr_, address router_) external onlyOwner {
        if (factory_     == address(0)) revert ZeroAddress();
        if (positionMgr_ == address(0)) revert ZeroAddress();
        if (router_      == address(0)) revert ZeroAddress();
        dexes[factory_] = DexConfig({
            positionManager: positionMgr_,
            router:          router_,
            enabled:         true
        });
        emit DexAdded(factory_, positionMgr_, router_);
    }

    function disableDex(address factory_) external onlyOwner {
        if (!dexes[factory_].enabled) revert UnsupportedDex();
        dexes[factory_].enabled = false;
        emit DexDisabled(factory_);
    }

    function addQuoteToken(
        address token_,
        uint256 fee_,
        uint8   decimals_,
        uint256 marketCapRef_
    ) external onlyOwner {
        if (token_        == address(0)) revert ZeroAddress();
        if (fee_          == 0)          revert ZeroAmount();
        if (marketCapRef_ == 0)          revert ZeroAmount();
        quoteTokens[token_] = QuoteToken({
            launchFee:    fee_,
            marketCapRef: marketCapRef_,
            decimals:     decimals_,
            enabled:      true,
            isNative:     (token_ == weth)
        });
        emit QuoteTokenAdded(token_, fee_, decimals_, marketCapRef_);
    }

    function disableQuoteToken(address token_) external onlyOwner {
        if (!quoteTokens[token_].enabled) revert UnsupportedQuoteToken();
        quoteTokens[token_].enabled = false;
        emit QuoteTokenDisabled(token_);
    }

    // Recover ETH that became stuck in this contract (e.g. from a failed launch mid-flight).
    function rescueETH(address to_, uint256 amount_) external onlyOwner {
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();
        (bool ok,) = to_.call{value: amount_}("");
        if (!ok) revert TransferFailed();
        emit ETHRescued(to_, amount_);
    }

    // Recover ERC-20 tokens that became stuck in this contract.
    function rescueERC20(address token_, address to_, uint256 amount_) external onlyOwner {
        if (token_  == address(0)) revert ZeroAddress();
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();
        _safeTransfer(token_, to_, amount_);
        emit ERC20Rescued(token_, to_, amount_);
    }

    function launch(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_,
        address         feeWallet_,
        address         factory_,
        address         quoteToken_,
        uint256         extraBuy_    // extra quote tokens for instant buy (ERC-20 only; native uses msg.value excess)
    ) external payable returns (address token, address pool, uint256 tokenId) {
        token = _deployAndInit(name_, symbol_, metaURI_);
        (pool, tokenId) = _setupAndRegister(token, feeWallet_, factory_, quoteToken_, extraBuy_);
    }

    function _setupAndRegister(
        address token,
        address feeWallet_,
        address factory_,
        address quoteToken_,
        uint256 extraBuy_
    ) private returns (address pool, uint256 tokenId) {
        DexConfig memory dex = dexes[factory_];
        if (!dex.enabled) revert UnsupportedDex();

        QuoteToken memory qt = quoteTokens[quoteToken_];
        if (!qt.enabled) revert UnsupportedQuoteToken();

        uint256 extraQuote;

        // Collect payment and route launch fee to platform wallet.
        if (qt.isNative) {
            if (msg.value < qt.launchFee) revert WrongFee();
            IWETH(weth).deposit{value: msg.value}();
            extraQuote = msg.value - qt.launchFee;
        } else {
            if (msg.value != 0) revert UnexpectedETH();
            _pullFrom(quoteToken_, msg.sender, qt.launchFee + extraBuy_);
            extraQuote = extraBuy_;
        }
        // Fee goes to platform wallet — not into the pool.
        _safeTransfer(quoteToken_, launchFeeWallet, qt.launchFee);

        // Determine token ordering (V3 requires token0 < token1 by address).
        (address token0, address token1) = token < quoteToken_
            ? (token,       quoteToken_)
            : (quoteToken_, token      );

        if (IUniswapV3Factory(factory_).getPool(token0, token1, FEE_TIER) != address(0))
            revert PoolAlreadyExists();

        pool = IUniswapV3Factory(factory_).createPool(token0, token1, FEE_TIER);

        // Initialise at a price targeting qt.marketCapRef for the full TOTAL_SUPPLY.
        IUniswapV3Pool(pool).initialize(_computeSqrtPriceX96(token, quoteToken_, qt.marketCapRef));

        // Tick setup + mint extracted to avoid stack-too-deep in legacy codegen.
        tokenId = _mintLiquidity(dex.positionManager, token, token0, token1, pool);

        address feeWallet = feeWallet_ == address(0) ? msg.sender : feeWallet_;
        locker.registerPosition(token, tokenId, feeWallet, token0, token1, pool, dex.positionManager);

        // Instant buy: swap any excess quote tokens for SparkTokens → creator.
        if (extraQuote > 0) {
            _safeApprove(quoteToken_, dex.router, extraQuote);
            ISwapRouter(dex.router).exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn:           quoteToken_,
                tokenOut:          token,
                fee:               FEE_TIER,
                recipient:         msg.sender,
                deadline:          block.timestamp,
                amountIn:          extraQuote,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            }));
        }

        // Creator allocation: ~0.01 % + any mint dust remaining in this contract.
        uint256 creatorTokens = ISparkToken(token).balanceOf(address(this));
        if (creatorTokens > 0) ISparkToken(token).transfer(msg.sender, creatorTokens);

        // Renounce ownership immediately — token is permanently ownerless after launch.
        ISparkToken(token).renounceOwnership();

        emit TokenLaunched(token, msg.sender, factory_, quoteToken_, feeWallet, pool, tokenId);
    }

    receive() external payable {}

    // Reads the post-initialize tick, builds the one-sided tick range, approves, and mints
    // the LP position. Extracted from _setupAndRegister to keep its stack depth in range.
    function _mintLiquidity(
        address positionManager_,
        address token,
        address token0,
        address token1,
        address pool
    ) private returns (uint256 tokenId) {
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;

        // Reuse tickLower as a temp for currentTick — one fewer stack slot.
        (, tickLower,,,,,) = IUniswapV3Pool(pool).slot0();

        if (token == token0) {
            // SparkToken is token0 → held as token0 when currentTick >= tickUpper.
            tickUpper      = _floorToTickSpacing(tickLower); // <= currentTick ✓
            tickLower      = MIN_TICK;
            amount0Desired = POOL_TOKENS;
            amount1Desired = 0;
        } else {
            // SparkToken is token1 → held as token1 when currentTick < tickLower.
            tickLower      = _floorToTickSpacing(tickLower) + TICK_SPACING; // > currentTick ✓
            tickUpper      = MAX_TICK;
            amount0Desired = 0;
            amount1Desired = POOL_TOKENS;
        }

        _safeApprove(token, positionManager_, POOL_TOKENS);

        (tokenId,,,) = INonfungiblePositionManager(positionManager_).mint(
            INonfungiblePositionManager.MintParams({
                token0:         token0,
                token1:         token1,
                fee:            FEE_TIER,
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min:     0,
                amount1Min:     0,
                recipient:      address(locker),
                deadline:       block.timestamp
            })
        );
    }

    function _deployAndInit(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_
    ) private returns (address token) {
        token = _clone(tokenImpl);
        ISparkToken(token).initSpark(name_, symbol_, metaURI_, address(this));
    }

    // sqrtPriceX96 targeting marketCapRef_ for TOTAL_SUPPLY, adjusted for token ordering.
    function _computeSqrtPriceX96(address sparkToken, address quoteToken_, uint256 marketCapRef_)
        private pure returns (uint160)
    {
        // price = token1 / token0
        if (sparkToken < quoteToken_) {
            // sparkToken = token0, quote = token1 → price = marketCapRef_ / TOTAL_SUPPLY (very small)
            return _sqrtPriceX96(TOTAL_SUPPLY, marketCapRef_);
        } else {
            // quote = token0, sparkToken = token1 → price = TOTAL_SUPPLY / marketCapRef_ (very large)
            return _sqrtPriceX96(marketCapRef_, TOTAL_SUPPLY);
        }
    }

    // Floor tick down to the nearest TICK_SPACING multiple (handles negative ticks correctly).
    function _floorToTickSpacing(int24 tick) private pure returns (int24) {
        int24 compressed = tick / TICK_SPACING;
        // Solidity truncates towards zero; subtract 1 for negative non-multiples.
        if (tick < 0 && tick % TICK_SPACING != 0) compressed--;
        return compressed * TICK_SPACING;
    }

    // EIP-1167 minimal proxy — 55-byte deployment (10 creation + 45 runtime).
    function _clone(address impl) private returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert CloneFailed();
    }

    // sqrtPriceX96 = sqrt(amount1 / amount0) × 2^96
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
        (bool _ok,) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, 0));
        _ok;
        (bool ok,)  = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok) revert ApprovalFailed();
    }

    // transferFrom(address,address,uint256)
    function _pullFrom(address token_, address from, uint256 amount) private {
        (bool ok, bytes memory data) = token_.call(
            abi.encodeWithSelector(0x23b872dd, from, address(this), amount)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    // transfer(address,uint256) — USDT-safe (handles missing return value).
    function _safeTransfer(address token_, address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token_.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
