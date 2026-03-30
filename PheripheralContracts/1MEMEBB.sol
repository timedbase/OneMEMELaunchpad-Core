// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPancakeRouter02 {
    function WETH() external pure returns (address);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256        amountOutMin,
        address[] calldata path,
        address        to,
        uint256        deadline
    ) external payable;
}

/**
 * @title  1MEMEBB  (OneMEME BuyBack)
 * @notice Holds BNB and executes periodic buybacks of a tracked token on
 *         PancakeSwap V2.  Anyone may trigger BBnow(); the amount spent per
 *         call scales with the contract's BNB balance:
 *
 *   balance < 0.1 BNB              → spend 100 % (entire balance)
 *   0.1 BNB ≤ balance ≤ 2 BNB     → spend exactly 0.1 BNB
 *   balance > 2 BNB                → spend flat 0.25 BNB
 *
 * A configurable cooldown (default 1 hour) prevents back-to-back calls.
 * Supports tax tokens via swapExactETHForTokensSupportingFeeOnTransferTokens.
 * Bought tokens accumulate inside this contract.
 * Only the owner can update the router, the buy token, or the cooldown period.
 * Ownership is two-step transferrable.
 */
contract OneMEMEBB {

    // ─── ownership ──────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;

    event OwnershipTransferInitiated(address indexed proposed);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "1MEMEBB: not owner");
        _;
    }

    /// @notice Step 1 – owner nominates a new owner.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "1MEMEBB: zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(newOwner);
    }

    /// @notice Step 2 – nominee accepts ownership.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "1MEMEBB: not pending owner");
        emit OwnershipTransferred(owner, msg.sender);
        owner        = msg.sender;
        pendingOwner = address(0);
    }

    // ─── configuration ───────────────────────────────────────────────────────

    IPancakeRouter02 public router;
    address          public buyToken;

    /// @dev Minimum seconds between consecutive BBnow() calls.
    uint256 public cooldown = 1 hours;

    /// @dev Bounds for owner-set cooldown: 30 min – 7 days.
    uint256 private constant MIN_COOLDOWN = 30 minutes;
    uint256 private constant MAX_COOLDOWN =  7 days;

    event RouterUpdated(address indexed newRouter);
    event BuyTokenUpdated(address indexed newToken);
    event CooldownUpdated(uint256 newCooldown);

    function setRouter(address router_) external onlyOwner {
        require(router_ != address(0), "1MEMEBB: zero address");
        router = IPancakeRouter02(router_);
        emit RouterUpdated(router_);
    }

    /// @notice Buy token is immutable once set — can only be configured once.
    function setBuyToken(address token_) external onlyOwner {
        require(buyToken == address(0), "1MEMEBB: buy token already set");
        require(token_ != address(0), "1MEMEBB: zero address");
        if (address(router) != address(0)) {
            require(token_ != router.WETH(), "1MEMEBB: buy token cannot be WBNB");
        }
        buyToken = token_;
        emit BuyTokenUpdated(token_);
    }

    /// @notice Adjust the inter-call cooldown (30 min – 7 days).
    function setCooldown(uint256 seconds_) external onlyOwner {
        require(seconds_ >= MIN_COOLDOWN && seconds_ <= MAX_COOLDOWN, "1MEMEBB: cooldown out of range");
        cooldown = seconds_;
        emit CooldownUpdated(seconds_);
    }

    // ─── buyback ─────────────────────────────────────────────────────────────

    uint256 public lastBuyAt;

    event BoughtBack(uint256 bnbSpent, uint256 balanceBefore);

    /**
     * @notice Trigger a buyback.  Open to anyone; enforces cooldown.
     *         Reverts if balance < 0.005 BNB.
     *
     * Spend tiers (evaluated against contract BNB balance):
     *   < 0.1 BNB            → 100 % of balance
     *   0.1 BNB – 2 BNB      → flat 0.1 BNB
     *   > 2 BNB              → flat 0.25 BNB
     */
    function BBnow() external {
        require(block.timestamp >= lastBuyAt + cooldown, "1MEMEBB: cooldown active");
        require(address(router) != address(0),           "1MEMEBB: router not set");
        require(buyToken        != address(0),           "1MEMEBB: buy token not set");

        uint256 balance = address(this).balance;
        require(balance >= 0.005 ether, "1MEMEBB: balance below minimum");

        uint256 spendAmount;
        if (balance < 0.1 ether) {
            spendAmount = balance;        // 100 %
        } else if (balance <= 2 ether) {
            spendAmount = 0.1 ether;     // flat 0.1 BNB
        } else {
            spendAmount = 0.25 ether;    // flat 0.25 BNB
        }

        // CEI: record timestamp before external call
        lastBuyAt = block.timestamp;

        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = buyToken;

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: spendAmount}(
            0,
            path,
            address(this),
            block.timestamp + 3 minutes
        );

        emit BoughtBack(spendAmount, balance);
    }

    /// @notice Seconds remaining until BBnow() can next be called (0 = ready).
    function cooldownRemaining() external view returns (uint256) {
        uint256 unlockAt = lastBuyAt + cooldown;
        return block.timestamp >= unlockAt ? 0 : unlockAt - block.timestamp;
    }

    // ─── withdrawal ──────────────────────────────────────────────────────────

    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Rescue any ERC-20 token held by this contract — including the
     *         tracked buyToken and tokens stranded by a previous buyToken change.
     * @param  token   Token contract address.
     * @param  amount  Amount to rescue; pass 0 to rescue entire balance.
     */
    function rescueToken(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "1MEMEBB: zero address");
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 toSend = amount == 0 ? bal : amount;
        require(toSend > 0 && toSend <= bal, "1MEMEBB: invalid amount");
        require(IERC20(token).transfer(owner, toSend), "1MEMEBB: transfer failed");
        emit TokensWithdrawn(token, owner, toSend);
    }

    /**
     * @notice Withdraw BNB held by this contract to the owner.
     * @param  amount  Amount to withdraw; pass 0 to withdraw entire balance.
     */
    function withdrawBNB(uint256 amount) external onlyOwner {
        uint256 bal = address(this).balance;
        uint256 toSend = amount == 0 ? bal : amount;
        require(toSend > 0 && toSend <= bal, "1MEMEBB: invalid amount");
        (bool ok,) = owner.call{value: toSend}("");
        require(ok, "1MEMEBB: BNB transfer failed");
    }

    // ─── constructor / receive ───────────────────────────────────────────────

    /**
     * @param router_   PancakeSwap V2 router address.
     * @param buyToken_ Token to accumulate on each buyback.
     */
    constructor(address router_, address buyToken_) {
        require(router_   != address(0), "1MEMEBB: zero router");
        require(buyToken_ != address(0), "1MEMEBB: zero token");
        owner    = msg.sender;
        router   = IPancakeRouter02(router_);
        buyToken = buyToken_;
    }

    event Received(address indexed from, uint256 amount);

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}
