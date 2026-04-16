// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./GenericV2Adapter.sol";
import "./GenericV3Adapter.sol";
import "./GenericV4Adapter.sol";

/**
 * @title  PancakeSwapV2Adapter
 * @notice GenericV2Adapter bound to the PancakeSwap V2 router (BSC mainnet).
 *         Registry ID: keccak256("PANCAKE_V2")
 */
contract PancakeSwapV2Adapter is GenericV2Adapter {
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    constructor(address aggregator_)
        GenericV2Adapter(aggregator_, ROUTER, "PancakeSwap V2")
    {}
}

/**
 * @title  PancakeSwapV3Adapter
 * @notice GenericV3Adapter bound to the PancakeSwap V3 SmartRouter (BSC mainnet).
 *         Registry ID: keccak256("PANCAKE_V3")
 */
contract PancakeSwapV3Adapter is GenericV3Adapter {
    address private constant ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address private constant WBNB   = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    constructor(address aggregator_)
        GenericV3Adapter(aggregator_, ROUTER, WBNB, "PancakeSwap V3")
    {}
}

/**
 * @title  PancakeSwapV4Adapter
 * @notice GenericV4Adapter bound to the PancakeSwap V4 UniversalRouter (BSC mainnet).
 *         Registry ID: keccak256("PANCAKE_V4")
 */
contract PancakeSwapV4Adapter is GenericV4Adapter {
    address private constant ROUTER = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;

    constructor(address aggregator_)
        GenericV4Adapter(aggregator_, ROUTER, "PancakeSwap V4")
    {}
}
