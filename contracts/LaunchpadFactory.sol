// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./interfaces/IPancakeRouter02.sol";
import "./BondingCurve.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IVestingWallet {
    function addVesting(address token, address beneficiary, uint256 amount) external;
}

interface IStdInit {
    function initForLaunchpad(
        string memory name_, string memory symbol_, uint256 totalSupply_,
        address factory_, address bc_, address creator_, string memory metaURI_
    ) external;
}

interface ITaxRflInit {
    function initForLaunchpad(
        string memory name_, string memory symbol_, uint256 totalSupply_,
        address factory_, address bc_, address creator_, string memory metaURI_,
        address router_, address vestingWallet_
    ) external;
    function pancakePair() external view returns (address);
}

contract LaunchpadFactory {

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
        uint256      antibotBlocks;
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

    uint256 private constant LIQUIDITY_BPS = 3800;
    uint256 private constant CREATOR_BPS   =  500;
    uint256 private constant BPS_DENOM     = 10_000;
    uint256 private constant MAX_TOTAL_FEE =  250;  // 2.5 %

    uint256 public  constant DEFAULT_CREATION_FEE = 0.0011 ether;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    address public owner;
    address public pendingOwner;
    mapping(address => bool) public managers;

    address public immutable standardImpl;
    address public immutable taxImpl;
    address public immutable reflectionImpl;

    BondingCurve public immutable migrator;
    address public vestingWallet;

    uint256 public creationFee;
    uint256 public defaultVirtualBNB;
    uint256 public defaultMigrationTarget;

    uint256 private _status;

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

    constructor(
        address migrator_,
        uint256 creationFee_,
        uint256 defaultVirtualBNB_,
        uint256 defaultMigrationTarget_,
        address standardImpl_,
        address taxImpl_,
        address reflectionImpl_,
        address vestingWallet_
    ) {
        if (migrator_               == address(0)) revert ZeroAddress();
        if (defaultVirtualBNB_      == 0)          revert ZeroAmount();
        if (defaultMigrationTarget_ == 0)          revert ZeroAmount();
        if (standardImpl_           == address(0)) revert ZeroAddress();
        if (taxImpl_                == address(0)) revert ZeroAddress();
        if (reflectionImpl_         == address(0)) revert ZeroAddress();

        owner                  = msg.sender;
        migrator               = BondingCurve(payable(migrator_));
        creationFee            = creationFee_;
        defaultVirtualBNB      = defaultVirtualBNB_;
        defaultMigrationTarget = defaultMigrationTarget_;
        _status                = _NOT_ENTERED;

        standardImpl   = standardImpl_;
        taxImpl        = taxImpl_;
        reflectionImpl = reflectionImpl_;
        vestingWallet  = vestingWallet_;
    }

    function createToken(BaseParams memory p) external payable nonReentrant returns (address token) {
        BondingCurve bc  = migrator;
        uint256 earlyBuy = _collectCreationFee(bc);
        token = _cloneCreate2(standardImpl, p.salt);

        uint256 tradingBlock_;
        {
            Alloc memory a = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);
            IStdInit(token).initForLaunchpad(
                p.name, p.symbol, a.supply, address(this), address(bc), msg.sender, p.metaURI
            );
            _distribute(token, address(bc), a);
            _registerWithCurve(bc, token, address(0), a, p.enableAntibot, p.antibotBlocks);
            tradingBlock_ = p.enableAntibot ? block.number + p.antibotBlocks : block.number;
            emit TokenCreated(token, msg.sender, a.supply,
                defaultVirtualBNB, defaultMigrationTarget, p.enableAntibot, tradingBlock_);
        }

        if (earlyBuy > 0) bc.earlyBuy{value: earlyBuy}(token, msg.sender);
    }

    function createTT(CreateTTParams memory p) external payable nonReentrant returns (address payable token) {
        BondingCurve bc  = migrator;
        uint256 earlyBuy = _collectCreationFee(bc);
        token = payable(_cloneCreate2(taxImpl, p.salt));

        uint256 tradingBlock_;
        {
            Alloc memory a  = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);
            ITaxRflInit(token).initForLaunchpad(
                p.name, p.symbol, a.supply, address(this), address(bc), msg.sender, p.metaURI,
                bc.pancakeRouter(), vestingWallet
            );
            _distribute(token, address(bc), a);
            _registerWithCurve(bc, token, ITaxRflInit(token).pancakePair(), a, p.enableAntibot, p.antibotBlocks);
            tradingBlock_ = p.enableAntibot ? block.number + p.antibotBlocks : block.number;
            emit TokenCreated(token, msg.sender, a.supply,
                defaultVirtualBNB, defaultMigrationTarget, p.enableAntibot, tradingBlock_);
        }

        if (earlyBuy > 0) bc.earlyBuy{value: earlyBuy}(token, msg.sender);
    }

    function createRFL(CreateRFLParams memory p) external payable nonReentrant returns (address payable token) {
        BondingCurve bc  = migrator;
        uint256 earlyBuy = _collectCreationFee(bc);
        token = payable(_cloneCreate2(reflectionImpl, p.salt));

        uint256 tradingBlock_;
        {
            Alloc memory a  = _computeAlloc(_supplyFromOption(p.supplyOption), p.enableCreatorAlloc);
            ITaxRflInit(token).initForLaunchpad(
                p.name, p.symbol, a.supply, address(this), address(bc), msg.sender, p.metaURI,
                bc.pancakeRouter(), vestingWallet
            );
            _distribute(token, address(bc), a);
            _registerWithCurve(bc, token, ITaxRflInit(token).pancakePair(), a, p.enableAntibot, p.antibotBlocks);
            tradingBlock_ = p.enableAntibot ? block.number + p.antibotBlocks : block.number;
            emit TokenCreated(token, msg.sender, a.supply,
                defaultVirtualBNB, defaultMigrationTarget, p.enableAntibot, tradingBlock_);
        }

        if (earlyBuy > 0) bc.earlyBuy{value: earlyBuy}(token, msg.sender);
    }

    function buy(address token_, uint256 minOut, uint256 deadline) external payable nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (msg.value == 0) revert ZeroAmount();
        migrator.buyFor{value: msg.value}(token_, msg.sender, minOut);
    }

    function sell(address token_, uint256 amountIn, uint256 minBNBOut, uint256 deadline)
        external nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();
        address bc = address(migrator);
        IERC20Min(token_).transferFrom(msg.sender, bc, amountIn);
        BondingCurve(payable(bc)).completeSell(token_, msg.sender, amountIn, minBNBOut, deadline);
    }

    function migrate(address token_) external {
        migrator.migrate(token_);
    }

    function setDefaultParams(uint256 virtualBNB_, uint256 migrationTarget_) external onlyOwnerOrManager {
        if (virtualBNB_      == 0) revert ZeroAmount();
        if (migrationTarget_ == 0) revert ZeroAmount();
        if (virtualBNB_      > 10_000 ether)  revert ParamOutOfRange();
        if (migrationTarget_ > 100_000 ether) revert ParamOutOfRange();
        emit DefaultParamsUpdated(defaultVirtualBNB, virtualBNB_, defaultMigrationTarget, migrationTarget_);
        defaultVirtualBNB      = virtualBNB_;
        defaultMigrationTarget = migrationTarget_;
    }

    function setCreationFee(uint256 fee_) external onlyOwner {
        emit CreationFeeUpdated(creationFee, fee_);
        creationFee = fee_;
    }

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
        emit RouterUpdated(migrator.pancakeRouter(), _pendingRouter);
        migrator.setRouter(_pendingRouter);
    }

    function proposeSetPlatformFee(uint256 fee_) external onlyOwner {
        if (fee_ + migrator.charityFee() > MAX_TOTAL_FEE) revert FeeExceedsMax();
        _pendingPlatformFee = fee_;
        _queueAction(TL_SET_PLATFORM_FEE);
    }

    function executeSetPlatformFee() external onlyOwner {
        _consumeAction(TL_SET_PLATFORM_FEE);
        uint256 pf = _pendingPlatformFee;
        if (pf + migrator.charityFee() > MAX_TOTAL_FEE) revert FeeExceedsMax();
        migrator.setFees(pf, migrator.charityFee());
        emit PlatformFeeUpdated(pf);
    }

    function proposeSetCharityFee(uint256 fee_) external onlyOwner {
        if (migrator.platformFee() + fee_ > MAX_TOTAL_FEE) revert FeeExceedsMax();
        _pendingCharityFee = fee_;
        _queueAction(TL_SET_CHARITY_FEE);
    }

    function executeSetCharityFee() external onlyOwner {
        _consumeAction(TL_SET_CHARITY_FEE);
        uint256 cf = _pendingCharityFee;
        if (migrator.platformFee() + cf > MAX_TOTAL_FEE) revert FeeExceedsMax();
        migrator.setFees(migrator.platformFee(), cf);
        emit CharityFeeUpdated(cf);
    }

    function proposeSetFeeRecipient(address rec_) external onlyOwner {
        if (rec_ == address(0)) revert ZeroAddress();
        _pendingFeeRecipient = rec_;
        _queueAction(TL_SET_FEE_RECIPIENT);
    }

    function executeSetFeeRecipient() external onlyOwner {
        _consumeAction(TL_SET_FEE_RECIPIENT);
        migrator.setFeeRecipient(_pendingFeeRecipient);
        emit FeeRecipientUpdated(_pendingFeeRecipient);
    }

    // Propose address(0) to redirect the charity portion to feeRecipient.
    function proposeSetCharityWallet(address wallet_) external onlyOwner {
        _pendingCharityWallet = wallet_;
        _queueAction(TL_SET_CHARITY_WALLET);
    }

    function executeSetCharityWallet() external onlyOwner {
        _consumeAction(TL_SET_CHARITY_WALLET);
        migrator.setCharityWallet(_pendingCharityWallet);
        emit CharityWalletUpdated(_pendingCharityWallet);
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        if (timelockExpiry[actionId] == 0) revert TimelockNotQueued();
        timelockExpiry[actionId] = 0;
        emit TimelockCancelled(actionId);
    }

    // Can only be called once (when vestingWallet is zero).
    function setVestingWallet(address vestingWallet_) external onlyOwner {
        if (vestingWallet != address(0)) revert Unauthorized();
        if (vestingWallet_ == address(0)) revert ZeroAddress();
        vestingWallet = vestingWallet_;
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

    function _distribute(address token, address bc, Alloc memory a) internal {
        IERC20Min(token).transfer(bc, a.liqTokens + a.bcTokens);
        if (a.creatorTokens > 0) {
            address vw = vestingWallet;
            IERC20Min(token).transfer(vw, a.creatorTokens);
            IVestingWallet(vw).addVesting(token, msg.sender, a.creatorTokens);
        }
    }

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

    // Salt is bound to msg.sender to prevent cross-sender front-running.
    // The resulting address must end in 0x1111 (vanity requirement).
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

    function rescueBNB(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        migrator.rescueBNB(to);
    }

    receive() external payable {}
}
