// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUniV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
