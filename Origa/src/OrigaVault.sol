// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {OrigaMultisigBase} from "./OrigaMultisigBase.sol";

// Fixed 2-of-3 multisig vault. Signer set and threshold are set once at init and are
// permanently immutable — this contract exposes no function capable of changing them.
contract OrigaVault is OrigaMultisigBase {

    error AlreadyInitialized();

    bool private _initialized;

    constructor() { _initialized = true; } // blocks direct use of the implementation

    function init(address[3] calldata signers_) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        address[] memory s = new address[](3);
        for (uint256 i; i < 3; i++) s[i] = signers_[i];
        _initMultisig(s, 2);
    }
}
