// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AggregationExecutor} from "../src/AggregationExecutor.sol";

/**
 * @title  Deploy — 1SWAP AggregationExecutor
 * @notice Foundry deployment script for BSC mainnet.
 *
 * Usage:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $BSC_RPC_URL        \
 *     --broadcast                   \
 *     --verify                      \
 *     --etherscan-api-key $BSCSCAN_KEY
 *
 * Required env vars:
 *   PRIVATE_KEY   — deployer private key (hex, no 0x prefix)
 *   DEPLOYER      — deployer address (must match PRIVATE_KEY)
 *
 * Optional env vars (override defaults):
 *   BONDING_CURVE — OneMEME bonding curve address
 */
contract Deploy is Script {

    // ── BSC mainnet constants ────────────────────────────────────────────────
    address constant WBNB         = 0xbb4CdB9CBD36B01bD1cBaEBF2De08d9173bc095c;
    address constant PANCAKE_V2   = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant PANCAKE_V3   = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant UNISWAP_V2   = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address constant FOURMEME_H3  = 0xF251F83e40a78868FcfA3FA4599Dad6494E46034;
    address constant FLAPSH       = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;

    function run() external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER");

        // Optional override for OneMEME bonding curve
        address bondingCurve = vm.envOr("BONDING_CURVE", address(0));

        vm.startBroadcast(pk);

        AggregationExecutor executor = new AggregationExecutor(WBNB, deployer);

        // Whitelist well-known BSC DEX routers
        uint256 count = bondingCurve != address(0) ? 6 : 5;
        address[] memory targets = new address[](count);
        targets[0] = WBNB;          // WBNB itself (for wrap/unwrap steps)
        targets[1] = PANCAKE_V2;
        targets[2] = PANCAKE_V3;
        targets[3] = UNISWAP_V2;
        targets[4] = FOURMEME_H3;
        if (bondingCurve != address(0)) targets[5] = bondingCurve;

        executor.addTargets(targets);

        // FLAP.SH registered separately so the array stays under 7
        executor.addTarget(FLAPSH);

        vm.stopBroadcast();

        console.log("=== 1SWAP Deployment ===");
        console.log("AggregationExecutor:", address(executor));
        console.log("Owner:              ", deployer);
        console.log("WBNB:               ", WBNB);
        console.log("Whitelisted targets:");
        console.log("  WBNB:             ", WBNB);
        console.log("  PancakeSwap V2:   ", PANCAKE_V2);
        console.log("  PancakeSwap V3:   ", PANCAKE_V3);
        console.log("  Uniswap V2:       ", UNISWAP_V2);
        console.log("  FourMEME Helper3: ", FOURMEME_H3);
        console.log("  Flap.SH:          ", FLAPSH);
        if (bondingCurve != address(0))
            console.log("  BondingCurve:     ", bondingCurve);
    }
}
