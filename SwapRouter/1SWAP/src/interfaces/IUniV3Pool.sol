// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUniV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee()    external view returns (uint24);
}
