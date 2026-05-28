// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OneDex} from "../src/OneDex.sol";

/// @dev Deploy OneDex on a single chain. Set the CHAIN env var to "bsc" or "eth".
contract Deploy is Script {

    // ── Shared ────────────────────────────────────────────────────────────────
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ── BSC ───────────────────────────────────────────────────────────────────
    address constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // ── Ethereum Mainnet ──────────────────────────────────────────────────────
    address constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        uint256 pk           = vm.envUint("PRIVATE_KEY");
        address deployer     = vm.addr(pk);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        string  memory chain = vm.envOr("CHAIN", string("bsc"));

        address wNative = keccak256(bytes(chain)) == keccak256("eth")
            ? ETH_WETH
            : BSC_WBNB;

        vm.startBroadcast(pk);

        OneDex dex = new OneDex(wNative, PERMIT2, feeRecipient);

        vm.stopBroadcast();

        console.log("=== 1Dex Deployment (%s) ===", chain);
        console.log("OneDex:       ", address(dex));
        console.log("Owner:        ", deployer);
        console.log("FeeRecipient: ", feeRecipient);
        console.log("WNATIVE:      ", wNative);
        console.log("Permit2:      ", PERMIT2);
    }
}
