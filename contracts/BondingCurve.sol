// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/ILaunchpadToken.sol";
import "./interfaces/IPancakeRouter02.sol";

/**
 * @title BondingCurve — OneMEME
 * @notice Holds all bonding-curve state and executes buy / sell / migrate for every token
 *         launched through the LaunchpadFactory.
 *
 *         Tokens are minted directly to this contract at launch time (their `factory`
 *         field is set to address(this)), so this contract can call setupVesting() and
 *         postMigrateSetup() on the token contracts.
 *
 * ─── Trading paths ─────────────────────────────────────────────────────────
 *   Direct (user → BondingCurve):
 *     buy(token, minOut, deadline)          — user pays BNB, receives tokens
 *     sell(token, amountIn, minBNB, dl)     — user approves BondingCurve, receives BNB
 *     migrate(token)                        — permissionless once target reached
 *
 *   Routed (user → LaunchpadFactory → BondingCurve):
 *     buyFor(token, recipient, minOut)      — factory checked deadline; factory-only
 *     completeSell(token, seller, ...)      — factory transferred tokens first; factory-only
 *     earlyBuy(token, recipient)            — antibot-exempt; factory-only (creation only)
 *
 * ─── Admin ─────────────────────────────────────────────────────────────────
 *   All state-mutating admin functions are onlyFactory — the LaunchpadFactory is the
 *   sole authority, and its owner uses timelocked pass-through calls.
 *   The factory address itself is updatable (setFactory) to support factory upgrades.
 */
contract BondingCurve {

    // ─────────────────────────────────────────────────────────────────────
    // TYPES
    // ─────────────────────────────────────────────────────────────────────

    struct TokenConfig {
        address   token;
        address   creator;

        uint256 totalSupply;
        uint256 liquidityTokens;   // 38 % — added to DEX at migration
        uint256 creatorTokens;     // 5 % or 0 — linearly vested
        uint256 bcTokensTotal;     // remainder — tradeable on the bonding curve
        uint256 bcTokensSold;

        uint256 virtualBNB;        // virtual BNB seeded at launch
        uint256 k;                 // constant-product invariant: virtualBNB × bcTokensTotal
        uint256 raisedBNB;         // real BNB raised so far
        uint256 migrationTarget;   // real BNB target that triggers DEX migration

        address pair;              // PancakeSwap pair — created at launch for TAX/RFL
        address router;            // router snapshotted at registration; used for migration

        bool    antibotEnabled;
        uint256 creationBlock;
        uint256 tradingBlock;      // creationBlock + antibotBlocks

        bool migrated;
    }

    /// @dev Passed by the factory to registerToken().
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

    /// @dev Packed outputs from _calcBuy — one memory pointer keeps each frame stack-safe.
    struct BuyResult {
        uint256 refund;
        uint256 fee;
        uint256 tokensOut;
        uint256 netBNBIn;  // bnbIn − refund; actual BNB consumed, used in the TokenBought emit
    }

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────

    uint256 private constant BPS_DENOM          = 10_000;
    uint256 private constant MAX_TOTAL_FEE      =    250; // 2.5 %
    uint256 private constant ANTIBOT_MIN_BLOCKS =     10;
    uint256 private constant ANTIBOT_MAX_BLOCKS =    199;
    address private constant DEAD               = 0x000000000000000000000000000000000000dEaD;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    // ─────────────────────────────────────────────────────────────────────
    // STATE
    // ─────────────────────────────────────────────────────────────────────

    address public factory;
    address public pancakeRouter;

    uint256 public platformFee;   // bps — goes to feeRecipient
    uint256 public charityFee;    // bps — goes to charityWallet
    address public feeRecipient;
    address public charityWallet; // address(0) → charity portion redirected to feeRecipient

    // internal: the auto-generated public getter for a 17-field struct exceeds the
    // EVM's 16-slot stack limit without viaIR. Use getToken() instead.
    mapping(address => TokenConfig) internal tokens;
    address[] public allTokens;
    mapping(address => address[]) private _tokensByCreator;

    uint256 private _totalRaisedBNB;  // sum of all active tc.raisedBNB; used by rescueBNB
    uint256 private _status;

    // ─────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────

    error NotFactory();
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

    // ─────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────

    constructor(
        address factory_,
        address router_,
        address feeRecipient_,
        uint256 platformFee_,
        uint256 charityFee_
    ) {
        if (factory_      == address(0)) revert ZeroAddress();
        if (router_       == address(0)) revert ZeroAddress();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (platformFee_ + charityFee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();

        factory      = factory_;
        pancakeRouter = router_;
        feeRecipient = feeRecipient_;
        platformFee  = platformFee_;
        charityFee   = charityFee_;
        _status      = _NOT_ENTERED;
    }

    // ─────────────────────────────────────────────────────────────────────
    // REGISTRATION
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Register a newly cloned token with the bonding curve.
     *         Called by the factory after initForLaunchpad and after the factory
     *         has transferred (liqTokens + bcTokens) to this contract.
     */
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
        tc.router          = pancakeRouter; // snapshot at registration — immune to future changes
        tc.antibotEnabled  = p.enableAntibot;
        tc.creationBlock   = block.number;
        tc.tradingBlock    = block.number + antibotBlocks;
        tc.migrated        = false;

        allTokens.push(token_);
        _tokensByCreator[p.creator].push(token_);

        emit TokenRegistered(token_, p.creator, tc.totalSupply, p.virtualBNB, p.migrationTarget);
    }

    // ─────────────────────────────────────────────────────────────────────
    // BUY — direct
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Buy tokens on the bonding curve.
     * @param token_   Token address (must not be migrated)
     * @param minOut   Minimum tokens to receive (slippage guard)
     * @param deadline Unix timestamp after which the call reverts
     */
    function buy(address token_, uint256 minOut, uint256 deadline) external payable nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (msg.value == 0) revert ZeroAmount();
        _executeBuy(token_, msg.sender, msg.value, minOut, false);
    }

    // ─────────────────────────────────────────────────────────────────────
    // BUY — factory-routed
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Factory-proxied buy.  The factory validates deadline before calling.
     *         Sends tokens to `recipient` (the original msg.sender on the factory).
     */
    function buyFor(address token_, address recipient, uint256 minOut)
        external payable nonReentrant onlyFactory
    {
        if (msg.value == 0) revert ZeroAmount();
        _executeBuy(token_, recipient, msg.value, minOut, false);
    }

    /**
     * @notice Antibot-exempt early buy — called only by the factory during token creation.
     *         Passes skipAntibot = true and minOut = 0.
     */
    function earlyBuy(address token_, address recipient)
        external payable nonReentrant onlyFactory
    {
        if (msg.value == 0) revert ZeroAmount();
        _executeBuy(token_, recipient, msg.value, 0, true);
    }

    // ─────────────────────────────────────────────────────────────────────
    // SELL — direct
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Sell tokens back to the bonding curve for BNB.
     *         Caller must have approved this contract for `amountIn` tokens.
     *         Peak stack: 9 slots (token_/amountIn/minBNBOut/deadline/tc/fee/netBNB/raisedAfter/ok).
     */
    function sell(address token_, uint256 amountIn, uint256 minBNBOut, uint256 deadline)
        external nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();
        ILaunchpadToken(token_).transferFrom(msg.sender, address(this), amountIn);
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        // Liquidity-reserve guard: only tokens that were previously bought can be sold back.
        // liquidityTokens are held by this contract but are never part of the BC pool,
        // so bcTokensSold can never include them — they are always reserved for migration.
        if (amountIn > tc.bcTokensSold) revert ExceedsSoldSupply();
        (uint256 fee, uint256 netBNB) = _computeSell(tc, amountIn, minBNBOut);
        uint256 raisedAfter = tc.raisedBNB;
        (bool ok,) = payable(msg.sender).call{value: netBNB}("");
        if (!ok) revert BNBTransferFailed();
        _dispatchFee(fee);
        emit TokenSold(token_, msg.sender, amountIn, netBNB, raisedAfter);
    }

    // ─────────────────────────────────────────────────────────────────────
    // SELL — factory-routed
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Complete a sell initiated by the factory.
     *         The factory must have already transferred `amountIn` tokens to this contract
     *         via transferFrom(seller → address(this)) before calling.
     *         Peak stack: 10 slots (token_/seller/amountIn/minBNBOut/deadline/tc/fee/netBNB/raisedAfter/ok).
     */
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
        // Liquidity-reserve guard: mirrors sell() — only previously-bought tokens accepted.
        if (amountIn > tc.bcTokensSold) revert ExceedsSoldSupply();
        (uint256 fee, uint256 netBNB) = _computeSell(tc, amountIn, minBNBOut);
        uint256 raisedAfter = tc.raisedBNB;
        (bool ok,) = payable(seller).call{value: netBNB}("");
        if (!ok) revert BNBTransferFailed();
        _dispatchFee(fee);
        emit TokenSold(token_, seller, amountIn, netBNB, raisedAfter);
    }

    // ─────────────────────────────────────────────────────────────────────
    // MIGRATE
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
    // ADMIN — onlyFactory
    // ─────────────────────────────────────────────────────────────────────

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

    /// @notice Update the factory address — used when the LaunchpadFactory itself is upgraded.
    function setFactory(address factory_) external onlyFactory {
        if (factory_ == address(0)) revert ZeroAddress();
        emit FactoryUpdated(factory, factory_);
        factory = factory_;
    }

    /// @notice Sweep stray BNB (anything above the sum of all active raisedBNB pools).
    function rescueBNB(address to) external onlyFactory {
        if (to == address(0)) revert ZeroAddress();
        if (address(this).balance <= _totalRaisedBNB) revert ZeroAmount();
        _safeSendBNB(to, address(this).balance - _totalRaisedBNB);
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL — BUY
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Entry point shared by buy(), buyFor(), and earlyBuy().
     *      Split into _calcBuy + _finalizeBuy so each frame stays well under
     *      the EVM's 16-slot stack limit without requiring viaIR.
     *      Peak stack here: 7 slots (5 params + tc + r).
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
        BuyResult memory r = _calcBuy(tc, bnbIn, minOut);
        _dispatchFee(r.fee);
        _finalizeBuy(tc, token_, buyer, skipAntibot, r);
    }

    /**
     * @dev AMM math: computes fee, tokensOut, refund and updates tc state.
     *      Peak stack: 9 slots (3 params + r + poolBNB + poolTokens + totalFee + grossNeeded + netBNB).
     */
    function _calcBuy(
        TokenConfig storage tc,
        uint256 bnbIn,
        uint256 minOut
    ) private returns (BuyResult memory r) {
        uint256 poolBNB    = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        uint256 totalFee   = platformFee + charityFee;
        // grossNeeded = gross BNB required to hit the migration target exactly.
        // Ceiling division ensures net amount covers the target after fee deduction.
        uint256 grossNeeded = totalFee == 0
            ? tc.migrationTarget - tc.raisedBNB
            : ((tc.migrationTarget - tc.raisedBNB) * BPS_DENOM
                + (BPS_DENOM - totalFee) - 1)
              / (BPS_DENOM - totalFee);
        uint256 netBNB;

        if (bnbIn >= grossNeeded) {
            // Migration-cap: sell ALL remaining BC tokens, refund excess BNB.
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
        // Hard guard: tokensOut must never exceed the BC pool — liquidity tokens are not for sale.
        if (r.tokensOut > poolTokens) revert LiquidityReserveViolation();

        tc.raisedBNB    += netBNB;
        _totalRaisedBNB += netBNB;
        tc.bcTokensSold += r.tokensOut;
    }

    /**
     * @dev Settlement: antibot burn, token transfers, BNB refund, emit, auto-migrate.
     *      Peak stack: 9 slots (5 params + tokensToDead + remaining + totalBlocks + penaltyBPS).
     */
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
                // Ceiling: penalty decreases slightly slower, preventing bots from
                // exploiting floor rounding at the boundary block.
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

        // Auto-migrate as soon as the target is met — no separate call required.
        if (!tc.migrated && tc.raisedBNB >= tc.migrationTarget) {
            _doMigrate(tc, token_);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL — MIGRATE
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Seed DEX liquidity, burn unsold BC tokens, and call postMigrateSetup on the token.
    function _doMigrate(TokenConfig storage tc, address token_) internal {
        tc.migrated = true;

        uint256 migrationBNB = tc.raisedBNB;
        uint256 liqTokens    = tc.liquidityTokens;

        // Invariant: this contract must hold at least liqTokens at migration.
        // bcTokensSold accounting guarantees this (only bought tokens can be sold back,
        // and liquidityTokens are never part of the BC pool), but we assert explicitly.
        if (ILaunchpadToken(token_).balanceOf(address(this)) < liqTokens)
            revert LiquidityReserveViolation();

        if (migrationBNB >= _totalRaisedBNB) _totalRaisedBNB = 0;
        else                                 _totalRaisedBNB -= migrationBNB;

        address pair_ = tc.pair;

        {   // Scope: router_ freed after addLiquidityETH; minimums inlined to save slots.
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

        // Exit bonding phase on all token types (no-op on StandardToken).
        ILaunchpadToken(token_).postMigrateSetup();

        // Burn any unsold BC tokens — should be zero via migration-cap guarantee,
        // but handles edge cases such as a direct migrate() call.
        uint256 unsold = tc.bcTokensTotal - tc.bcTokensSold;
        if (unsold > 0) ILaunchpadToken(token_).transfer(DEAD, unsold);

        tc.raisedBNB = 0;
        emit TokenMigrated(token_, pair_, migrationBNB, liqTokens);
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL — SELL
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev AMM sell math + state update, shared by sell() and completeSell().
     *      Two call sites prevent optimizer inlining; peak stack: 9 slots
     *      (tc/amountIn/minBNBOut + fee/netBNB returns + poolBNB/newPoolToks/newPoolBNB/grossBNB).
     *      totalFee reuses a slot after grossBNB is consumed.
     */
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

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL — FEE DISPATCH
    // ─────────────────────────────────────────────────────────────────────

    function _dispatchFee(uint256 amount) private {
        if (amount == 0) return;
        uint256 cFee    = charityFee;
        uint256 total   = cFee + platformFee;
        address charity = charityWallet;
        if (charity != address(0) && cFee > 0 && total > 0) {
            uint256 charityAmt = (amount * cFee + total - 1) / total; // ceiling — charity exact share
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

    /**
     * @notice Tokens received for a given BNB input (after trade fee).
     *         Accounts for the migration cap.
     */
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

    /**
     * @notice BNB received for selling a given token amount (after trade fee).
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
        uint256 newPoolBNB  = (tc.k + newPoolToks - 1) / newPoolToks;
        uint256 grossBNB    = poolBNB > newPoolBNB ? poolBNB - newPoolBNB : 0;
        if (grossBNB > tc.raisedBNB) return (0, 0);
        uint256 totalFee    = platformFee + charityFee;
        feeBNB = totalFee == 0 ? 0 : (grossBNB * totalFee + BPS_DENOM - 1) / BPS_DENOM;
        bnbOut = grossBNB - feeBNB;
    }

    /// @notice Spot price: BNB per whole token (×1e18).
    function getSpotPrice(address token_) external view returns (uint256 price) {
        TokenConfig storage tc = tokens[token_];
        if (tc.token == address(0)) revert UnknownToken();
        uint256 poolBNB    = tc.virtualBNB + tc.raisedBNB;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        if (poolTokens == 0) return type(uint256).max;
        price = (poolBNB * 1e18) / poolTokens;
    }

    /// @notice Returns the full TokenConfig for a registered token as a memory struct.
    ///         (The mapping is internal; this replaces the auto-generated public getter
    ///          which would overflow the stack without viaIR due to the 17-field struct.)
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
