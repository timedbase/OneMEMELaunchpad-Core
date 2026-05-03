// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

/**
 * @title  OneMEMEMetaTx
 * @notice Gasless swap relay. Users sign MetaTxOrders off-chain (EIP-712);
 *         relayers submit on-chain, pay gas, and receive relayerFee BNB from swap output.
 *         Supports Token→BNB (relayerFee ≥ 0) and Token→Token (relayerFee must be 0).
 */

interface IOneMEMEAggregator {
    function swap(
        bytes32        adapterId,
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        uint256        deadline,
        bytes calldata adapterData
    ) external payable returns (uint256 amountOut);
}

interface IERC20 {
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IPermit2 {
    struct TokenPermissions        { address token; uint256 amount; }
    struct PermitTransferFrom      { TokenPermissions permitted; uint256 nonce; uint256 deadline; }
    struct SignatureTransferDetails { address to; uint256 requestedAmount; }
    function permitTransferFrom(
        PermitTransferFrom       calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address                           owner,
        bytes                    calldata signature
    ) external;
}

contract OneMEMEMetaTx {

    uint8 public constant PERMIT_NONE    = 0;
    uint8 public constant PERMIT_EIP2612 = 1;
    uint8 public constant PERMIT_2       = 2;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    // adapterData is dynamic (bytes) — hashed per EIP-712.
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "MetaTxOrder("
            "address user,"
            "uint256 nonce,"
            "uint256 deadline,"
            "bytes32 adapterId,"
            "address tokenIn,"
            "uint256 grossAmountIn,"
            "address tokenOut,"
            "uint256 minUserOut,"
            "address recipient,"
            "uint256 swapDeadline,"
            "bytes adapterData,"
            "uint256 relayerFee"
        ")"
    );

    address public immutable aggregator;
    address public immutable permit2;
    bytes32 public immutable DOMAIN_SEPARATOR;

    address public owner;
    address public pendingOwner;

    mapping(address => uint256) public nonces;

    uint256 private _status = _NOT_ENTERED;

    struct MetaTxOrder {
        address user;
        uint256 nonce;
        uint256 deadline;
        bytes32 adapterId;
        address tokenIn;
        uint256 grossAmountIn;
        address tokenOut;
        uint256 minUserOut;
        address recipient;
        uint256 swapDeadline;
        bytes   adapterData;
        uint256 relayerFee;    // BNB paid to relayer; requires tokenOut == address(0)
    }

    struct PermitData {
        uint8 permitType;
        bytes data;
    }

    event MetaTxExecuted(
        address indexed user,
        address indexed relayer,
        bytes32 indexed adapterId,
        address         tokenIn,
        address         tokenOut,
        uint256         grossAmountIn,
        uint256         amountOut,
        uint256         relayerFee,
        uint256         nonce
    );
    event OrdersCancelled(address indexed user, uint256 newNonce);
    event OwnershipTransferInitiated(address indexed proposed);
    event OwnershipTransferred(address indexed previous, address indexed next);

    error Reentrancy();
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error ZeroAmount();
    error DeadlineExpired();
    error InvalidSignature();
    error NonceMismatch();
    error NonceTooLow();
    error NativeInputNotSupported();
    error RelayerFeeRequiresBNBOutput();
    error InsufficientAllowance();
    error Permit2NotConfigured();
    error InsufficientOutput();
    error TransferFailed();
    error NativeSendFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(address aggregator_, address permit2_) {
        if (aggregator_ == address(0)) revert ZeroAddress();
        owner      = msg.sender;
        aggregator = aggregator_;
        permit2    = permit2_;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("OneMEMEMetaTx"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    receive() external payable {}

    function executeMetaTx(
        MetaTxOrder calldata order,
        bytes       calldata sig,
        PermitData  calldata permit
    ) external nonReentrant {
        if (block.timestamp > order.deadline)                      revert DeadlineExpired();
        if (order.tokenIn == address(0))                           revert NativeInputNotSupported();
        if (order.grossAmountIn == 0)                              revert ZeroAmount();
        if (order.recipient == address(0))                         revert ZeroAddress();
        if (order.relayerFee > 0 && order.tokenOut != address(0)) revert RelayerFeeRequiresBNBOutput();

        uint256 usedNonce = nonces[order.user];
        if (order.nonce != usedNonce) revert NonceMismatch();
        unchecked { nonces[order.user] = usedNonce + 1; }

        _verifySignature(order, sig);

        // Balance delta handles fee-on-transfer tokens: actualReceived may be less than
        // grossAmountIn, and we approve the aggregator for exactly what we hold.
        uint256 tokenBalBefore = _balanceOf(order.tokenIn, address(this));
        _pullWithPermit(order.user, order.tokenIn, order.grossAmountIn, permit);
        uint256 actualReceived = _balanceOf(order.tokenIn, address(this)) - tokenBalBefore;

        address swapRecipient = (order.relayerFee > 0) ? address(this) : order.recipient;

        _approve(order.tokenIn, aggregator, actualReceived);

        uint256 aggregatorMinOut = order.minUserOut + order.relayerFee;
        uint256 bnbBefore = address(this).balance;

        uint256 amountOut = _callSwap(order, actualReceived, swapRecipient, aggregatorMinOut);

        _resetApproval(order.tokenIn, aggregator);

        if (order.relayerFee > 0) {
            uint256 bnbReceived = address(this).balance - bnbBefore;
            if (bnbReceived < order.relayerFee) revert InsufficientOutput();
            _sendNative(msg.sender, order.relayerFee);
            uint256 userBNB = bnbReceived - order.relayerFee;
            if (userBNB > 0) _sendNative(order.recipient, userBNB);
        }

        _emitExecuted(order, amountOut, usedNonce);
    }

    function invalidateNonces(uint256 newNonce) external {
        if (newNonce <= nonces[msg.sender]) revert NonceTooLow();
        nonces[msg.sender] = newNonce;
        emit OrdersCancelled(msg.sender, newNonce);
    }

    function rescueTokens(address token, address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _safeTransfer(token, recipient, amount);
    }

    function rescueNative(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _sendNative(recipient, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner        = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Compute the EIP-712 digest for an order (use with eth_signTypedData_v4 offchain).
    function orderDigest(MetaTxOrder calldata order) external view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _structHash(order)));
    }

    function _emitExecuted(
        MetaTxOrder calldata order,
        uint256 amountOut,
        uint256 usedNonce
    ) internal {
        emit MetaTxExecuted(
            order.user, msg.sender, order.adapterId,
            order.tokenIn, order.tokenOut,
            order.grossAmountIn, amountOut,
            order.relayerFee, usedNonce
        );
    }

    function _callSwap(
        MetaTxOrder calldata order,
        uint256 actualReceived,
        address swapRecipient,
        uint256 aggregatorMinOut
    ) internal returns (uint256) {
        return IOneMEMEAggregator(aggregator).swap(
            order.adapterId,
            order.tokenIn,
            actualReceived,
            order.tokenOut,
            aggregatorMinOut,
            swapRecipient,
            order.swapDeadline,
            order.adapterData
        );
    }

    function _pullWithPermit(
        address            user,
        address            token,
        uint256            amount,
        PermitData calldata permitData
    ) internal {
        if (permitData.permitType == PERMIT_2) {
            if (permit2 == address(0)) revert Permit2NotConfigured();
            (uint256 p2Nonce, uint256 p2Deadline, bytes memory p2Sig) =
                abi.decode(permitData.data, (uint256, uint256, bytes));
            IPermit2(permit2).permitTransferFrom(
                IPermit2.PermitTransferFrom({
                    permitted: IPermit2.TokenPermissions({ token: token, amount: amount }),
                    nonce:     p2Nonce,
                    deadline:  p2Deadline
                }),
                IPermit2.SignatureTransferDetails({ to: address(this), requestedAmount: amount }),
                user,
                p2Sig
            );
        } else {
            uint256 currentAllowance = IERC20(token).allowance(user, address(this));
            if (currentAllowance < amount) {
                if (permitData.permitType == PERMIT_EIP2612) {
                    (uint256 permDeadline, uint8 v, bytes32 r, bytes32 s) =
                        abi.decode(permitData.data, (uint256, uint8, bytes32, bytes32));
                    try IERC20Permit(token).permit(user, address(this), amount, permDeadline, v, r, s) {} catch {}
                    if (IERC20(token).allowance(user, address(this)) < amount) revert InsufficientAllowance();
                } else {
                    revert InsufficientAllowance();
                }
            }
            _safeTransferFrom(token, user, address(this), amount);
        }
    }

    function _verifySignature(MetaTxOrder calldata order, bytes calldata sig) internal view {
        if (sig.length != 65) revert InvalidSignature();
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        // Enforce low-s (EIP-2): ecrecover accepts both curve halves; canonical form prevents malleability.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _structHash(order)));
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != order.user) revert InvalidSignature();
    }

    function _structHash(MetaTxOrder calldata order) internal pure returns (bytes32) {
        // Split across two abi.encode calls to stay within the 16-slot legacy stack limit.
        // Concatenation is safe: all fields are static-length (32 bytes each after padding),
        // so bytes.concat(abi.encode(a…g), abi.encode(h…m)) == abi.encode(a…m).
        return keccak256(bytes.concat(
            abi.encode(
                ORDER_TYPEHASH,
                order.user, order.nonce, order.deadline,
                order.adapterId, order.tokenIn, order.grossAmountIn
            ),
            abi.encode(
                order.tokenOut, order.minUserOut, order.recipient,
                order.swapDeadline,
                keccak256(order.adapterData),
                order.relayerFee
            )
        ));
    }

    function _balanceOf(address token, address account) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        bal = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    // USDT-safe approve: reset to 0 before setting a new value.
    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, 0));
        if (!ok) revert TransferFailed();
        (ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        if (!ok) revert TransferFailed();
    }

    function _resetApproval(address token, address spender) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, 0));
        if (!ok) revert TransferFailed();
    }

    function _safeTransfer(address token, address to_, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to_, amount));
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to_, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x23b872dd, from, to_, amount));
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _sendNative(address to_, uint256 amount) internal {
        (bool ok,) = to_.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }
}
