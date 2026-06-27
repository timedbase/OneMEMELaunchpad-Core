// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPositionManagerCV {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);
    function positions(uint256 tokenId) external view returns (
        uint96  nonce,
        address operator,
        address token0,
        address token1,
        uint24  fee,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );
}

interface IUniswapV3PoolFeesCV {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16  observationCardinality, uint16 observationCardinalityNext,
        uint32  feeProtocol, bool unlocked // PancakeSwap V3 packs this wider than uint8
    );
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick) external view returns (
        uint128 liquidityGross,
        int128  liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        int56   tickCumulativeOutside,
        uint160 secondsPerLiquidityOutsideX128,
        uint32  secondsOutside,
        bool    initialized
    );
}

/// @notice Shared per-creator escrow for every token launched through the Launchpad.
///         Two independent responsibilities live here:
///           1. Linear vesting of the creator's token allocation (unchanged from the
///              original VestingWallet).
///           2. Locking the V3 liquidity NFT minted for StandardToken migrations and
///              splitting its accruing 1% trading fees between creator / platform /
///              charity — mirroring spark/SparkLocker.sol's model exactly, so a
///              StandardToken creator earns an ongoing reward from their token's own
///              trading volume instead of the LP being burned outright.
///         TaxToken / ReflectionToken still migrate to PancakeSwap V2 with LP burned
///         at the dead address — unchanged; this vault never holds a position for them.
contract CreatorVault {

    uint256 public constant MIN_VESTING_DURATION = 30 days;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public owner;
    address public launchManager; // the Launchpad contract — may call addVesting() and registerPosition()

    struct Schedule {
        uint256 total;
        uint256 start;
        uint256 claimed;
        uint256 duration;
    }

    mapping(address => mapping(address => Schedule)) public schedules;

    // ── LP-lock state (SparkLocker-style) ────────────────────────────────────────
    uint256 public creatorBps  = 7_000; // 70 %
    uint256 public platformBps = 2_500; // 25 %
    uint256 public charityBps  =   500; //  5 %
    uint256 private constant BPS = 10_000;

    struct Position {
        uint256 tokenId;
        address feeWallet;
        address token0;
        address token1;
        address pool;            // needed for fee-growth queries in pendingCreatorFees
        address positionManager; // NFT manager for this position's DEX
    }

    address public platformWallet;
    address public charityWallet;

    mapping(address => Position) public positions; // launched token → locked position
    address[] public allPositionTokens;

    error NotOwner();
    error NotLaunchManager();
    error AlreadySetup();
    error NoSchedule();
    error NothingToClaim();
    error VestingDurationTooShort();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();
    error AlreadyRegistered();
    error UnknownToken();
    error NotAuthorized();
    error InvalidBps();

    event VestingAdded(address indexed token, address indexed beneficiary, uint256 amount, uint256 duration);
    event Claimed(address indexed token, address indexed beneficiary, uint256 amount);
    event VestingVoided(address indexed token, address indexed beneficiary, uint256 burned);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event LaunchManagerUpdated(address indexed prev, address indexed next);

    event PositionRegistered(
        address indexed token,
        uint256 indexed tokenId,
        address         feeWallet,
        address         pool,
        address         positionManager
    );
    event FeesClaimed(
        address indexed token,
        address indexed feeWallet,
        uint256 creator0,
        uint256 creator1,
        uint256 platform0,
        uint256 platform1,
        uint256 charity0,
        uint256 charity1
    );
    event PlatformWalletSet(address indexed wallet);
    event CharityWalletSet(address indexed wallet);
    event FeeBpsUpdated(uint256 creatorBps, uint256 platformBps, uint256 charityBps);

    modifier onlyOwner()         { if (msg.sender != owner)         revert NotOwner();        _; }
    modifier onlyLaunchManager() { if (msg.sender != launchManager) revert NotLaunchManager(); _; }

    constructor(address owner_, address launchManager_) {
        if (owner_         == address(0)) revert ZeroAddress();
        if (launchManager_ == address(0)) revert ZeroAddress();
        owner          = owner_;
        launchManager  = launchManager_;
        platformWallet = owner_;
        charityWallet  = owner_;
    }

    // ── Vesting ───────────────────────────────────────────────────────────────────

    function addVesting(address token, address beneficiary, uint256 amount, uint256 duration) external {
        if (msg.sender != launchManager)      revert NotLaunchManager();
        if (beneficiary == address(0))        revert ZeroAddress();
        if (amount == 0)                      revert ZeroAmount();
        if (duration < MIN_VESTING_DURATION)  revert VestingDurationTooShort();
        Schedule storage s = schedules[token][beneficiary];
        if (s.total != 0) revert AlreadySetup();
        s.total    = amount;
        s.start    = block.timestamp;
        s.duration = duration;
        emit VestingAdded(token, beneficiary, amount, duration);
    }

    function claim(address token) external {
        Schedule storage s = schedules[token][msg.sender];
        uint256 amount = _claimable(s);
        if (amount == 0) revert NothingToClaim();
        s.claimed += amount;
        bool ok = IERC20Transfer(token).transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();
        emit Claimed(token, msg.sender, amount);
    }

    function voidSchedule(address token, address beneficiary) external onlyOwner {
        Schedule storage s = schedules[token][beneficiary];
        if (s.total == 0) revert NoSchedule();
        uint256 remaining = s.total - s.claimed;
        // Zero the schedule before the external call to prevent re-entrancy.
        s.total   = 0;
        s.start   = 0;
        s.claimed = 0;
        if (remaining > 0) {
            bool ok = IERC20Transfer(token).transfer(BURN_ADDRESS, remaining);
            if (!ok) revert TransferFailed();
        }
        emit VestingVoided(token, beneficiary, remaining);
    }

    function claimable(address token, address beneficiary) external view returns (uint256) {
        return _claimable(schedules[token][beneficiary]);
    }

    function _claimable(Schedule storage s) private view returns (uint256) {
        if (s.total == 0) return 0;
        uint256 elapsed = block.timestamp - s.start;
        if (elapsed >= s.duration) return s.total - s.claimed;
        return (s.total * elapsed / s.duration) - s.claimed;
    }

    // ── LP lock + fee distribution (SparkLocker-style) ───────────────────────────

    function registerPosition(
        address token,
        uint256 tokenId,
        address feeWallet,
        address token0,
        address token1,
        address pool,
        address positionManager
    ) external onlyLaunchManager {
        if (positions[token].tokenId != 0) revert AlreadyRegistered();
        positions[token] = Position({
            tokenId:         tokenId,
            feeWallet:       feeWallet,
            token0:          token0,
            token1:          token1,
            pool:            pool,
            positionManager: positionManager
        });
        allPositionTokens.push(token);
        emit PositionRegistered(token, tokenId, feeWallet, pool, positionManager);
    }

    function claimFees(address token) external {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();
        // address(this) allowed so claimAllFees / claimFeesRange can use try this.claimFees()
        if (msg.sender != pos.feeWallet && msg.sender != owner && msg.sender != address(this))
            revert NotAuthorized();
        _collectAndDistribute(token, pos);
    }

    function claimAllFees() external onlyOwner {
        uint256 len = allPositionTokens.length;
        for (uint256 i; i < len; ++i) {
            try this.claimFees(allPositionTokens[i]) {} catch {} // skip failures, don't brick the sweep
        }
    }

    // Paginated variant of claimAllFees — use when the full list exceeds block gas limit.
    function claimFeesRange(uint256 from, uint256 to) external onlyOwner {
        uint256 len = allPositionTokens.length;
        if (to > len) to = len;
        for (uint256 i = from; i < to; ++i) {
            try this.claimFees(allPositionTokens[i]) {} catch {}
        }
    }

    function positionTokenCount() external view returns (uint256) {
        return allPositionTokens.length;
    }

    // Returns the creator's share of currently uncollected fees using V3 fee-growth math.
    function pendingCreatorFees(address token) external view returns (
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();

        token0 = pos.token0;
        token1 = pos.token1;

        (,,,,,int24 tickLower, int24 tickUpper, uint128 liquidity,
         uint256 fg0Last, uint256 fg1Last, uint128 owed0, uint128 owed1) =
            IPositionManagerCV(pos.positionManager).positions(pos.tokenId);

        if (liquidity == 0) return (token0, token1, 0, 0);

        IUniswapV3PoolFeesCV poolView = IUniswapV3PoolFeesCV(pos.pool);
        (, int24 currentTick,,,,,) = poolView.slot0();

        (uint256 fgi0, uint256 fgi1) = _feeGrowthInside(
            poolView, tickLower, tickUpper, currentTick,
            poolView.feeGrowthGlobal0X128(), poolView.feeGrowthGlobal1X128()
        );

        unchecked {
            uint256 liq = uint256(liquidity);
            amount0 = (liq * (fgi0 - fg0Last) / (1 << 128) + owed0) * creatorBps / BPS;
            amount1 = (liq * (fgi1 - fg1Last) / (1 << 128) + owed1) * creatorBps / BPS;
        }
    }

    // Standard V3 fee-growth-inside derivation; all unchecked subtraction wraps intentionally.
    function _feeGrowthInside(
        IUniswapV3PoolFeesCV pool,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint256 fgGlobal0,
        uint256 fgGlobal1
    ) private view returns (uint256 fgInside0, uint256 fgInside1) {
        (,, uint256 lo0, uint256 lo1,,,,) = pool.ticks(tickLower);
        (,, uint256 hi0, uint256 hi1,,,,) = pool.ticks(tickUpper);
        unchecked {
            uint256 below0 = currentTick >= tickLower ? lo0 : fgGlobal0 - lo0;
            uint256 above0 = currentTick <  tickUpper ? hi0 : fgGlobal0 - hi0;
            uint256 below1 = currentTick >= tickLower ? lo1 : fgGlobal1 - lo1;
            uint256 above1 = currentTick <  tickUpper ? hi1 : fgGlobal1 - hi1;
            fgInside0 = fgGlobal0 - below0 - above0;
            fgInside1 = fgGlobal1 - below1 - above1;
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return 0x150b7a02; // bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))
    }

    function _collectAndDistribute(address token, Position storage pos) private {
        (uint256 a0, uint256 a1) = IPositionManagerCV(pos.positionManager).collect(
            IPositionManagerCV.CollectParams({
                tokenId:    pos.tokenId,
                recipient:  address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        if (a0 == 0 && a1 == 0) return; // nothing to claim

        uint256 creator0;  uint256 creator1;
        uint256 platform0; uint256 platform1;
        uint256 charity0;  uint256 charity1;

        // Snapshot before external transfers — guards against re-entrancy changing bps mid-flight.
        uint256 cBps = creatorBps;
        uint256 chBps = charityBps;

        if (a0 > 0) {
            creator0  = a0 * cBps  / BPS;
            charity0  = a0 * chBps / BPS;
            platform0 = a0 - creator0 - charity0; // remainder absorbs rounding dust
            _safeTransfer(pos.token0, pos.feeWallet,  creator0);
            _safeTransfer(pos.token0, platformWallet, platform0);
            _safeTransfer(pos.token0, charityWallet,  charity0);
        }
        if (a1 > 0) {
            creator1  = a1 * cBps  / BPS;
            charity1  = a1 * chBps / BPS;
            platform1 = a1 - creator1 - charity1;
            _safeTransfer(pos.token1, pos.feeWallet,  creator1);
            _safeTransfer(pos.token1, platformWallet, platform1);
            _safeTransfer(pos.token1, charityWallet,  charity1);
        }

        emit FeesClaimed(token, pos.feeWallet, creator0, creator1, platform0, platform1, charity0, charity1);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        if (amount == 0) return; // USDT and some tokens revert on zero-amount transfer
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount) // transfer(address,uint256)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    // ── Shared admin ──────────────────────────────────────────────────────────────

    function setLaunchManager(address launchManager_) external onlyOwner {
        if (launchManager_ == address(0)) revert ZeroAddress();
        emit LaunchManagerUpdated(launchManager, launchManager_);
        launchManager = launchManager_;
    }

    function setPlatformWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        platformWallet = wallet;
        emit PlatformWalletSet(wallet);
    }

    function setCharityWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        charityWallet = wallet;
        emit CharityWalletSet(wallet);
    }

    function setFeeBps(uint256 creator_, uint256 platform_, uint256 charity_) external onlyOwner {
        if (creator_ + platform_ + charity_ != BPS) revert InvalidBps();
        creatorBps  = creator_;
        platformBps = platform_;
        charityBps  = charity_;
        emit FeeBpsUpdated(creator_, platform_, charity_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
