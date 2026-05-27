// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OneDex} from "../src/OneDex.sol";

/// @dev Deploy OneDex on a single chain. Set the CHAIN env var to "bsc" or "eth".
contract Deploy is Script {

    // ── Shared ────────────────────────────────────────────────────────────────
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ── BSC ───────────────────────────────────────────────────────────────────
    address constant BSC_WBNB          = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BSC_CAKE_V2_FAC   = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant BSC_UNI_V3_FAC    = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;
    address constant BSC_CAKE_V3_FAC   = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    // ── Ethereum Mainnet ──────────────────────────────────────────────────────
    address constant ETH_WETH          = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ETH_UNI_V2_FAC    = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant ETH_UNI_V3_FAC    = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant ETH_CAKE_V3_FAC   = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    function run() external {
        uint256 pk           = vm.envUint("PRIVATE_KEY");
        address deployer     = vm.addr(pk);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        string  memory chain = vm.envOr("CHAIN", string("bsc"));

        address wNative;
        address uniV2Fac;
        address cakeV2Fac;
        address uniV3Fac;
        address cakeV3Fac;

        if (keccak256(bytes(chain)) == keccak256("eth")) {
            wNative  = ETH_WETH;
            uniV2Fac = ETH_UNI_V2_FAC;
            cakeV2Fac = address(0);
            uniV3Fac = ETH_UNI_V3_FAC;
            cakeV3Fac = ETH_CAKE_V3_FAC;
        } else {
            // default: BSC
            wNative  = BSC_WBNB;
            uniV2Fac = address(0);
            cakeV2Fac = BSC_CAKE_V2_FAC;
            uniV3Fac = BSC_UNI_V3_FAC;
            cakeV3Fac = BSC_CAKE_V3_FAC;
        }

        vm.startBroadcast(pk);

        OneDex dex = new OneDex(
            wNative,
            PERMIT2,
            feeRecipient,
            uniV2Fac,
            cakeV2Fac,
            uniV3Fac,
            cakeV3Fac
        );

        vm.stopBroadcast();

        console.log("=== 1Dex Deployment (%s) ===", chain);
        console.log("OneDex:          ", address(dex));
        console.log("Owner:           ", deployer);
        console.log("FeeRecipient:    ", feeRecipient);
        console.log("WNATIVE:         ", wNative);
        console.log("Permit2:         ", PERMIT2);
        console.log("UNI_V2_FACTORY:  ", uniV2Fac);
        console.log("CAKE_V2_FACTORY: ", cakeV2Fac);
        console.log("UNI_V3_FACTORY:  ", uniV3Fac);
        console.log("CAKE_V3_FACTORY: ", cakeV3Fac);
    }
}
