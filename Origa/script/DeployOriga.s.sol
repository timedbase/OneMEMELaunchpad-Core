// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Script, console} from "forge-std/Script.sol";
import {OrigaVaultFactory} from "../src/OrigaVaultFactory.sol";
import {OrigaVaultLite} from "../src/OrigaVaultLite.sol";
import {OrigaVault} from "../src/OrigaVault.sol";
import {OrigaVaultUltra} from "../src/OrigaVaultUltra.sol";
import {OrigaVaultMax} from "../src/OrigaVaultMax.sol";

/// @notice Deploys the Origa factory and all four vault implementations deterministically
/// via the canonical CREATE2 deployer proxy, so that running this exact script on any chain
/// (where that proxy exists) produces identical addresses everywhere.
///
/// Requirements for that determinism to actually hold:
///   1. Use the SAME deploying private key (hence the same address) on every chain you run
///      this on — that address becomes both the factory's initial owner (a constructor arg,
///      so a different owner produces different factory bytecode and therefore a different
///      deterministic address) and the broadcaster, which must match `owner` for the
///      setVaultImpl calls below to succeed. Transfer ownership to a permanent multisig in a
///      separate follow-up call afterward if desired — that only changes storage, not the
///      factory's address.
///   2. Never change the salts below once any chain has used them for a real deployment.
///   3. Run with the same compiler/optimizer settings (this repo's foundry.toml) every time —
///      changing them changes each contract's bytecode, hence its CREATE2 address.
///
/// Usage:
///   PRIVATE_KEY=0x... forge script script/DeployOriga.s.sol --rpc-url <rpc> --broadcast
///
/// Idempotent: if a contract already exists at its predicted address on the target chain
/// (e.g. re-running on a chain where this was already deployed), deployment is skipped and
/// the existing address is reused/reported instead of reverting.
contract DeployOriga is Script {

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant FACTORY_SALT = keccak256("Origa.Factory.v1");
    bytes32 constant LITE_SALT    = keccak256("Origa.VaultLite.v1");
    bytes32 constant VAULT_SALT   = keccak256("Origa.Vault.v1");
    bytes32 constant ULTRA_SALT   = keccak256("Origa.VaultUltra.v1");
    bytes32 constant MAX_SALT     = keccak256("Origa.VaultMax.v1");

    // Vault type IDs as registered in OrigaVaultFactory.vaultImpl.
    uint8 constant TYPE_LITE  = 0;
    uint8 constant TYPE_VAULT = 1;
    uint8 constant TYPE_ULTRA = 2;
    uint8 constant TYPE_MAX   = 3;

    function run() external {
        uint256 pk    = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk); // deployer is the initial owner; transfer later if desired

        require(CREATE2_DEPLOYER.code.length > 0, "canonical CREATE2 deployer not present on this chain");

        vm.startBroadcast(pk);

        address factory = _deploy(FACTORY_SALT, abi.encodePacked(type(OrigaVaultFactory).creationCode, abi.encode(owner)));
        address liteImpl  = _deploy(LITE_SALT, type(OrigaVaultLite).creationCode);
        address vaultImpl_ = _deploy(VAULT_SALT, type(OrigaVault).creationCode);
        address ultraImpl = _deploy(ULTRA_SALT, type(OrigaVaultUltra).creationCode);
        address maxImpl   = _deploy(MAX_SALT, type(OrigaVaultMax).creationCode);

        _registerIfNeeded(factory, TYPE_LITE, liteImpl);
        _registerIfNeeded(factory, TYPE_VAULT, vaultImpl_);
        _registerIfNeeded(factory, TYPE_ULTRA, ultraImpl);
        _registerIfNeeded(factory, TYPE_MAX, maxImpl);

        vm.stopBroadcast();

        console.log("=== Origa Deployment ===");
        console.log("Chain ID:          ", block.chainid);
        console.log("Owner:             ", owner);
        console.log("OrigaVaultFactory: ", factory);
        console.log("OrigaVaultLite:    ", liteImpl);
        console.log("OrigaVault:        ", vaultImpl_);
        console.log("OrigaVaultUltra:   ", ultraImpl);
        console.log("OrigaVaultMax:     ", maxImpl);
    }

    function _computeAddress(bytes32 salt, bytes memory initcode) internal pure returns (address) {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initcode))
        ))));
    }

    function _deploy(bytes32 salt, bytes memory initcode) internal returns (address deployed) {
        address predicted = _computeAddress(salt, initcode);
        if (predicted.code.length > 0) {
            console.log("Already deployed, skipping:", predicted);
            return predicted;
        }

        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initcode));
        require(ok, "CREATE2 deployer call failed");
        require(ret.length == 20, "unexpected return length from deployer");
        assembly { deployed := shr(96, mload(add(ret, 0x20))) }

        require(deployed == predicted, "deployed address did not match prediction");
        require(deployed.code.length > 0, "deployment produced no code");
    }

    function _registerIfNeeded(address factory, uint8 vaultType, address impl) internal {
        if (OrigaVaultFactory(factory).vaultImpl(vaultType) == impl) return; // already set
        OrigaVaultFactory(factory).setVaultImpl(vaultType, impl);
    }
}
