// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface ISparkToken {
    function initSpark(string calldata name_, string calldata symbol_, string calldata metaURI_, address launcher_) external;
    function transferOwnership(address newOwner) external;
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
    uint256 public constant POOL_TOKENS  = 999_900_000e18; // 99.99 %; remaining ~0.01 % + dust → creator

    uint24  private constant FEE_TIER   = 10_000;  // V3 1 % tier, tick spacing 200
    int24   private constant TICK_LOWER = -887_200; // full-range: nearest multiple-of-200 within ±887272
    int24   private constant TICK_UPPER =  887_200;

    struct DexConfig {
        address positionManager;
        address router;
        bool    enabled;
    }

    struct QuoteToken {
        uint256 launchFee; // raw units of the token
        uint8   decimals;
        bool    enabled;
        bool    isNative;  // true → fee paid in ETH, WETH used in pool
    }

    mapping(address => DexConfig)   public dexes;       // factory → DEX config
    mapping(address => QuoteToken)  public quoteTokens;

    address      public immutable weth;
    address      public immutable tokenImpl;
    ISparkLocker public immutable locker;
    address      public owner;

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
    event QuoteTokenAdded(address indexed token, uint256 fee, uint8 decimals);
    event QuoteTokenDisabled(address indexed token);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(
        address weth_,
        address tokenImpl_,
        address locker_,
        address initialFactory_,
        address initialPositionMgr_,
        address initialRouter_
    ) {
        if (weth_               == address(0)) revert ZeroAddress();
        if (tokenImpl_          == address(0)) revert ZeroAddress();
        if (locker_             == address(0)) revert ZeroAddress();
        if (initialFactory_     == address(0)) revert ZeroAddress();
        if (initialPositionMgr_ == address(0)) revert ZeroAddress();
        if (initialRouter_      == address(0)) revert ZeroAddress();

        owner     = msg.sender;
        weth      = weth_;
        tokenImpl = tokenImpl_;
        locker    = ISparkLocker(locker_);

        dexes[initialFactory_] = DexConfig({
            positionManager: initialPositionMgr_,
            router:          initialRouter_,
            enabled:         true
        });
        emit DexAdded(initialFactory_, initialPositionMgr_, initialRouter_);

        quoteTokens[weth_] = QuoteToken({
            launchFee: 0.0005 ether,
            decimals:  18,
            enabled:   true,
            isNative:  true
        });
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function addDex(address factory_, address positionMgr_, address router_)
        external onlyOwner
    {
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

    function disableQuoteToken(address token_) external onlyOwner {
        if (!quoteTokens[token_].enabled) revert UnsupportedQuoteToken();
        quoteTokens[token_].enabled = false;
        emit QuoteTokenDisabled(token_);
    }

    function addQuoteToken(address token_, uint256 fee_, uint8 decimals_)
        external onlyOwner
    {
        if (token_ == address(0)) revert ZeroAddress();
        if (fee_   == 0)          revert ZeroAmount();
        quoteTokens[token_] = QuoteToken({
            launchFee: fee_,
            decimals:  decimals_,
            enabled:   true,
            isNative:  (token_ == weth)
        });
        emit QuoteTokenAdded(token_, fee_, decimals_);
    }

    function launch(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_,
        address         feeWallet_,
        address         factory_,
        address         quoteToken_,
        uint256         extraBuy_
    ) external payable returns (address token, address pool, uint256 tokenId) {
        // Deploy while string params are still near the top of the EVM stack (13 slots total
        // here vs 22+ if deferred past the address/uint locals below). The remaining work is
        // delegated to _setupAndRegister so those string slots never appear in the same frame.
        token = _deployAndInit(name_, symbol_, metaURI_);
        (pool, tokenId) = _setupAndRegister(token, feeWallet_, factory_, quoteToken_, extraBuy_);
    }

    // Contains all post-deploy launch logic. Separated from launch() so the three string
    // calldata params (6 stack slots) are absent, keeping peak stack depth within the EVM limit.
    function _setupAndRegister(
        address token,
        address feeWallet_,
        address factory_,
        address quoteToken_,
        uint256 extraBuy_
    ) private returns (address pool, uint256 tokenId) {
        DexConfig memory dex = dexes[factory_];
        if (!dex.enabled) revert UnsupportedDex();

        address feeWallet = feeWallet_ == address(0) ? msg.sender : feeWallet_;

        // Scope qt to free its stack slot after fee collection.
        uint256 quoteFee;
        {
            QuoteToken memory qt = quoteTokens[quoteToken_];
            if (!qt.enabled) revert UnsupportedQuoteToken();
            quoteFee = qt.launchFee;
            if (qt.isNative) {
                if (msg.value < quoteFee) revert WrongFee();
                IWETH(weth).deposit{value: msg.value}();
            } else {
                if (msg.value != 0) revert UnexpectedETH();
                _pullFrom(quoteToken_, msg.sender, quoteFee + extraBuy_);
            }
        }

        // Scope pool-setup locals (token0/1, a0/1) to free them after registration.
        {
            (address token0, address token1, uint256 a0, uint256 a1) = quoteToken_ < token
                ? (quoteToken_, token,  quoteFee,    POOL_TOKENS)
                : (token,        quoteToken_, POOL_TOKENS, quoteFee);

            if (IUniswapV3Factory(factory_).getPool(token0, token1, FEE_TIER) != address(0))
                revert PoolAlreadyExists();
            pool = IUniswapV3Factory(factory_).createPool(token0, token1, FEE_TIER);
            IUniswapV3Pool(pool).initialize(_sqrtPriceX96(a0, a1));

            _safeApprove(quoteToken_, dex.positionManager, quoteFee);
            _safeApprove(token,       dex.positionManager, POOL_TOKENS);

            (tokenId, , , ) = INonfungiblePositionManager(dex.positionManager).mint(
                INonfungiblePositionManager.MintParams({
                    token0:         token0,
                    token1:         token1,
                    fee:            FEE_TIER,
                    tickLower:      TICK_LOWER,
                    tickUpper:      TICK_UPPER,
                    amount0Desired: a0,
                    amount1Desired: a1,
                    amount0Min:     0,
                    amount1Min:     0,
                    recipient:      address(locker),
                    deadline:       block.timestamp
                })
            );

            locker.registerPosition(
                token, tokenId, feeWallet, token0, token1, pool, dex.positionManager
            );
        }

        // Scope quoteDust to free its slot before the creator-token transfer.
        {
            uint256 quoteDust = _balanceOf(quoteToken_, address(this));
            if (quoteDust > 0) {
                _safeApprove(quoteToken_, dex.router, quoteDust);
                ISwapRouter(dex.router).exactInputSingle(ISwapRouter.ExactInputSingleParams({
                    tokenIn:           quoteToken_,
                    tokenOut:          token,
                    fee:               FEE_TIER,
                    recipient:         msg.sender,
                    deadline:          block.timestamp,
                    amountIn:          quoteDust,
                    amountOutMinimum:  0,
                    sqrtPriceLimitX96: 0
                }));
            }
        }

        {
            uint256 creatorTokens = ISparkToken(token).balanceOf(address(this));
            if (creatorTokens > 0) ISparkToken(token).transfer(msg.sender, creatorTokens);
        }

        ISparkToken(token).transferOwnership(msg.sender);

        emit TokenLaunched(token, msg.sender, factory_, quoteToken_, feeWallet, pool, tokenId);
    }

    receive() external payable {}

    // Isolated so the three string calldata params stay near the top of the EVM stack
    // when initSpark is called, avoiding stack-too-deep in launch().
    function _deployAndInit(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_
    ) private returns (address token) {
        token = _clone(tokenImpl);
        ISparkToken(token).initSpark(name_, symbol_, metaURI_, address(this));
    }

    // EIP-1167 minimal proxy — 55-byte deployment (10 creation + 45 runtime).
    //   creation : 3d602d80600a3d3981f3
    //   runtime  : 363d3d373d3d3d363d73 <impl 20 bytes> 5af43d82803e903d91602b57fd5bf3
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
    function _sqrtPriceX96(uint256 amount0, uint256 amount1)
        private pure returns (uint160)
    {
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
        token_.call(abi.encodeWithSelector(0x095ea7b3, spender, 0)); // approve(address,uint256)
        (bool ok, ) = token_.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok) revert ApprovalFailed();
    }

    // transferFrom(address,address,uint256)
    function _pullFrom(address token_, address from, uint256 amount) private {
        (bool ok, bytes memory data) = token_.call(
            abi.encodeWithSelector(0x23b872dd, from, address(this), amount)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    // balanceOf(address) — returns 0 on failure
    function _balanceOf(address token_, address account) private view returns (uint256 bal) {
        (bool ok, bytes memory data) = token_.staticcall(
            abi.encodeWithSelector(0x70a08231, account)
        );
        if (ok && data.length >= 32) bal = abi.decode(data, (uint256));
    }
}
