// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/ILaunchpadToken.sol";
import "./interfaces/IPancakeRouter02.sol";

contract BondingCurve {

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

        address pair;
        address router;

        bool    antibotEnabled;
        uint256 creationBlock;
        uint256 tradingBlock;

        bool migrated;
    }

    struct RegisterParams {
        uint256   liqTokens;
        uint256   creatorTokens;
        uint256   bcTokens;
        address   pair;
        bool      enableAntibot;
        uint256   antibotBlocks;
        address   creator;
        uint256   virtualBNB;
        uint256   migrationTarget;
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

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    address public factory;
    address public immutable deployer; // one-time right to call setFactory; no other privileges
    address public pancakeRouter;

    uint256 public platformFee;
    uint256 public charityFee;
    address public feeRecipient;
    address public charityWallet; // address(0) → charity portion redirected to feeRecipient

    // The auto-generated public getter for a 17-field struct exceeds the EVM's 16-slot
    // stack limit without viaIR. Use getToken() instead.
    mapping(address => TokenConfig) internal tokens;
    address[] public allTokens;
    mapping(address => address[]) private _tokensByCreator;

    uint256 private _totalRaisedBNB;  // sum of all active raisedBNB pools; used by rescueBNB
    uint256 private _status;

    error NotFactory();
    error Unauthorized();
    error Reentrancy();
    error ZeroAddress();
    error ZeroAmount();
    error FeeExceedsMax();
    error UnknownToken();
    error AlreadyMigrated();
    error ExceedsSoldSupply();
    error LiquidityReserveViolation();
    error InsufficientPoolBNB();
    error SlippageTooLittleBNB();
    error SlippageTooFewTokens();
    error MigrationTargetNotReached();
    error BNBTransferFailed();
    error RefundFailed();
    error AntibotBlocksOutOfRange();
    error DeadlineExpired();

    event TokenRegistered(
        address indexed token,
        address indexed creator,
        uint256         totalSupply,
        uint256         virtualBNB,
        uint256         migrationTarget
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
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event FeesUpdated(uint256 platformFee, uint256 charityFee);
    event FeeRecipientUpdated(address recipient);
    event CharityWalletUpdated(address wallet);
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(
        address router_,
        address feeRecipient_,
        uint256 platformFee_,
        uint256 charityFee_
    ) {
        if (router_       == address(0)) revert ZeroAddress();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (platformFee_ + charityFee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();

        deployer     = msg.sender;
        pancakeRouter = router_;
        feeRecipient = feeRecipient_;
        platformFee  = platformFee_;
        charityFee   = charityFee_;
        _status      = _NOT_ENTERED;
    }

    function registerToken(address token_, RegisterParams calldata p) external onlyFactory {
        if (token_ == address(0)) revert ZeroAddress();

        uint256 antibotBlocks = 0;
        if (p.enableAntibot) {
            if (p.antibotBlocks < ANTIBOT_MIN_BLOCKS || p.antibotBlocks > ANTIBOT_MAX_BLOCKS)
                revert AntibotBlocksOutOfRange();
            antibotBlocks = p.antibotBlocks;
        }

        TokenConfig storage tc = tokens[token_];
        tc.token           = token_;
        tc.creator         = p.creator;
        tc.totalSupply     = p.liqTokens + p.creatorTokens + p.bcTokens;
        tc.liquidityTokens = p.liqTokens;
        tc.creatorTokens   = p.creatorTokens;
        tc.bcTokensTotal   = p.bcTokens;
        tc.bcTokensSold    = 0;
        tc.virtualBNB      = p.virtualBNB;
        tc.k               = p.virtualBNB * p.bcTokens;
        tc.raisedBNB       = 0;
        tc.migrationTarget = p.migrationTarget;
        tc.pair            = p.pair;
        tc.router          = pancakeRouter; // snapshotted at registration; immune to future setRouter calls
        tc.antibotEnabled  = p.enableAntibot;
        tc.creationBlock   = block.number;
        tc.tradingBlock    = block.number + antibotBlocks;
        tc.migrated        = false;

        allTokens.push(token_);
        _tokensByCreator[p.creator].push(token_);

        emit TokenRegistered(token_, p.creator, tc.totalSupply, p.virtualBNB, p.migrationTarget);
    }

    function buy(address token_, uint256 minOut, uint256 deadline) external payable nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (msg.value == 0) revert ZeroAmount();
        _executeBuy(token_, msg.sender, msg.value, minOut, false);
    }

    function buyFor(address token_, address recipient, uint256 minOut)
        external payable nonReentrant onlyFactory
    {
        if (msg.value == 0) revert ZeroAmount();
        _executeBuy(token_, recipient, msg.value, minOut, false);
    }

    // skipAntibot = true and minOut = 0; called only by the factory during token creation.
    function earlyBuy(address token_, address recipient)
        external payable nonReentrant onlyFactory
    {
        if (msg.value == 0) revert ZeroAmount();
        _executeBuy(token_, recipient, msg.value, 0, true);
    }

    function sell(address token_, uint256 amountIn, uint256 minBNBOut, uint256 deadline)
        external nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();
        ILaunchpadToken(token_).transferFrom(msg.sender, address(this), amountIn);
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
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

    // Factory must transferFrom(seller → address(this)) before calling.
    function completeSell(
        address token_,
        address seller,
        uint256 amountIn,
        uint256 minBNBOut,
        uint256 deadline
    ) external nonReentrant onlyFactory {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (amountIn > tc.bcTokensSold) revert ExceedsSoldSupply();
        (uint256 fee, uint256 netBNB) = _computeSell(tc, amountIn, minBNBOut);
        uint256 raisedAfter = tc.raisedBNB;
        (bool ok,) = payable(seller).call{value: netBNB}("");
        if (!ok) revert BNBTransferFailed();
        _dispatchFee(fee);
        emit TokenSold(token_, seller, amountIn, netBNB, raisedAfter);
    }

    function migrate(address token_) external nonReentrant {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0))            revert UnknownToken();
        if (tc.migrated)                       revert AlreadyMigrated();
        if (tc.raisedBNB < tc.migrationTarget) revert MigrationTargetNotReached();
        _doMigrate(tc, token_);
    }

    function setRouter(address router_) external onlyFactory {
        if (router_ == address(0)) revert ZeroAddress();
        emit RouterUpdated(pancakeRouter, router_);
        pancakeRouter = router_;
    }

    function setFees(uint256 platformFee_, uint256 charityFee_) external onlyFactory {
        if (platformFee_ + charityFee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();
        platformFee = platformFee_;
        charityFee  = charityFee_;
        emit FeesUpdated(platformFee_, charityFee_);
    }

    function setFeeRecipient(address rec_) external onlyFactory {
        if (rec_ == address(0)) revert ZeroAddress();
        feeRecipient = rec_;
        emit FeeRecipientUpdated(rec_);
    }

    function setCharityWallet(address wallet_) external onlyFactory {
        charityWallet = wallet_;
        emit CharityWalletUpdated(wallet_);
    }

    function setFactory(address factory_) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (factory_ == address(0)) revert ZeroAddress();
        emit FactoryUpdated(factory, factory_);
        factory = factory_;
    }

    function rescueBNB(address to) external onlyFactory {
        if (to == address(0)) revert ZeroAddress();
        if (address(this).balance <= _totalRaisedBNB) revert ZeroAmount();
        _safeSendBNB(to, address(this).balance - _totalRaisedBNB);
    }

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
        BuyResult memory r = _calcBuy(tc, bnbIn, minOut);
        _dispatchFee(r.fee);
        _finalizeBuy(tc, token_, buyer, skipAntibot, r);
    }

    function _calcBuy(
        TokenConfig storage tc,
        uint256 bnbIn,
        uint256 minOut
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
        TokenConfig storage tc,
        address token_,
        address buyer,
        bool    skipAntibot,
        BuyResult memory r
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
            _doMigrate(tc, token_);
        }
    }

    function _doMigrate(TokenConfig storage tc, address token_) internal {
        tc.migrated = true;

        uint256 migrationBNB = tc.raisedBNB;
        uint256 liqTokens    = tc.liquidityTokens;

        // bcTokensSold accounting ensures this holds, but assert explicitly as a safety net.
        if (ILaunchpadToken(token_).balanceOf(address(this)) < liqTokens)
            revert LiquidityReserveViolation();

        if (migrationBNB >= _totalRaisedBNB) _totalRaisedBNB = 0;
        else                                 _totalRaisedBNB -= migrationBNB;

        address pair_ = tc.pair;

        {
            address router_ = tc.router;
            ILaunchpadToken(token_).approve(router_, liqTokens);
            // LP tokens sent to dead wallet — permanently locked.
            // 99 % minimums protect against pre-seeded pair sandwich attacks.
            IPancakeRouter02(router_).addLiquidityETH{value: migrationBNB}(
                token_, liqTokens,
                liqTokens    * 9900 / 10000,
                migrationBNB * 9900 / 10000,
                DEAD, block.timestamp + 300
            );
        }

        ILaunchpadToken(token_).postMigrateSetup();

        // Should be zero after the migration-cap buy, but handles a direct migrate() call.
        uint256 unsold = tc.bcTokensTotal - tc.bcTokensSold;
        if (unsold > 0) ILaunchpadToken(token_).transfer(DEAD, unsold);

        tc.raisedBNB = 0;
        emit TokenMigrated(token_, pair_, migrationBNB, liqTokens);
    }

    function _computeSell(
        TokenConfig storage tc,
        uint256 amountIn,
        uint256 minBNBOut
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

    receive() external payable {}
}
