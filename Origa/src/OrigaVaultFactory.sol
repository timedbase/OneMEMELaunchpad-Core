// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Deploys EIP-1167 minimal-proxy clones of registered vault implementations via CREATE2.
//
// Cross-chain address determinism
// --------------------------------
// Requirement: the same wallet deploying the same vault type with the same salt on chain A
// and chain B must get the same vault address on both.
//
// CREATE2's address is a pure function of (deployer, salt, initCodeHash). This contract
// already keeps `salt` and `initCodeHash` chain-agnostic:
//   - `_vaultSalt(creator, salt)` never reads chain id, block data, or this factory's own
//     address — only `creator` and the caller-supplied `salt`.
//   - the EIP-1167 init code only embeds the implementation address, nothing chain-specific.
//
// The remaining variable is `deployer`, i.e. this factory's own address, and the
// implementation address baked into the clone's init code. For the final vault address to
// match across chains, BOTH of the following must themselves be deployed at identical
// addresses on every chain:
//   1. This factory contract.
//   2. Every vault implementation registered via setVaultImpl.
//
// That is a deployment-process guarantee, not something this contract's logic can enforce
// on its own — achieve it by deploying both the factory and every implementation via a
// canonical CREATE2 deployer that already exists at the same address on every target chain
// (e.g. the deterministic deployment proxy at 0x4e59b44847b379578588920cA78FbF26c0B4956,
// present on most EVM chains including BSC), using identical bytecode, constructor
// arguments, and salt every time. Given that, `computeVaultAddress` returns the same result
// for the same (creator, salt, vaultType) on any chain.
contract OrigaVaultFactory {

    error ZeroAddress();
    error VaultCreationFailed();
    error InitFailed();
    error UnknownVaultType();
    error NotOwner();

    address public owner;
    mapping(uint8 => address) public vaultImpl; // vaultType => implementation

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event VaultImplSet(uint8 indexed vaultType, address impl);
    event VaultCreated(address indexed creator, uint8 indexed vaultType, bytes32 indexed salt, address vault);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // Set once per vaultType per chain, pointing at that vault type's implementation —
    // deploy the implementation deterministically (see contract-level note) so this points
    // at the same address on every chain.
    function setVaultImpl(uint8 vaultType, address impl) external onlyOwner {
        if (impl == address(0)) revert ZeroAddress();
        vaultImpl[vaultType] = impl;
        emit VaultImplSet(vaultType, impl);
    }

    // `initData` is the ABI-encoded call to the chosen vault type's own init function
    // (e.g. OrigaVaultLite.init(address) or OrigaVaultMax.init(address[],uint256)) — the
    // caller builds this for whichever vaultType they're deploying.
    function createVault(uint8 vaultType, bytes32 salt, bytes calldata initData) external returns (address vault) {
        address impl = vaultImpl[vaultType];
        if (impl == address(0)) revert UnknownVaultType();

        vault = _clone(impl, _vaultSalt(msg.sender, salt));

        (bool ok, ) = vault.call(initData);
        if (!ok) revert InitFailed();

        emit VaultCreated(msg.sender, vaultType, salt, vault);
    }

    function computeVaultAddress(address creator, bytes32 salt, uint8 vaultType) external view returns (address vault) {
        address impl = vaultImpl[vaultType];
        if (impl == address(0)) revert UnknownVaultType();
        bytes32 initCodeHash = keccak256(_cloneInitCode(impl));
        bytes32 vaultSalt    = _vaultSalt(creator, salt);
        vault = address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), address(this), vaultSalt, initCodeHash)
        ))));
    }

    // The salt actually fed to CREATE2 is derived from (creator, salt) only — this factory's
    // own address is deliberately excluded from the pre-image. CREATE2 still folds the
    // deployer (this factory) into the final on-chain address per its own formula, but a
    // vault's *logical* identity (which creator, which chosen salt) never depends on which
    // factory instance deployed it.
    function _vaultSalt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(creator, salt));
    }

    function _cloneInitCode(address impl) private pure returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            impl,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
    }

    // EIP-1167 minimal proxy via CREATE2 — salt already excludes this factory's address (see _vaultSalt).
    function _clone(address impl, bytes32 salt) private returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0)) revert VaultCreationFailed();
    }
}
