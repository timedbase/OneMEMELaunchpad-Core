// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IPositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
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

interface IUniswapV3PoolFees {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16  observationCardinality, uint16 observationCardinalityNext,
        uint8   feeProtocol, bool unlocked
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

contract SparkLocker {

    error NotOwner();
    error NotLauncher();
    error NotAuthorized();
    error ZeroAddress();
    error AlreadyRegistered();
    error UnknownToken();
    error TransferFailed();
    error InvalidBps();

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

    address public owner;
    address public launcher;
    address public platformWallet;
    address public charityWallet;

    mapping(address => Position) public positions; // launched token → locked position
    address[] public allTokens;

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
    event LauncherSet(address indexed launcher);
    event PlatformWalletSet(address indexed wallet);
    event CharityWalletSet(address indexed wallet);
    event FeeBpsUpdated(uint256 creatorBps, uint256 platformBps, uint256 charityBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 tokenId);

    modifier onlyOwner()    { if (msg.sender != owner)    revert NotOwner();    _; }
    modifier onlyLauncher() { if (msg.sender != launcher) revert NotLauncher(); _; }

    constructor(address platformWallet_, address charityWallet_) {
        if (platformWallet_ == address(0)) revert ZeroAddress();
        if (charityWallet_  == address(0)) revert ZeroAddress();
        owner          = msg.sender;
        platformWallet = platformWallet_;
        charityWallet  = charityWallet_;
    }

    function setLauncher(address launcher_) external onlyOwner {
        if (launcher_ == address(0)) revert ZeroAddress();
        launcher = launcher_;
        emit LauncherSet(launcher_);
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

    function setFeeBps(uint256 creator_, uint256 platform_, uint256 charity_)
        external onlyOwner
    {
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

    function registerPosition(
        address token,
        uint256 tokenId,
        address feeWallet,
        address token0,
        address token1,
        address pool,
        address positionManager
    ) external onlyLauncher {
        if (positions[token].tokenId != 0) revert AlreadyRegistered();
        positions[token] = Position({
            tokenId:         tokenId,
            feeWallet:       feeWallet,
            token0:          token0,
            token1:          token1,
            pool:            pool,
            positionManager: positionManager
        });
        allTokens.push(token);
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
        uint256 len = allTokens.length;
        for (uint256 i; i < len; ++i) {
            try this.claimFees(allTokens[i]) {} catch {} // skip failures, don't brick the sweep
        }
    }

    // Paginated variant of claimAllFees — use when the full list exceeds block gas limit.
    function claimFeesRange(uint256 from, uint256 to) external onlyOwner {
        uint256 len = allTokens.length;
        if (to > len) to = len;
        for (uint256 i = from; i < to; ++i) {
            try this.claimFees(allTokens[i]) {} catch {}
        }
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function emergencyWithdraw(address token) external onlyOwner {
        Position storage pos = positions[token];
        if (pos.tokenId == 0) revert UnknownToken();
        uint256 tokenId         = pos.tokenId;
        address positionManager = pos.positionManager;
        delete positions[token]; // clears tokenId so fee-claim loops skip gracefully
        IPositionManager(positionManager).safeTransferFrom(address(this), platformWallet, tokenId);
        emit EmergencyWithdraw(token, platformWallet, tokenId);
    }

    // Returns the creator's share of currently uncollected fees using V3 fee-growth math.
    // See SPARK.md → "Pending Fee Formula" for derivation.
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
            IPositionManager(pos.positionManager).positions(pos.tokenId);

        if (liquidity == 0) return (token0, token1, 0, 0);

        IUniswapV3PoolFees poolView = IUniswapV3PoolFees(pos.pool);
        (, int24 currentTick,,,,,) = poolView.slot0();

        // Pass fgGlobal values inline to avoid two extra stack slots.
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
        IUniswapV3PoolFees pool,
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
        (uint256 a0, uint256 a1) = IPositionManager(pos.positionManager).collect(
            IPositionManager.CollectParams({
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
}
