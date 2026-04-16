// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface ITokenManagerHelper3 {
    function getTokenInfo(address token) external view returns (
        uint256 version,
        address tokenManager,
        address quote,
        uint256 lastPrice,
        uint256 tradingFeeRate,
        uint256 minTradingFee,
        uint256 launchTime,
        uint256 offers,
        uint256 maxOffers,
        uint256 funds,
        uint256 maxFunds,
        bool    liquidityAdded
    );
    // ERC20-quote pairs only: wraps BNB → quote → token internally.
    function buyWithEth(uint256 origin, address token, address to, uint256 funds, uint256 minAmount) external payable;
    // ERC20-quote pairs only: pulls token from msg.sender, delivers BNB to msg.sender.
    function sellForEth(uint256 origin, address token, uint256 amount, uint256 minFunds, uint256 feeRate, address feeRecipient) external;
}

interface ITokenManagerV1 {
    // Buys with BNB (msg.value), delivers tokens to `to`.
    function purchaseTokenAMAP(uint256 origin, address token, address to, uint256 funds, uint256 minAmount) external payable;
    // Pulls tokens from msg.sender via transferFrom, sends BNB to msg.sender.
    function saleToken(address token, uint256 amount) external;
}

interface ITokenManagerV2 {
    // Universal buy: works for both regular and X-Mode tokens. Uses msg.value for BNB pairs.
    function buyToken(bytes calldata args, uint256 time, bytes calldata signature) external payable;
    // Pulls tokens from msg.sender via transferFrom, sends BNB/quote to msg.sender.
    function sellToken(uint256 origin, address token, uint256 amount, uint256 minFunds, uint256 feeRate, address feeRecipient) external;
}

// ─── Main Contract ────────────────────────────────────────────────────────────

/**
 * @title  FourMEMEAdapter
 * @notice Aggregator adapter for FourMEME bonding-curve tokens.
 *         Supports BNB → Token (buy) and Token → BNB (sell) only.
 *         Routing (V1/V2 manager, BNB vs ERC20 quote pair) is resolved at
 *         runtime via Helper V3 — no offchain hint required.
 *         Reverts if the token has already migrated to PancakeSwap.
 *
 * adapterData  abi.encode(address token)
 * Registry ID  keccak256("FOURMEME")
 */
contract FourMEMEAdapter is BaseAdapter {

    // ── Protocol addresses (BSC mainnet) ─────────────────────────────────────

    address public constant V1_MANAGER = 0xEC4549caDcE5DA21Df6E6422d448034B5233bFbC;
    address public constant V2_MANAGER = 0x5c952063c7fc8610FFDB798152D69F0B9550762b;
    address public constant HELPER_V3  = 0xF251F83e40a78868FcfA3FA4599Dad6494E46034;

    // ── Errors ───────────────────────────────────────────────────────────────

    error TokenMigrated();
    error UnsupportedDirection();

    // ── BuyTokenParams (V2 universal buy interface) ───────────────────────────
    // AMAP mode: amount=0, maxFunds=0, funds=<quote>, minAmount=<min tokens>
    struct BuyTokenParams {
        uint256 origin;
        address token;
        address to;
        uint256 amount;
        uint256 maxFunds;
        uint256 funds;
        uint256 minAmount;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address aggregator_) BaseAdapter(aggregator_) {}

    function name() external pure override returns (string memory) {
        return "FourMEME Adapter";
    }

    // ── execute ──────────────────────────────────────────────────────────────

    /**
     * @dev Pre-condition (buy):  netIn BNB in msg.value.
     *      Pre-condition (sell): netIn of tokenIn already held by this adapter.
     */
    function execute(
        address        tokenIn,
        uint256        netIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata adapterData
    ) external payable override onlyAggregator returns (uint256 amountOut) {
        address token = abi.decode(adapterData, (address));

        (
            uint256 version,
            address tokenManager,
            address quote,
            ,,,,,,,, // lastPrice … maxFunds (unused)
            bool liquidityAdded
        ) = ITokenManagerHelper3(HELPER_V3).getTokenInfo(token);

        if (liquidityAdded) revert TokenMigrated();

        if (tokenIn == address(0) && tokenOut != address(0)) {
            _buy(version, tokenManager, quote, token, netIn, minOut, to);
        } else if (tokenIn != address(0) && tokenOut == address(0)) {
            amountOut = _sell(version, tokenManager, quote, token, minOut, to);
        } else {
            revert UnsupportedDirection();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL
    // ─────────────────────────────────────────────────────────────────────────

    function _buy(
        uint256 version,
        address tokenManager,
        address quote,
        address token,
        uint256 netIn,
        uint256 minOut,
        address to
    ) internal {
        if (quote == address(0)) {
            if (version == 1) {
                ITokenManagerV1(tokenManager).purchaseTokenAMAP{value: netIn}(0, token, to, netIn, minOut);
            } else {
                // V2 universal interface handles regular and X-Mode tokens uniformly.
                bytes memory args = abi.encode(BuyTokenParams(0, token, to, 0, 0, netIn, minOut));
                ITokenManagerV2(tokenManager).buyToken{value: netIn}(args, 0, "");
            }
        } else {
            // ERC20-quote pair: helper wraps BNB → quote → token.
            ITokenManagerHelper3(HELPER_V3).buyWithEth{value: netIn}(0, token, to, netIn, minOut);
        }
        // Tokens delivered directly to `to` — amountOut left as 0.
    }

    function _sell(
        uint256 version,
        address tokenManager,
        address quote,
        address token,
        uint256 minOut,
        address to
    ) internal returns (uint256 bnbOut) {
        // _selfBalance is FoT-safe: adapter may hold less than the declared netIn.
        uint256 amount = _selfBalance(token);
        uint256 bnbBefore = address(this).balance;

        if (quote == address(0)) {
            _approve(token, tokenManager, amount);
            if (version == 1) {
                ITokenManagerV1(tokenManager).saleToken(token, amount);
            } else {
                ITokenManagerV2(tokenManager).sellToken(0, token, amount, minOut, 0, address(0));
            }
            _resetApproval(token, tokenManager);
        } else {
            // ERC20-quote pair: helper pulls token from msg.sender (this adapter),
            // converts proceeds to BNB, sends BNB to msg.sender.
            _approve(token, HELPER_V3, amount);
            ITokenManagerHelper3(HELPER_V3).sellForEth(0, token, amount, minOut, 0, address(0));
            _resetApproval(token, HELPER_V3);
        }

        bnbOut = address(this).balance - bnbBefore;
        if (bnbOut < minOut) revert InsufficientOutput();
        _sendNative(to, bnbOut);
    }
}
