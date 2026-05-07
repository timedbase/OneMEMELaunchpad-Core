// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice ERC-20 with a configurable basis-point transfer tax.
 *         Tax is deducted from the received amount on every transfer.
 *         e.g. taxBps=500 → 5 % tax → recipient gets 95 % of the nominal amount.
 */
contract MockFOTToken {
    string  public name;
    string  public symbol;
    uint8   public decimals;
    uint256 public totalSupply;

    /// @notice Tax in basis points (500 = 5 %).
    uint256 public immutable taxBps;
    address public immutable taxCollector;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8   decimals_,
        uint256 taxBps_,
        address taxCollector_
    ) {
        name         = name_;
        symbol       = symbol_;
        decimals     = decimals_;
        taxBps       = taxBps_;
        taxCollector = taxCollector_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply   += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        uint256 tax      = (amount * taxBps) / 10_000;
        uint256 netAmount = amount - tax;

        balanceOf[from]           -= amount;
        balanceOf[to]             += netAmount;
        balanceOf[taxCollector]   += tax;

        emit Transfer(from, to, netAmount);
        if (tax > 0) emit Transfer(from, taxCollector, tax);
        return true;
    }
}
