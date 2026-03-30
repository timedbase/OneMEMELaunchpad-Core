// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title  Collector
 * @notice Accepts BNB and ERC/BEP-20 tokens.
 *         Any BNB held can be dispersed to six fixed recipients via Disperse().
 *         Any ERC/BEP-20 token can be rescued by the owner.
 *         Recipient addresses are owner-configurable with a 48-hour cooldown guard.
 *         Ownership is two-step transferrable.
 *
 * Split (basis points / 10 000):
 *   CR8  40 %  (4000 bps)
 *   MTN  14 %  (1400 bps)
 *   BB    8 %   (800 bps)  ← receives remainder to absorb rounding dust
 *   TW    8 %   (800 bps)
 *   HK    8 %   (800 bps)
 *   KJC  22 %  (2200 bps)
 */
contract Collector {

    // ─── ownership ──────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;

    event OwnershipTransferInitiated(address indexed proposed);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Collector: not owner");
        _;
    }

    /// @notice Step 1 – owner proposes a new owner.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Collector: zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(newOwner);
    }

    /// @notice Step 2 – proposed owner accepts.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Collector: not pending owner");
        emit OwnershipTransferred(owner, msg.sender);
        owner     = msg.sender;
        pendingOwner = address(0);
    }

    // ─── recipients ─────────────────────────────────────────────────────────

    address public CR8;
    address public MTN;
    address public BB;
    address public TW;
    address public HK;
    address public KJC;

    uint256 public lastRecipientUpdate;
    uint256 private constant RECIPIENT_COOLDOWN = 48 hours;

    event RecipientsUpdated(
        address cr8,
        address mtn,
        address bb,
        address tw,
        address hk,
        address kjc
    );

    /**
     * @notice Set all six recipient addresses.
     * @dev    Enforces a 48-hour cooldown between updates.
     */
    function setRecipients(
        address cr8_,
        address mtn_,
        address bb_,
        address tw_,
        address hk_,
        address kjc_
    ) external onlyOwner {
        require(
            block.timestamp >= lastRecipientUpdate + RECIPIENT_COOLDOWN,
            "Collector: cooldown active"
        );
        require(
            cr8_ != address(0) && mtn_ != address(0) && bb_  != address(0) &&
            tw_  != address(0) && hk_  != address(0) && kjc_ != address(0),
            "Collector: zero address"
        );

        CR8 = cr8_;
        MTN = mtn_;
        BB  = bb_;
        TW  = tw_;
        HK  = hk_;
        KJC = kjc_;

        lastRecipientUpdate = block.timestamp;
        emit RecipientsUpdated(cr8_, mtn_, bb_, tw_, hk_, kjc_);
    }

    /// @notice Seconds remaining until recipients can next be updated (0 = unlocked).
    function recipientCooldownRemaining() external view returns (uint256) {
        uint256 unlockAt = lastRecipientUpdate + RECIPIENT_COOLDOWN;
        return block.timestamp >= unlockAt ? 0 : unlockAt - block.timestamp;
    }

    // ─── disperse ────────────────────────────────────────────────────────────

    uint256 public  lastDisperse;
    uint256 private constant DISPERSE_COOLDOWN = 36 hours;

    event Dispersed(uint256 total);
    event SendFailed(address indexed recipient, uint256 amount);

    /// @notice Seconds remaining until Disperse() can next be called (0 = ready).
    function disperseCooldownRemaining() external view returns (uint256) {
        uint256 unlockAt = lastDisperse + DISPERSE_COOLDOWN;
        return block.timestamp >= unlockAt ? 0 : unlockAt - block.timestamp;
    }

    /**
     * @notice Split entire BNB balance among the six recipients.
     *         Anyone may call this; enforces a 36-hour cooldown between calls.
     *         Minimum balance of 0.005 BNB required.
     *         Failed individual sends are skipped and logged via SendFailed rather
     *         than reverting, preventing a single bad recipient from locking funds.
     */
    function Disperse() external {
        require(block.timestamp >= lastDisperse + DISPERSE_COOLDOWN, "Collector: disperse cooldown active");
        require(CR8 != address(0), "Collector: recipients not set");

        uint256 balance = address(this).balance;
        require(balance >= 0.005 ether, "Collector: balance below minimum");

        lastDisperse = block.timestamp;

        // CR8 40%, MTN 14%, TW 8%, HK 8%, KJC 22%; BB receives remainder (~8%)
        uint256 toCR8 = (balance * 4000) / 10_000;
        uint256 toMTN = (balance * 1400) / 10_000;
        uint256 toTW  = (balance *  800) / 10_000;
        uint256 toHK  = (balance *  800) / 10_000;
        uint256 toKJC = (balance * 2200) / 10_000;
        uint256 toBB  = balance - toCR8 - toMTN - toTW - toHK - toKJC;

        _sendBNB(CR8, toCR8);
        _sendBNB(MTN, toMTN);
        _sendBNB(TW,  toTW);
        _sendBNB(HK,  toHK);
        _sendBNB(KJC, toKJC);
        _sendBNB(BB,  toBB);

        emit Dispersed(balance);
    }

    // ─── token rescue ────────────────────────────────────────────────────────

    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Rescue ERC/BEP-20 tokens accidentally sent to this contract.
     * @param  token   Token contract address.
     * @param  amount  Amount to rescue; pass 0 to rescue entire balance.
     */
    function rescueToken(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Collector: zero address");
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 toSend = amount == 0 ? bal : amount;
        require(toSend > 0 && toSend <= bal, "Collector: invalid amount");
        require(IERC20(token).transfer(owner, toSend), "Collector: transfer failed");
        emit TokenRescued(token, owner, toSend);
    }

    // ─── internals ───────────────────────────────────────────────────────────

    function _sendBNB(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) emit SendFailed(to, amount);
    }

    // ─── constructor / receive ───────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}
}
