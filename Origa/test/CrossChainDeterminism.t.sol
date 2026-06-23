// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {OrigaVaultFactory} from "../src/OrigaVaultFactory.sol";
import {OrigaVaultLite} from "../src/OrigaVaultLite.sol";
import {OrigaVault} from "../src/OrigaVault.sol";
import {OrigaVaultUltra} from "../src/OrigaVaultUltra.sol";
import {OrigaVaultMax} from "../src/OrigaVaultMax.sol";

/// Proves cross-chain address determinism across all four target chains at once: the same
/// wallet, deploying the same vault type with the same salt, gets the same vault address on
/// every chain -- as long as the factory and every implementation are themselves deployed
/// via the canonical CREATE2 deployer proxy using identical bytecode, constructor args, and
/// salt (exactly what script/DeployOriga.s.sol does).
contract CrossChainDeterminismTest is Test {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address factoryOwner = makeAddr("factoryOwner");
    address creator      = makeAddr("creator");

    bytes32 constant FACTORY_SALT = keccak256("Origa.Factory.v1");
    bytes32 constant LITE_SALT    = keccak256("Origa.VaultLite.v1");
    bytes32 constant VAULT_SALT   = keccak256("Origa.Vault.v1");
    bytes32 constant ULTRA_SALT   = keccak256("Origa.VaultUltra.v1");
    bytes32 constant MAX_SALT     = keccak256("Origa.VaultMax.v1");
    bytes32 constant USER_SALT    = keccak256("alice-personal-vault-1");

    struct DeployResult {
        address factory;
        address liteImpl;
        address vaultImpl_;
        address ultraImpl;
        address maxImpl;
        address predictedLiteVault;
        address actualLiteVault;
    }

    function _create2Deploy(bytes32 salt, bytes memory initcode) internal returns (address deployed) {
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initcode));
        require(ok, "create2 deployer call failed");
        require(ret.length == 20, "unexpected return length from deployer");
        assembly { deployed := shr(96, mload(add(ret, 0x20))) }
        require(deployed.code.length > 0, "deployment produced no code");
    }

    function _deployEverything() internal returns (DeployResult memory r) {
        bytes memory factoryInitcode = abi.encodePacked(
            type(OrigaVaultFactory).creationCode, abi.encode(factoryOwner)
        );
        r.factory    = _create2Deploy(FACTORY_SALT, factoryInitcode);
        r.liteImpl   = _create2Deploy(LITE_SALT, type(OrigaVaultLite).creationCode);
        r.vaultImpl_ = _create2Deploy(VAULT_SALT, type(OrigaVault).creationCode);
        r.ultraImpl  = _create2Deploy(ULTRA_SALT, type(OrigaVaultUltra).creationCode);
        r.maxImpl    = _create2Deploy(MAX_SALT, type(OrigaVaultMax).creationCode);

        vm.startPrank(factoryOwner);
        OrigaVaultFactory(r.factory).setVaultImpl(0, r.liteImpl);
        OrigaVaultFactory(r.factory).setVaultImpl(1, r.vaultImpl_);
        OrigaVaultFactory(r.factory).setVaultImpl(2, r.ultraImpl);
        OrigaVaultFactory(r.factory).setVaultImpl(3, r.maxImpl);
        vm.stopPrank();

        r.predictedLiteVault = OrigaVaultFactory(r.factory).computeVaultAddress(creator, USER_SALT, 0);

        bytes memory initData = abi.encodeWithSelector(OrigaVaultLite.init.selector, creator);
        vm.prank(creator);
        r.actualLiteVault = OrigaVaultFactory(r.factory).createVault(0, USER_SALT, initData);
    }

    function testDeterminismAcross4Chains() public {
        vm.createSelectFork("ethereum");
        DeployResult memory eth = _deployEverything();
        assertEq(eth.predictedLiteVault, eth.actualLiteVault, "Ethereum: predicted != actual");

        vm.createSelectFork("bsc");
        DeployResult memory bsc = _deployEverything();
        assertEq(bsc.predictedLiteVault, bsc.actualLiteVault, "BSC: predicted != actual");

        vm.createSelectFork("polygon");
        DeployResult memory pol = _deployEverything();
        assertEq(pol.predictedLiteVault, pol.actualLiteVault, "Polygon: predicted != actual");

        vm.createSelectFork("base");
        DeployResult memory base = _deployEverything();
        assertEq(base.predictedLiteVault, base.actualLiteVault, "Base: predicted != actual");

        emit log_string("==== Cross-chain determinism: Ethereum / BSC / Polygon / Base ====");
        emit log_named_address("Ethereum factory", eth.factory);
        emit log_named_address("BSC factory      ", bsc.factory);
        emit log_named_address("Polygon factory  ", pol.factory);
        emit log_named_address("Base factory     ", base.factory);
        emit log_named_address("Ethereum vault   ", eth.actualLiteVault);
        emit log_named_address("BSC vault        ", bsc.actualLiteVault);
        emit log_named_address("Polygon vault    ", pol.actualLiteVault);
        emit log_named_address("Base vault       ", base.actualLiteVault);

        // Factory addresses identical across all four.
        assertEq(eth.factory, bsc.factory, "factory: ethereum != bsc");
        assertEq(bsc.factory, pol.factory, "factory: bsc != polygon");
        assertEq(pol.factory, base.factory, "factory: polygon != base");

        // Every implementation identical across all four.
        assertEq(eth.liteImpl, bsc.liteImpl);   assertEq(bsc.liteImpl, pol.liteImpl);   assertEq(pol.liteImpl, base.liteImpl);
        assertEq(eth.vaultImpl_, bsc.vaultImpl_); assertEq(bsc.vaultImpl_, pol.vaultImpl_); assertEq(pol.vaultImpl_, base.vaultImpl_);
        assertEq(eth.ultraImpl, bsc.ultraImpl);  assertEq(bsc.ultraImpl, pol.ultraImpl);  assertEq(pol.ultraImpl, base.ultraImpl);
        assertEq(eth.maxImpl, bsc.maxImpl);     assertEq(bsc.maxImpl, pol.maxImpl);     assertEq(pol.maxImpl, base.maxImpl);

        // The actual headline property: final deployed vault address identical everywhere.
        assertEq(eth.actualLiteVault, bsc.actualLiteVault, "VAULT: ethereum != bsc");
        assertEq(bsc.actualLiteVault, pol.actualLiteVault, "VAULT: bsc != polygon");
        assertEq(pol.actualLiteVault, base.actualLiteVault, "VAULT: polygon != base");
    }
}
