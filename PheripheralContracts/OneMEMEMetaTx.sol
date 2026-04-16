// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

/**
 * @title  OneMEMEMetaTx
 * @notice Gasless swap relay for the OneMEME aggregator.
 *
 * Users sign MetaTxOrders off-chain (EIP-712). Relayers submit them on-chain,
 * pay the gas, and are compensated in BNB from the swap output.
 *
 * ─── Supported swap directions ──────────────────────────────────────────────
 *
 *   Token → BNB   (tokenIn = ERC-20, tokenOut = address(0))
 *     Primary gasless use-case. User has tokens but no BNB for gas.
 *     Relayer earns `relayerFee` BNB deducted from the swap output.
 *
 *   Token → Token (tokenIn = ERC-20, tokenOut = ERC-20)
 *     Supported, but `relayerFee` must be 0. Relayer compensation is
 *     negotiated off-chain (e.g. sponsored gas or fee paid separately).
 *
 *   BNB → Token   not supported — user has no BNB to attach as msg.value.
 *
 * ─── Permit support ──────────────────────────────────────────────────────────
 *
 *   PERMIT_NONE (0)    — user called approve(MetaTx, amount) beforehand.
 *                        Gas-optimal when allowance already exists.
 *
 *   PERMIT_EIP2612 (1) — EIP-2612 permit(). MetaTx checks allowance first;
 *                        if already sufficient the permit call is skipped
 *                        entirely (saves ~25 k gas). If permit is provided but
 *                        the token doesn't support it, the failure is caught and
 *                        a clear InsufficientAllowance error is surfaced before
 *                        the swap path, preventing wasted gas on the aggregator
 *                        call that would inevitably fail.
 *
 *   PERMIT_2 (2)       — Uniswap Permit2. User approves Permit2 once, then
 *                        signs off-chain permits. The contract calls
 *                        Permit2.permitTransferFrom() which handles both the
 *                        permission check and the transfer atomically.
 *
 * ─── Transaction flow ────────────────────────────────────────────────────────
 *
 *   Relayer calls executeMetaTx(order, sig, permitData)
 *     │
 *     ├── 1. Validate deadline, nonce, direction, relayer-fee constraint
 *     ├── 2. Verify EIP-712 signature (order.user is signer)
 *     ├── 3. Consume permit (if provided) and pull grossAmountIn from user
 *     ├── 4. Approve aggregator; call aggregator.swap()
 *     │        aggregator takes its 1% protocol fee on grossAmountIn
 *     │        net amount is swapped via the chosen adapter
 *     ├── 5. If relayerFee > 0 (Token→BNB path):
 *     │        pay relayer relayerFee BNB
 *     │        forward remaining swap BNB to order.recipient
 *     └── 6. Emit MetaTxExecuted
 *
 * ─── Aggregator fee interaction ──────────────────────────────────────────────
 *
 *   The aggregator takes 1% of grossAmountIn as its protocol fee.
 *   minUserOut + relayerFee is passed as minOut to the aggregator, so the
 *   total BNB output must cover both. Users should factor in the 1% fee when
 *   computing grossAmountIn and minUserOut off-chain.
 *
 * ─── Permit data is NOT signed in MetaTxOrder ────────────────────────────────
 *
 *   The relayer attaches the most-current permit at submission time. This is
 *   safe because each permit type contains its own user signature (v,r,s or
 *   Permit2 sig) which cannot be forged by the relayer.
 */

// ─── Interfaces ───────────────────────────────────────────────────────────────

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
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external;

    function allowance(address owner, address spender) external view returns (uint256);
}

/// @dev Minimal Uniswap Permit2 interface.
///      Canonical deployment on all supported chains: 0x000000000022D473030F116dDEE9F6B43aC78BA3
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256          nonce;
        uint256          deadline;
    }
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }
    function permitTransferFrom(
        PermitTransferFrom    calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address                owner,
        bytes                  calldata signature
    ) external;
}

// ─── Main Contract ────────────────────────────────────────────────────────────

contract OneMEMEMetaTx {

    // ── Constants ────────────────────────────────────────────────────────────

    uint8 public constant PERMIT_NONE    = 0;   // pre-approved via ERC-20 approve()
    uint8 public constant PERMIT_EIP2612 = 1;   // EIP-2612 permit() — try-catch with allowance guard
    uint8 public constant PERMIT_2       = 2;   // Uniswap Permit2 — handles permit + transfer

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    /// @dev EIP-712 typehash for MetaTxOrder. adapterData is dynamic (bytes) — hashed in encoding.
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

    // ── Immutables ───────────────────────────────────────────────────────────

    /// @notice The OneMEMEAggregator all meta-transactions route through.
    address public immutable aggregator;

    /// @notice Uniswap Permit2 contract.
    ///         BSC / most EVM chains: 0x000000000022D473030F116dDEE9F6B43aC78BA3
    ///         Set to address(0) at deploy time to disable Permit2 support.
    address public immutable permit2;

    /// @notice EIP-712 domain separator — bound to this contract + chainId at deploy.
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ── State ────────────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;

    /// @notice Sequential nonce per user. Incremented after every successful execution.
    ///         All outstanding signed orders with the old nonce become invalid.
    mapping(address => uint256) public nonces;

    uint256 private _status = _NOT_ENTERED;

    // ── Structs ──────────────────────────────────────────────────────────────

    /**
     * @notice The order a user signs off-chain.
     *
     * @param user           Token owner and meta-tx signer.
     * @param nonce          Must equal nonces[user] at execution time.
     * @param deadline       Expiry of this meta-tx (checked by this contract).
     * @param adapterId      Aggregator registry key — keccak256("PANCAKE_V2") etc.
     * @param tokenIn        Input token. Must not be address(0).
     * @param grossAmountIn  Total pulled from user. Aggregator takes its 1% fee on this.
     * @param tokenOut       Output token. address(0) = BNB output.
     *                       Must be address(0) when relayerFee > 0.
     * @param minUserOut     Minimum output user must receive, AFTER relayerFee is deducted.
     *                       The aggregator is called with minOut = minUserOut + relayerFee.
     * @param recipient      Where the user's output (tokens or remaining BNB) is delivered.
     * @param swapDeadline   Forwarded to aggregator.swap() — typically deadline + buffer.
     * @param adapterData    Adapter-specific routing bytes built offchain.
     * @param relayerFee     BNB amount paid to msg.sender (relayer). 0 = no on-chain payment.
     *                       Requires tokenOut == address(0).
     */
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
        uint256 relayerFee;
    }

    /**
     * @notice Permit data attached by the relayer at call time — NOT signed in MetaTxOrder.
     *         The contained user signatures (v,r,s or Permit2 sig) prevent relayer forgery.
     *
     * @param permitType  PERMIT_NONE | PERMIT_EIP2612 | PERMIT_2
     * @param data        ABI-encoded permit parameters:
     *
     *   PERMIT_NONE    ""   (empty — just use existing allowance)
     *
     *   PERMIT_EIP2612 abi.encode(uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s)
     *                  The permit value is always order.grossAmountIn. Allowance is checked
     *                  first; if sufficient, the permit call is skipped to save gas.
     *
     *   PERMIT_2       abi.encode(uint256 p2Nonce, uint256 p2Deadline, bytes signature)
     *                  Permit2.permitTransferFrom handles the approval and transfer atomically.
     */
    struct PermitData {
        uint8 permitType;
        bytes data;
    }

    // ── Events ───────────────────────────────────────────────────────────────

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

    // ── Errors ───────────────────────────────────────────────────────────────

    error Reentrancy();
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error ZeroAmount();
    error DeadlineExpired();
    error InvalidSignature();
    error NonceMismatch();                  // order.nonce != nonces[user]
    error NonceTooLow();                    // invalidateNonces: newNonce <= current
    error NativeInputNotSupported();        // tokenIn == address(0): user has no BNB for gasless
    error RelayerFeeRequiresBNBOutput();    // relayerFee > 0 but tokenOut != address(0)
    error InsufficientAllowance();          // permit failed / not provided and approval missing
    error Permit2NotConfigured();           // PERMIT_2 chosen but permit2 == address(0) at deploy
    error InsufficientOutput();             // swap BNB output < relayerFee
    error TransferFailed();
    error NativeSendFailed();

    // ── Modifiers ────────────────────────────────────────────────────────────

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

    // ── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param aggregator_  OneMEMEAggregator address.
     * @param permit2_     Permit2 contract address.
     *                     Pass 0x000000000022D473030F116dDEE9F6B43aC78BA3 on BSC.
     *                     Pass address(0) to disable Permit2 support.
     */
    constructor(address aggregator_, address permit2_) {
        if (aggregator_ == address(0)) revert ZeroAddress();
        owner      = msg.sender;
        aggregator = aggregator_;
        permit2    = permit2_;

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256(
                "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
            ),
            keccak256("OneMEMEMetaTx"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    /// @dev Required to receive BNB from the aggregator on Token→BNB swaps.
    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────
    // CORE
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Execute a gasless swap on behalf of a user.
     *
     * @param order   The user's signed order.
     * @param sig     65-byte EIP-712 signature (r ++ s ++ v) over `order`.
     * @param permit  Optional permit data. Relayer attaches the best available
     *                permit at submission time — not part of `order` signature.
     *
     * @dev msg.sender is the relayer and receives order.relayerFee BNB on success.
     */
    function executeMetaTx(
        MetaTxOrder calldata order,
        bytes       calldata sig,
        PermitData  calldata permit
    ) external nonReentrant {

        // ── Validation ────────────────────────────────────────────────────────

        if (block.timestamp > order.deadline)                      revert DeadlineExpired();
        if (order.tokenIn == address(0))                           revert NativeInputNotSupported();
        if (order.grossAmountIn == 0)                              revert ZeroAmount();
        if (order.recipient == address(0))                         revert ZeroAddress();
        if (order.relayerFee > 0 && order.tokenOut != address(0)) revert RelayerFeeRequiresBNBOutput();

        // Consume nonce — replay protection.
        uint256 usedNonce = nonces[order.user];
        if (order.nonce != usedNonce) revert NonceMismatch();
        unchecked { nonces[order.user] = usedNonce + 1; }

        // Verify EIP-712 signature.
        _verifySignature(order, sig);

        // ── Pull tokens from user ─────────────────────────────────────────────
        // Measure balance delta to handle fee-on-transfer (FoT) tokens correctly.
        // For standard tokens actualReceived == grossAmountIn. For FoT tokens
        // actualReceived < grossAmountIn; approving the aggregator for the full
        // grossAmountIn would cause the aggregator's transferFrom to fail.

        uint256 tokenBalBefore = _balanceOf(order.tokenIn, address(this));
        _pullWithPermit(order.user, order.tokenIn, order.grossAmountIn, permit);
        uint256 actualReceived = _balanceOf(order.tokenIn, address(this)) - tokenBalBefore;

        // ── Execute swap via aggregator ───────────────────────────────────────

        // When relayerFee > 0, route swap output to this contract so we can
        // split it. Otherwise output goes directly to the recipient.
        address swapRecipient = (order.relayerFee > 0) ? address(this) : order.recipient;

        // Approve only what we actually hold — FoT-safe.
        _approve(order.tokenIn, aggregator, actualReceived);

        // minOut passed to aggregator must cover user's share AND the relayer's fee.
        // Checked arithmetic — overflow would silently set a near-zero minOut.
        uint256 aggregatorMinOut = order.minUserOut + order.relayerFee;

        uint256 bnbBefore = address(this).balance;

        uint256 amountOut = IOneMEMEAggregator(aggregator).swap(
            order.adapterId,
            order.tokenIn,
            actualReceived,
            order.tokenOut,
            aggregatorMinOut,
            swapRecipient,
            order.swapDeadline,
            order.adapterData
        );

        _resetApproval(order.tokenIn, aggregator);

        // ── Pay relayer and forward user's share ──────────────────────────────

        if (order.relayerFee > 0) {
            // tokenOut == address(0) is enforced above, so BNB arrived here.
            uint256 bnbReceived = address(this).balance - bnbBefore;
            if (bnbReceived < order.relayerFee) revert InsufficientOutput();

            _sendNative(msg.sender, order.relayerFee);

            uint256 userBNB = bnbReceived - order.relayerFee;
            if (userBNB > 0) {
                _sendNative(order.recipient, userBNB);
            }
        }

        emit MetaTxExecuted(
            order.user,
            msg.sender,
            order.adapterId,
            order.tokenIn,
            order.tokenOut,
            order.grossAmountIn,
            amountOut,
            order.relayerFee,
            usedNonce
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // USER CONTROLS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Invalidate all outstanding signed orders up to (but not including) `newNonce`.
     *
     *         Unlike a +1 bump, this lets the user cancel multiple pre-signed orders in a
     *         single call. Example: if the user pre-signed orders at nonces 5, 6, 7 and
     *         wants to cancel all of them, call invalidateNonces(8).
     *
     * @param newNonce Must be strictly greater than the caller's current nonce.
     */
    function invalidateNonces(uint256 newNonce) external {
        if (newNonce <= nonces[msg.sender]) revert NonceTooLow();
        nonces[msg.sender] = newNonce;
        emit OrdersCancelled(msg.sender, newNonce);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADMIN
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Rescue ERC-20 tokens that became stuck in this contract.
    ///         Under normal operation the MetaTx contract holds tokens only
    ///         momentarily (between _pullWithPermit and aggregator.swap).
    ///         A failed native send to a contract recipient could leave BNB here;
    ///         a directly-sent token deposit can never be recovered without this.
    function rescueTokens(address token, address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _safeTransfer(token, recipient, amount);
    }

    /// @notice Rescue native BNB stuck in this contract.
    ///         Dust accumulates when BNB is sent directly to the contract address
    ///         (not via a swap) because the bnbBefore delta never distributes it.
    function rescueNative(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _sendNative(recipient, amount);
    }

    /// @notice Step 1 — propose a new owner.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(newOwner);
    }

    /// @notice Step 2 — new owner accepts.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner        = msg.sender;
        pendingOwner = address(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VIEWS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Compute the EIP-712 digest for an order.
     *         Use this offchain to generate the user signature via eth_signTypedData_v4.
     */
    function orderDigest(MetaTxOrder calldata order) external view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _structHash(order)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL — PERMIT HANDLING
    // ─────────────────────────────────────────────────────────────────────────

    function _pullWithPermit(
        address           user,
        address           token,
        uint256           amount,
        PermitData calldata permitData
    ) internal {

        if (permitData.permitType == PERMIT_2) {
            // ── Uniswap Permit2 ───────────────────────────────────────────────
            // Permit2.permitTransferFrom combines the permit verification and
            // the transferFrom into a single atomic call.
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
            // Tokens are now in this contract — no separate transferFrom needed.

        } else {
            // ── ERC-20 allowance path (PERMIT_NONE or PERMIT_EIP2612) ─────────

            // Check existing allowance first.
            // If already sufficient, skip the permit call entirely — saves ~25k gas.
            uint256 currentAllowance = IERC20(token).allowance(user, address(this));

            if (currentAllowance < amount) {
                if (permitData.permitType == PERMIT_EIP2612) {
                    // Attempt EIP-2612 permit. Catch failures: the token may not
                    // support it, or the permit may have already been consumed.
                    (uint256 permDeadline, uint8 v, bytes32 r, bytes32 s) =
                        abi.decode(permitData.data, (uint256, uint8, bytes32, bytes32));

                    try IERC20Permit(token).permit(
                        user, address(this), amount, permDeadline, v, r, s
                    ) {} catch {}

                    // Re-check allowance. If the permit did not work and there is
                    // still no approval, surface a clear error now rather than
                    // letting the aggregator call fail later — no gas is wasted on
                    // the swap path.
                    if (IERC20(token).allowance(user, address(this)) < amount) {
                        revert InsufficientAllowance();
                    }

                } else {
                    // PERMIT_NONE with insufficient allowance — relayer should not
                    // have submitted. Revert immediately before any swap work.
                    revert InsufficientAllowance();
                }
            }

            // Transfer tokens from user to this contract.
            _safeTransferFrom(token, user, address(this), amount);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL — SIGNATURE VERIFICATION
    // ─────────────────────────────────────────────────────────────────────────

    function _verifySignature(MetaTxOrder calldata order, bytes calldata sig) internal view {
        if (sig.length != 65) revert InvalidSignature();

        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }

        // Reject high-s signatures (EIP-2 canonical form).
        // ecrecover accepts both halves of the curve; enforcing low-s prevents
        // signature malleability even though sequential nonces already block replay.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _structHash(order)));
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != order.user) revert InvalidSignature();
    }

    function _structHash(MetaTxOrder calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH,
            order.user,
            order.nonce,
            order.deadline,
            order.adapterId,
            order.tokenIn,
            order.grossAmountIn,
            order.tokenOut,
            order.minUserOut,
            order.recipient,
            order.swapDeadline,
            keccak256(order.adapterData),   // bytes encoded as keccak256 per EIP-712
            order.relayerFee
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL — TOKEN HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    function _balanceOf(address token, address account) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        bal = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    /// @dev USDT-safe approve: reset to 0 before setting a new value.
    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, 0)
        );
        if (!ok) revert TransferFailed();
        (ok,) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        if (!ok) revert TransferFailed();
    }

    /// @dev Reset allowance to 0. Called after every aggregator.swap() to leave
    ///      no residual approval on the aggregator.
    function _resetApproval(address token, address spender) internal {
        (bool ok,) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, 0)
        );
        if (!ok) revert TransferFailed();
    }

    /// @dev Low-level transfer — handles tokens that return nothing (USDT-style).
    function _safeTransfer(address token, address to_, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to_, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /// @dev Low-level transferFrom — handles tokens that return nothing (USDT-style).
    function _safeTransferFrom(address token, address from, address to_, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to_, amount)
        );
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _sendNative(address to_, uint256 amount) internal {
        (bool ok,) = to_.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }
}
