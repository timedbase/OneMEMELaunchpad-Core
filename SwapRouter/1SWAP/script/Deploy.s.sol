// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OneDex} from "../src/OneDex.sol";

contract Deploy is Script {

    address constant WBNB             = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant PANCAKE_V2       = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant PANCAKE_V3       = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant UNISWAP_V2       = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address constant FOURMEME_H3      = 0xF251F83e40a78868FcfA3FA4599Dad6494E46034;
    address constant FLAPSH           = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // V3 factories (used for callback validation)
    address constant UNI_V3_FACTORY   = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F; // Uniswap V3 BSC
    address constant CAKE_V3_FACTORY  = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865; // PancakeSwap V3 BSC

    function run() external {
        uint256 pk           = vm.envUint("PRIVATE_KEY");
        address deployer     = vm.addr(pk);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address bondingCurve = vm.envOr("BONDING_CURVE", address(0));

        vm.startBroadcast(pk);

        OneDex dex = new OneDex(WBNB, PERMIT2, feeRecipient, UNI_V3_FACTORY, CAKE_V3_FACTORY);

        uint256 count = bondingCurve != address(0) ? 6 : 5;
        address[] memory targets = new address[](count);
        targets[0] = WBNB;
        targets[1] = PANCAKE_V2;
        targets[2] = PANCAKE_V3;
        targets[3] = UNISWAP_V2;
        targets[4] = FOURMEME_H3;
        if (bondingCurve != address(0)) targets[5] = bondingCurve;

        dex.addTargets(targets);
        dex.addTarget(FLAPSH);

        vm.stopBroadcast();

        console.log("=== 1Dex Deployment ===");
        console.log("OneDex:       ", address(dex));
        console.log("Owner:        ", deployer);
        console.log("FeeRecipient: ", feeRecipient);
        console.log("WBNB:         ", WBNB);
        console.log("Permit2:      ", PERMIT2);
        console.log("UniV3Factory: ", UNI_V3_FACTORY);
        console.log("CakeV3Factory:", CAKE_V3_FACTORY);
        console.log("Targets:");
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
