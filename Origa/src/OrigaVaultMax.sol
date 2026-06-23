// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {OrigaMultisigBase} from "./OrigaMultisigBase.sol";

// Modular M-of-N multisig vault. Signer set and threshold can be changed after deployment
// (e.g. when someone new joins) — but only through this vault's own propose/approve/execute
// pipeline, since addSigner/removeSigner/setThreshold are gated `onlySelf`. No designated
// admin key exists; the current signers must approve any change to themselves via the same
// process used for any other vault transaction.
contract OrigaVaultMax is OrigaMultisigBase {

    error AlreadyInitialized();

    bool private _initialized;

    constructor() { _initialized = true; } // blocks direct use of the implementation

    function init(address[] calldata signers_, uint256 threshold_) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _initMultisig(signers_, threshold_);
    }

    // Reachable only via execute() calling back into this contract (target = address(this)),
    // which itself requires `threshold` current-signer approvals to have already happened.
    function addSigner(address newSigner) external onlySelf {
        if (newSigner == address(0)) revert ZeroAddress();
        if (isSigner[newSigner]) revert DuplicateSigner();
        isSigner[newSigner] = true;
        signers.push(newSigner);
        emit SignerAdded(newSigner);
    }

    function removeSigner(address signer_) external onlySelf {
        if (!isSigner[signer_]) revert SignerNotFound();
        uint256 len = signers.length;
        if (len - 1 < threshold) revert InvalidThreshold(); // lower threshold first
        isSigner[signer_] = false;
        for (uint256 i; i < len; i++) {
            if (signers[i] == signer_) {
                signers[i] = signers[len - 1];
                signers.pop();
                break;
            }
        }
        emit SignerRemoved(signer_);
    }

    function setThreshold(uint256 newThreshold) external onlySelf {
        if (newThreshold == 0 || newThreshold > signers.length) revert InvalidThreshold();
        emit ThresholdChanged(threshold, newThreshold);
        threshold = newThreshold;
    }
}
