// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/ILaunchpadToken.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./tokens/StandardToken.sol";
import "./tokens/TaxToken.sol";
import "./tokens/ReflectionToken.sol";
import "./BondingCurve.sol";

/**
 * @title LaunchpadFactory — OneMEME
 * @notice Creates meme-token clones (Standard / Tax / Reflection) and registers them
 *         with the BondingCurve contract where all trading state lives.
 *
 * ─── Separation of concerns ────────────────────────────────────────────────
 *   LaunchpadFactory  —  token creation, clone deployment, owner/manager admin,
 *                        default bonding-curve parameters, creation-fee collection,
 *                        timelocked updates to BondingCurve configuration,
 *                        convenience buy/sell/migrate pass-throughs.
 *
 *   BondingCurve      —  all per-token AMM state, buy/sell/migrate execution,
 *                        trade-fee collection and dispatch, DEX migration.
 *
 * ─── Token creation ────────────────────────────────────────────────────────
 *   initForLaunchpad is called with factory_ = address(bondingCurve) so the token
 *   mints its entire supply directly to BondingCurve.  The token's onlyFactory
 *   modifier then permits BondingCurve to call setupVesting() and postMigrateSetup().
 *
 * ─── Trading pass-throughs ─────────────────────────────────────────────────
 *   factory.buy()   → bondingCurve.buyFor()       (factory checks deadline)
 *   factory.sell()  → token.transferFrom + bondingCurve.completeSell()
 *   factory.migrate() → bondingCurve.migrate()
 *   Users may also interact with BondingCurve directly.
 *   For direct sells, users approve BondingCurve (not Factory).
 *   For factory-routed sells, users approve Factory (Factory transfers to BC).
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
 * ─── Vanity addresses ─────────────────────────────────────────────────────
 *   Every clone is deployed via CREATE2 with a user-provided salt bound to
 *   msg.sender.  The resulting address must end in 0x1111.
 *   Mine off-chain: predictTokenAddress(creator, salt, impl) until match.
 */
contract LaunchpadFactory {

    // ─────────────────────────────────────────────────────────────────────
    // TYPES
    // ─────────────────────────────────────────────────────────────────────

    enum SupplyOption { ONE, THOUSAND, MILLION, BILLION }

    struct Alloc {
        uint256 supply;
        uint256 liqTokens;
        uint256 creatorTokens;
        uint256 bcTokens;
    }

    struct BaseParams {
        string       name;
        string       symbol;
        SupplyOption supplyOption;
        bool         enableCreatorAlloc;
        bool         enableAntibot;
        uint256      antibotBlocks;    // 10 – 199; ignored if antibot disabled
        string       metaURI;
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
    }

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────

    uint256 private constant LIQUIDITY_BPS = 3800;
    uint256 private constant CREATOR_BPS   =  500;
    uint256 private constant BPS_DENOM     = 10_000;
    uint256 private constant MAX_TOTAL_FEE =  250;  // 2.5 %

    /// @notice Suggested default creation fee: 0.0011 BNB.
    uint256 public  constant DEFAULT_CREATION_FEE = 0.0011 ether;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    // ─────────────────────────────────────────────────────────────────────
    // STATE
    // ─────────────────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;
    mapping(address => bool) public managers;

    address public immutable standardImpl;
    address public immutable taxImpl;
    address public immutable reflectionImpl;

    BondingCurve public immutable bondingCurve;

    uint256 public creationFee;            // BNB wei — collected at token creation
    uint256 public defaultVirtualBNB;      // BNB wei — passed to BondingCurve at registration
    uint256 public defaultMigrationTarget; // BNB wei — passed to BondingCurve at registration

    uint256 private _status;

    // ─── Timelock ─────────────────────────────────────────────────────────
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    bytes32 public constant TL_SET_ROUTER         = keccak256("SET_ROUTER");
    bytes32 public constant TL_SET_PLATFORM_FEE   = keccak256("SET_PLATFORM_FEE");
    bytes32 public constant TL_SET_CHARITY_FEE    = keccak256("SET_CHARITY_FEE");
    bytes32 public constant TL_SET_FEE_RECIPIENT  = keccak256("SET_FEE_RECIPIENT");
    bytes32 public constant TL_SET_CHARITY_WALLET = keccak256("SET_CHARITY_WALLET");

    mapping(bytes32 => uint256) public timelockExpiry;

    address private _pendingRouter;
    uint256 private _pendingPlatformFee;
    uint256 private _pendingCharityFee;
    address private _pendingFeeRecipient;
    address private _pendingCharityWallet;

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
    error CloneFailed();
    error VanityAddressRequired();
    error BNBTransferFailed();
    error DeadlineExpired();
    error TimelockNotQueued();
    error TimelockNotExpired();
    error ParamOutOfRange();

    // ─────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────

    event TokenCreated(
        address indexed token,
        address indexed creator,
        uint256         totalSupply,
        uint256         virtualBNB,
        uint256         migrationTarget,
        bool            antibotEnabled,
        uint256         tradingBlock
    );
    event DefaultParamsUpdated(uint256 oldVirtualBNB, uint256 newVirtualBNB, uint256 oldMigrationTarget, uint256 newMigrationTarget);
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event FeeRecipientUpdated(address recipient);
    event CharityWalletUpdated(address wallet);
    event PlatformFeeUpdated(uint256 feeBps);
    event CharityFeeUpdated(uint256 feeBps);
    event ManagerAdded(address indexed manager);
    event ManagerRemoved(address indexed manager);
    event OwnershipTransferProposed(address indexed current, address indexed proposed);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event TimelockQueued(bytes32 indexed actionId, uint256 executeAfter);
    event TimelockExecuted(bytes32 indexed actionId);
    event TimelockCancelled(bytes32 indexed actionId);

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
     * @param bondingCurve_           Deployed BondingCurve contract
     * @param creationFee_            Token creation fee in BNB wei
     * @param defaultVirtualBNB_      Default virtual BNB seeded into bonding curve
     * @param defaultMigrationTarget_ Default BNB raise target before DEX migration
     * @param standardImpl_           Deployed StandardToken implementation
     * @param taxImpl_                Deployed TaxToken implementation
     * @param reflectionImpl_         Deployed ReflectionToken implementation
     */
    constructor(
        address bondingCurve_,
        uint256 creationFee_,
        uint256 defaultVirtualBNB_,
        uint256 defaultMigrationTarget_,
        address standardImpl_,
        address taxImpl_,
        address reflectionImpl_
    ) {
        if (bondingCurve_           == address(0)) revert ZeroAddress();
        if (defaultVirtualBNB_      == 0)          revert ZeroAmount();
        if (defaultMigrationTarget_ == 0)          revert ZeroAmount();
        if (standardImpl_           == address(0)) revert ZeroAddress();
        if (taxImpl_                == address(0)) revert ZeroAddress();
        if (reflectionImpl_         == address(0)) revert ZeroAddress();

        owner                  = msg.sender;
        bondingCurve           = BondingCurve(payable(bondingCurve_));
        creationFee            = creationFee_;
        defaultVirtualBNB      = defaultVirtualBNB_;
        defaultMigrationTarget = defaultMigrationTarget_;
        _status                = _NOT_ENTERED;

        standardImpl   = standardImpl_;
        taxImpl        = taxImpl_;
        reflectionImpl = reflectionImpl_;
    }

    // ─────────────────────────────────────────────────────────────────────
    // TOKEN CREATION
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a Standard ERC-20 token and register it with the BondingCurve.
     *         msg.value must cover the creation fee.  Any excess is used as an
     *         antibot-exempt early buy executed atomically on the bonding curve.
     */
    function createToken(BaseParams memory p) external payable nonReentrant returns (address token) {
        BondingCurve bc  = bondingCurve;
        uint256 earlyBuy = _collectCreationFee(bc);
        token = _cloneCreate2(standardImpl, p.salt);

        uint256 tradingBlock_;
        {
            Alloc memory a = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);
            // Mints entire supply to this factory; factory and bc are both exempt from fees.
            StandardToken(payable(token)).initForLaunchpad(
                p.name, p.symbol, a.supply, address(this), address(bc), msg.sender, p.metaURI
            );
            _sendToBondingCurve(token, address(bc), a);
            _registerWithCurve(bc, token, address(0), a, p.enableAntibot, p.antibotBlocks);
            tradingBlock_ = p.enableAntibot ? block.number + p.antibotBlocks : block.number;
            emit TokenCreated(token, msg.sender, a.supply,
                defaultVirtualBNB, defaultMigrationTarget, p.enableAntibot, tradingBlock_);
        }

        if (earlyBuy > 0) bc.earlyBuy{value: earlyBuy}(token, msg.sender);
    }

    /**
     * @notice Create a Tax Token and register it with the BondingCurve.
     *         Taxes start at 0 — configure via the token's setBuyTaxes / setSellTaxes.
     */
    function createTT(CreateTTParams memory p) external payable nonReentrant returns (address payable token) {
        BondingCurve bc  = bondingCurve;
        uint256 earlyBuy = _collectCreationFee(bc);
        token = payable(_cloneCreate2(taxImpl, p.salt));

        uint256 tradingBlock_;
        {
            Alloc memory a  = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);
            TaxToken(token).initForLaunchpad(
                p.name, p.symbol, a.supply, address(this), address(bc), msg.sender, p.metaURI,
                bc.pancakeRouter()
            );
            _sendToBondingCurve(token, address(bc), a);
            _registerWithCurve(bc, token, TaxToken(token).pancakePair(), a, p.enableAntibot, p.antibotBlocks);
            tradingBlock_ = p.enableAntibot ? block.number + p.antibotBlocks : block.number;
            emit TokenCreated(token, msg.sender, a.supply,
                defaultVirtualBNB, defaultMigrationTarget, p.enableAntibot, tradingBlock_);
        }

        if (earlyBuy > 0) bc.earlyBuy{value: earlyBuy}(token, msg.sender);
    }

    /**
     * @notice Create a Reflection Token and register it with the BondingCurve.
     *         Taxes and reflection token start at 0 — configure post-deployment.
     */
    function createRFL(CreateRFLParams memory p) external payable nonReentrant returns (address payable token) {
        BondingCurve bc  = bondingCurve;
        uint256 earlyBuy = _collectCreationFee(bc);
        token = payable(_cloneCreate2(reflectionImpl, p.salt));

        uint256 tradingBlock_;
        {
            Alloc memory a  = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);
            ReflectionToken(token).initForLaunchpad(
                p.name, p.symbol, a.supply, address(this), address(bc), msg.sender, p.metaURI,
                bc.pancakeRouter()
            );
            _sendToBondingCurve(token, address(bc), a);
            _registerWithCurve(bc, token, ReflectionToken(token).pancakePair(), a, p.enableAntibot, p.antibotBlocks);
            tradingBlock_ = p.enableAntibot ? block.number + p.antibotBlocks : block.number;
            emit TokenCreated(token, msg.sender, a.supply,
                defaultVirtualBNB, defaultMigrationTarget, p.enableAntibot, tradingBlock_);
        }

        if (earlyBuy > 0) bc.earlyBuy{value: earlyBuy}(token, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────
    // PASS-THROUGH TRADING
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Buy tokens via the bonding curve (factory-routed).
     *         Users may also call BondingCurve.buy() directly.
     */
    function buy(address token_, uint256 minOut, uint256 deadline) external payable nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (msg.value == 0) revert ZeroAmount();
        bondingCurve.buyFor{value: msg.value}(token_, msg.sender, minOut);
    }

    /**
     * @notice Sell tokens via the bonding curve (factory-routed).
     *         Caller must approve THIS contract for `amountIn` tokens.
     *         For direct sells, approve BondingCurve and call BondingCurve.sell() directly.
     */
    function sell(address token_, uint256 amountIn, uint256 minBNBOut, uint256 deadline)
        external nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();
        address bc = address(bondingCurve);
        ILaunchpadToken(token_).transferFrom(msg.sender, bc, amountIn);
        BondingCurve(payable(bc)).completeSell(token_, msg.sender, amountIn, minBNBOut, deadline);
    }

    /// @notice Trigger DEX migration for a completed bonding curve.  Permissionless.
    function migrate(address token_) external {
        bondingCurve.migrate(token_);
    }

    // ─────────────────────────────────────────────────────────────────────
    // ADMIN — DEFAULT PARAMS
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Update the default bonding-curve parameters for future launches.
    function setDefaultParams(uint256 virtualBNB_, uint256 migrationTarget_) external onlyOwnerOrManager {
        if (virtualBNB_      == 0) revert ZeroAmount();
        if (migrationTarget_ == 0) revert ZeroAmount();
        if (virtualBNB_      > 10_000 ether)  revert ParamOutOfRange();
        if (migrationTarget_ > 100_000 ether) revert ParamOutOfRange();
        emit DefaultParamsUpdated(defaultVirtualBNB, virtualBNB_, defaultMigrationTarget, migrationTarget_);
        defaultVirtualBNB      = virtualBNB_;
        defaultMigrationTarget = migrationTarget_;
    }

    /// @notice Set the token creation fee in BNB wei.  May be set to zero.
    function setCreationFee(uint256 fee_) external onlyOwner {
        emit CreationFeeUpdated(creationFee, fee_);
        creationFee = fee_;
    }

    // ─────────────────────────────────────────────────────────────────────
    // ADMIN — TIMELOCKED BONDING CURVE CONFIG
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Propose a new PancakeSwap router.  Execute after 48 h.
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
        emit RouterUpdated(bondingCurve.pancakeRouter(), _pendingRouter);
        bondingCurve.setRouter(_pendingRouter);
    }

    /// @notice Propose a new platform fee (bps).  Execute after 48 h.
    function proposeSetPlatformFee(uint256 fee_) external onlyOwner {
        if (fee_ + bondingCurve.charityFee() > MAX_TOTAL_FEE) revert FeeExceedsMax();
        _pendingPlatformFee = fee_;
        _queueAction(TL_SET_PLATFORM_FEE);
    }

    function executeSetPlatformFee() external onlyOwner {
        _consumeAction(TL_SET_PLATFORM_FEE);
        uint256 pf = _pendingPlatformFee;
        if (pf + bondingCurve.charityFee() > MAX_TOTAL_FEE) revert FeeExceedsMax();
        bondingCurve.setFees(pf, bondingCurve.charityFee());
        emit PlatformFeeUpdated(pf);
    }

    /// @notice Propose a new charity fee (bps).  Execute after 48 h.
    function proposeSetCharityFee(uint256 fee_) external onlyOwner {
        if (bondingCurve.platformFee() + fee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();
        _pendingCharityFee = fee_;
        _queueAction(TL_SET_CHARITY_FEE);
    }

    function executeSetCharityFee() external onlyOwner {
        _consumeAction(TL_SET_CHARITY_FEE);
        uint256 cf = _pendingCharityFee;
        if (bondingCurve.platformFee() + cf > MAX_TOTAL_FEE) revert FeeExceedsMax();
        bondingCurve.setFees(bondingCurve.platformFee(), cf);
        emit CharityFeeUpdated(cf);
    }

    /// @notice Propose a new fee recipient.  Execute after 48 h.
    function proposeSetFeeRecipient(address rec_) external onlyOwner {
        if (rec_ == address(0)) revert ZeroAddress();
        _pendingFeeRecipient = rec_;
        _queueAction(TL_SET_FEE_RECIPIENT);
    }

    function executeSetFeeRecipient() external onlyOwner {
        _consumeAction(TL_SET_FEE_RECIPIENT);
        bondingCurve.setFeeRecipient(_pendingFeeRecipient);
        emit FeeRecipientUpdated(_pendingFeeRecipient);
    }

    /**
     * @notice Propose a new charity wallet.  Execute after 48 h.
     *         Propose address(0) to redirect the charity portion to feeRecipient.
     */
    function proposeSetCharityWallet(address wallet_) external onlyOwner {
        _pendingCharityWallet = wallet_;
        _queueAction(TL_SET_CHARITY_WALLET);
    }

    function executeSetCharityWallet() external onlyOwner {
        _consumeAction(TL_SET_CHARITY_WALLET);
        bondingCurve.setCharityWallet(_pendingCharityWallet);
        emit CharityWalletUpdated(_pendingCharityWallet);
    }

    /// @notice Cancel a queued timelock action before it executes.
    function cancelAction(bytes32 actionId) external onlyOwner {
        if (timelockExpiry[actionId] == 0) revert TimelockNotQueued();
        timelockExpiry[actionId] = 0;
        emit TimelockCancelled(actionId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // ADMIN — OWNERSHIP / MANAGERS
    // ─────────────────────────────────────────────────────────────────────

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

    function addManager(address manager_) external onlyOwner {
        if (manager_ == address(0)) revert ZeroAddress();
        managers[manager_] = true;
        emit ManagerAdded(manager_);
    }

    function removeManager(address manager_) external onlyOwner {
        if (!managers[manager_]) revert Unauthorized();
        managers[manager_] = false;
        emit ManagerRemoved(manager_);
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Transfer (liqTokens + bcTokens) to BondingCurve and vest creator tokens if any.
    function _sendToBondingCurve(address token, address bc, Alloc memory a) internal {
        ILaunchpadToken(token).transfer(bc, a.liqTokens + a.bcTokens);
        if (a.creatorTokens > 0) {
            ILaunchpadToken(token).transfer(token, a.creatorTokens);
            ILaunchpadToken(token).setupVesting(msg.sender, a.creatorTokens);
        }
    }

    /// @dev Build RegisterParams and call bc.registerToken().
    function _registerWithCurve(
        BondingCurve bc,
        address token,
        address pair,
        Alloc memory a,
        bool enableAntibot,
        uint256 antibotBlocks
    ) internal {
        BondingCurve.RegisterParams memory rp;
        rp.liqTokens       = a.liqTokens;
        rp.creatorTokens   = a.creatorTokens;
        rp.bcTokens        = a.bcTokens;
        rp.pair            = pair;
        rp.enableAntibot   = enableAntibot;
        rp.antibotBlocks   = antibotBlocks;
        rp.creator         = msg.sender;
        rp.virtualBNB      = defaultVirtualBNB;
        rp.migrationTarget = defaultMigrationTarget;
        bc.registerToken(token, rp);
    }

    function _collectCreationFee(BondingCurve bc) internal returns (uint256 earlyBuy) {
        uint256 cf = creationFee;
        if (msg.value < cf) revert InsufficientCreationFee(cf, msg.value);
        earlyBuy = msg.value - cf;
        if (cf > 0) _safeSendBNB(bc.feeRecipient(), cf);
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
     *      Salt is bound to msg.sender to prevent cross-sender front-running.
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

    function _safeSendBNB(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert BNBTransferFailed();
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

    // ─────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Predict the CREATE2 address for a given creator, salt, and implementation.
     *         Mine off-chain until the resulting address ends in 0x1111.
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

    function getAntibotBlocksRange() external pure returns (uint256 min, uint256 max) {
        return (10, 199);
    }

    /// @notice Sweep stray BNB from the BondingCurve to `to` (anything above active pool totals).
    function rescueBNB(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        bondingCurve.rescueBNB(to);
    }

    receive() external payable {}
}
