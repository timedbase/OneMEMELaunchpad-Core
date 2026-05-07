# 1Dex — Contract Reference

## Overview

Calldata-driven, balance-differential swap aggregation executor for BSC.
All routing logic lives off-chain. The contract is a pure executor: it validates targets,
verifies balance deltas, collects the protocol fee, and delivers output — nothing else.

## Core guarantees

1. **Never trusts router return values.** Every output is measured via before/after `balanceOf`
   snapshots (correct for FOT and rebasing tokens).
2. **Only whitelisted targets can be called.** No arbitrary code execution.
3. **Exact-approval + immediate reset.** No lingering allowances (USDT-safe).
4. **Fully stateless between executions.** All routing state lives in calldata.
5. **0.5 % protocol fee always active.** `FEE_BPS = 50`. `feeRecipient` is required at
   deployment and can never be set to `address(0)`. `minAmountOut` is always checked against
   the net (post-fee) amount.

## Step struct fields

| Field | Description |
|-------|-------------|
| `target` | Whitelisted router / AMM / bonding-curve to call |
| `value` | Native BNB to forward with the call (0 for ERC-20 only steps) |
| `callData` | Fully-encoded router calldata built off-chain |
| `approveToken` | ERC-20 to approve to `target` before the call; `address(0)` = skip |
| `approveAmt` | Exact amount to approve; executor resets to 0 after the call |
| `tokenOut` | Token this step outputs; `address(0)` = native BNB |
| `minDelta` | Minimum required balance increase for `tokenOut`; reverts with `InsufficientOutput` if not met |

## execute()

```
execute(tokenIn, amountIn, tokenOut, minAmountOut, recipient, deadline, executionData)
```

| Parameter | Description |
|-----------|-------------|
| `tokenIn` | Input token. `address(0)` = native BNB (use `msg.value`) |
| `amountIn` | Amount to pull from `msg.sender` (ignored when native BNB) |
| `tokenOut` | Final output token. `address(0)` = native BNB |
| `minAmountOut` | Minimum acceptable **net** (post-fee) output; reverts if not met |
| `recipient` | Address that receives the final output |
| `deadline` | Unix timestamp after which the call reverts |
| `executionData` | `abi.encode(bool feeOnInput, Step[])` produced by the off-chain API |

Returns: `amountOut` — net amount delivered to `recipient`.

## executeWithPermit2()

Same parameters as `execute()`, plus:

| Parameter | Description |
|-----------|-------------|
| `permit` | `IPermit2.PermitTransferFrom` struct (includes token, amount, nonce, deadline) |
| `signature` | EIP-712 signature over `permit` produced by `msg.sender` |

Native BNB input is not supported (`tokenIn == address(0)` reverts with `NativeNotPermitted`).
Users approve the canonical Permit2 contract once; no standing allowance to this executor is needed.

## Fee system

`FEE_BPS = 50` → 0.5 % protocol fee on every swap.

The off-chain API encodes fee direction as the first element of `executionData`:

```js
executionData = abi.encode(feeOnInput, steps)  // bool, Step[]
```

| `feeOnInput` | Behaviour |
|---|---|
| `true` | Fee deducted from `actualIn` **before** steps. Route calldata is built for the reduced input. |
| `false` | Fee deducted from gross output **after** steps. `minAmountOut` is checked against net. |

`feeRecipient` is set at construction and cannot be `address(0)`. It can be updated via
`setFeeRecipient` (owner only, zero address rejected).

## Native BNB semantics

- `tokenIn == address(0)` → pull from `msg.value`
- `tokenOut == address(0)` → deliver native BNB to `recipient`
- `step.tokenOut == address(0)` → measure `address(this).balance` delta
- `step.value > 0` → forward that BNB with the step call

### BNB delta formula

When a step both sends and receives native BNB, the naive `afterBal - snapBefore` would underflow
because `afterBal` is already reduced by `step.value`. The formula used is:

```
delta = address(this).balance + step.value - snapBefore
```

Derivation:
```
afterBal   = snapBefore - step.value + bnbReceived
delta      = afterBal + step.value - snapBefore
           = (snapBefore - step.value + bnbReceived) + step.value - snapBefore
           = bnbReceived    ← always ≥ 0, no underflow
```

## WBNB wrap/unwrap

Steps can target WBNB directly (`deposit` / `withdraw`) — whitelist it like any other router.
The off-chain API inserts wrap/unwrap steps wherever the route needs them.

## Off-chain API usage

The off-chain API builds one `Step` per router call and ABI-encodes the route into `executionData`:

```js
executionData = abi.encode(feeOnInput, steps)  // bool, Step[]
```

The executor decodes and runs each step sequentially, enforcing `step.minDelta` per step and
`minAmountOut` on the final net output.

## Immutables

| Name | Description |
|------|-------------|
| `WBNB` | WBNB contract address (stored for off-chain convenience; not used in execution logic) |
| `PERMIT2` | Canonical Permit2 contract (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) |

## Ownership

Two-step: `transferOwnership(newOwner)` proposes, `acceptOwnership()` confirms.
Only the pending owner can accept. The old owner remains in control until acceptance.

## Deployment

Required constructor arguments (all non-zero enforced):

| Arg | Description |
|-----|-------------|
| `wbnb_` | WBNB contract address |
| `initialOwner` | Initial contract owner |
| `permit2_` | Canonical Permit2 address |
| `feeRecipient_` | Protocol fee recipient — **cannot be address(0)** |

Deployment script reads `FEE_RECIPIENT` from env alongside `PRIVATE_KEY`, `DEPLOYER`,
and optional `BONDING_CURVE`.

## Emergency rescue

`rescueToken(token, to, amount)` and `rescueNative(to, amount)` are `onlyOwner`.
These exist to recover tokens accidentally sent or stuck in the contract.
