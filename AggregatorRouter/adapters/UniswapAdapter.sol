// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./GenericV2Adapter.sol";
import "./GenericV3Adapter.sol";
import "./GenericV4Adapter.sol";

/**
 * @title  UniswapV2Adapter
 * @notice GenericV2Adapter bound to the Uniswap V2 router (BSC mainnet).
 *         Registry ID: keccak256("UNISWAP_V2")
 */
contract UniswapV2Adapter is GenericV2Adapter {
    address private constant ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;

    constructor(address aggregator_)
        GenericV2Adapter(aggregator_, ROUTER, "Uniswap V2")
    {}
}

/**
 * @title  UniswapV3Adapter
 * @notice GenericV3Adapter bound to the Uniswap V3 SwapRouter02 (BSC mainnet).
 *         Registry ID: keccak256("UNISWAP_V3")
 */
contract UniswapV3Adapter is GenericV3Adapter {
    address private constant ROUTER = 0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2;
    address private constant WBNB   = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    constructor(address aggregator_)
        GenericV3Adapter(aggregator_, ROUTER, WBNB, "Uniswap V3")
    {}
}

/**
 * @title  UniswapV4Adapter
 * @notice GenericV4Adapter bound to the Uniswap V4 UniversalRouter (BSC mainnet).
 *         Registry ID: keccak256("UNISWAP_V4")
 */
contract UniswapV4Adapter is GenericV4Adapter {
    address private constant ROUTER = 0x1906c1d672b88cD1B9aC7593301cA990F94Eae07;

    constructor(address aggregator_)
        GenericV4Adapter(aggregator_, ROUTER, "Uniswap V4")
    {}
}
