// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {OrigaMultisigBase} from "./OrigaMultisigBase.sol";

// Fixed 3-of-4 multisig vault. Signer set and threshold are set once at init and are
// permanently immutable — this contract exposes no function capable of changing them.
contract OrigaVaultUltra is OrigaMultisigBase {

    error AlreadyInitialized();

    bool private _initialized;

    constructor() { _initialized = true; } // blocks direct use of the implementation

    function init(address[4] calldata signers_) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        address[] memory s = new address[](4);
        for (uint256 i; i < 4; i++) s[i] = signers_[i];
        _initMultisig(s, 3);
    }
}
