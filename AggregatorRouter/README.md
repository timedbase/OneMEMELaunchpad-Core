# OneMEME AggregatorRouter

A platform-agnostic swap aggregator built on an adapter pattern. Any DEX, AMM, or trading platform can be integrated by deploying a new adapter contract and registering it — no upgrades to the core aggregator required.

---

## Architecture

```
OneMEMEAggregator.sol          Core router — fee, registry, dispatch
│
├── interfaces/
│   └── IAdapter.sol           Interface every adapter must implement
│
└── adapters/
    ├── BaseAdapter.sol        Abstract base — shared helpers + onlyAggregator guard
    ├── GenericV2Adapter.sol   Any Uniswap V2-compatible DEX
    └── GenericV3Adapter.sol   Any Uniswap V3-compatible DEX
```

### How a swap flows

```
User
  │  swap(adapterId, tokenIn, amountIn, tokenOut, minOut, to, deadline, adapterData)
  ▼
OneMEMEAggregator
  │  1. Check block.timestamp <= deadline
  │  2. Validate adapter is registered and enabled
  │  3. Pull gross amountIn from user; measure actual received (FoT safe)
  │  4. Deduct 1% fee on actual received → feeRecipient
  │  5. Transfer net 99% directly to the adapter's address
  │  6. Call adapter.execute(tokenIn, netIn, tokenOut, minOut, to, adapterData)
  ▼
Adapter (GenericV2 / GenericV3 / custom)
  │  1. Validate adapterData (path endpoints, path byte alignment)
  │  2. Read _selfBalance(tokenIn) — actual held amount after any FoT deduction
  │  3. Approve DEX router for actualIn
  │  4. Execute the DEX-specific swap
  │  5. Reset approval to 0
  │  6. Assert amountOut >= minOut (adapter-level slippage guard)
  │  7. Deliver output tokens / native BNB to `to`
  ▼
Recipient (`to`)
```

All routing logic and quotes are built **offchain**. The aggregator is a pure executor.

---

## Fee Model

| Parameter | Value |
|-----------|-------|
| Fee rate | 1% (100 bps) |
| Collected in | Input asset (BNB or ERC-20) |
| Fee basis | Actual received amount (not declared `amountIn`) |
| Recipient | `feeRecipient` (configurable by owner) |

The fee is deducted from the gross input before the swap. The recipient receives the DEX's full output on the net 99%.

For fee-on-transfer input tokens, the aggregator measures the actual balance delta after `transferFrom` and computes the fee on that — not on the declared `amountIn`. This prevents a transfer-failure when the adapter subsequently sends tokens to the DEX.

---

## Slippage Protection

Two independent layers protect every swap:

**1. Deadline (time-based)**

The `deadline` parameter on `swap()` is checked at aggregator entry before any state changes:

```solidity
if (block.timestamp > deadline) revert DeadlineExpired();
```

This uniformly covers all DEX types. V3 routers (SwapRouter02 / PancakeSwap V3 SmartRouter) removed `deadline` from their swap structs — the aggregator-level check fills that gap. V2 routers enforce deadline redundantly inside adapterData at the DEX level.

**2. Minimum output (price-based)**

`minOut` flows from caller → aggregator → adapter → DEX. Enforcement is layered:

| Layer | Mechanism |
|-------|-----------|
| DEX router (V2) | Internal balance-delta check at `to` inside `*SupportingFeeOnTransferTokens` variants |
| DEX router (V3) | `amountOutMinimum` enforced in `exactInputSingle` / `exactInput` |
| Adapter (V2, token output) | `if (amountOut < minOut) revert InsufficientOutput()` after balance delta |

The adapter-level guard on V2 catches fee-on-transfer **output** tokens: the DEX checks the gross output sent to `to`, but if `tokenOut` is itself FoT, `to` may receive less than `minOut` after the token's own transfer fee. The balance-delta measurement at the adapter catches this and reverts.

V2 BNB output is exempt from the adapter check — BNB is not FoT and the DEX delivers it directly to `to`, making it untrackable from the adapter. The DEX's own `minOut` enforcement is sufficient.

---

## Native BNB Convention

Both the aggregator and all adapters share a single sentinel:

| Value | Meaning |
|-------|---------|
| `tokenIn == address(0)` | Native BNB input — caller attaches BNB as `msg.value`; `amountIn` is ignored |
| `tokenOut == address(0)` | Native BNB output — recipient receives unwrapped BNB |

---

## Deployed Adapters (BSC Mainnet)

Deploy one instance of each adapter per DEX. Register them in the aggregator with the IDs below.

### GenericV2Adapter

| Registry ID (bytes32) | DEX | Router address |
|-----------------------|-----|----------------|
| `keccak256("PANCAKE_V2")` | PancakeSwap V2 | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |
| `keccak256("UNISWAP_V2")` | Uniswap V2 | `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24` |
| `keccak256("BISWAP")` | BiSwap | `0x3a6d8cA21a1a8D877Cb20E2E86a6F5F14f2b6e5B` |

**Constructor:**
```solidity
new GenericV2Adapter(aggregatorAddress, dexRouterAddress, "PancakeSwap V2")
```

`weth` is automatically read from `router.WETH()` at construction and stored as an `immutable`. No runtime external call is needed for path validation.

### GenericV3Adapter

| Registry ID (bytes32) | DEX | Router address |
|-----------------------|-----|----------------|
| `keccak256("PANCAKE_V3")` | PancakeSwap V3 | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` |
| `keccak256("UNISWAP_V3")` | Uniswap V3 | `0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2` |

**Constructor:**
```solidity
new GenericV3Adapter(
    aggregatorAddress,
    dexRouterAddress,
    0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,  // WBNB on BSC
    "PancakeSwap V3"
)
```

---

## Offchain Data Encoding

The `adapterData` bytes field is built offchain and passed through the aggregator unchanged to the adapter. Each adapter defines its own encoding.

### Full `swap()` call signature

```js
aggregator.swap(
  adapterId,    // bytes32 — keccak256(abi.encodePacked("PANCAKE_V2")) etc.
  tokenIn,      // address — address(0) for native BNB
  amountIn,     // uint256 — ignored when tokenIn == address(0)
  tokenOut,     // address — address(0) for native BNB output
  minOut,       // uint256 — minimum acceptable output
  to,           // address — output recipient
  deadline,     // uint256 — unix timestamp; reverts if block.timestamp > deadline
  adapterData   // bytes   — adapter-specific encoding below
)
```

---

### GenericV2Adapter

```js
const adapterData = ethers.AbiCoder.defaultAbiCoder().encode(
  ['address[]', 'uint256'],
  [path, deadline]
)
```

| Field | Description |
|-------|-------------|
| `path` | Ordered token addresses. **Must use the real WBNB address for native BNB legs.** `path[0]` must match `tokenIn` (or WBNB when `tokenIn == address(0)`). `path[last]` must match `tokenOut` (or WBNB when `tokenOut == address(0)`). Mismatches revert with `InvalidPath`. Length 2 = single-hop, length 3+ = multi-hop. |
| `deadline` | Unix timestamp enforced by the DEX router. Set to `block.timestamp + 60` at quote time. |

**Examples:**

```js
// BNB → TOKEN (single-hop)
// tokenIn = address(0), msg.value = gross BNB
path = [WBNB, TOKEN]

// TOKEN → BNB (single-hop)
// tokenOut = address(0)
path = [TOKEN, WBNB]

// TOKEN_A → TOKEN_B → TOKEN_C (multi-hop)
path = [TOKEN_A, TOKEN_B, TOKEN_C]

// BNB → TOKEN_A → TOKEN_B (multi-hop)
// tokenIn = address(0)
path = [WBNB, TOKEN_A, TOKEN_B]
```

---

### GenericV3Adapter — Single-hop

```js
const innerData = ethers.AbiCoder.defaultAbiCoder().encode(
  ['uint24', 'uint160'],
  [poolFee, 0n]  // 0 = no price limit
)

const adapterData = ethers.AbiCoder.defaultAbiCoder().encode(
  ['bool', 'bytes'],
  [false, innerData]
)
```

| Field | Description |
|-------|-------------|
| `poolFee` | Pool fee tier in hundredths of a bip: `100`, `500`, `2500`, or `10000` |
| `sqrtPriceLimitX96` | Price limit. Pass `0` for no limit (standard for aggregators). |

---

### GenericV3Adapter — Multi-hop

```js
// Build the packed V3 path
const v3Path = ethers.solidityPacked(
  ['address', 'uint24', 'address', 'uint24', 'address'],
  [TOKEN_A, fee0, TOKEN_B, fee1, TOKEN_C]
)

const adapterData = ethers.AbiCoder.defaultAbiCoder().encode(
  ['bool', 'bytes'],
  [true, v3Path]
)
```

| Field | Description |
|-------|-------------|
| V3 path | `abi.encodePacked(tokenA, fee0, tokenB, fee1, tokenC, ...)` Minimum 43 bytes (20+3+20). Each additional hop adds 23 bytes (3+20). The adapter validates both minimum length and byte alignment — a malformed path reverts with `InvalidPath`. Use real WBNB address for native BNB legs. |

**Fee tiers on BSC:**

| Tier | Use case |
|------|----------|
| `100` | Stable pairs (0.01%) |
| `500` | Stable / correlated pairs (0.05%) |
| `2500` | Standard pairs (0.25%) |
| `10000` | Exotic / volatile pairs (1%) |

---

### OneMEMEAdapter

Trades tokens that are still on the OneMEME launchpad bonding curve (pre-migration only).
Once a token migrates to a DEX, use a `GenericV2Adapter` or `GenericV3Adapter` instead.

| Registry ID (bytes32) | Contract |
|-----------------------|----------|
| `keccak256("ONEMEME_BC")` | `BondingCurve` contract address |

Only two directions are supported:

| `tokenIn` | `tokenOut` | Action |
|-----------|------------|--------|
| `address(0)` (BNB) | launchpad token | Buy on bonding curve |
| launchpad token | `address(0)` (BNB) | Sell on bonding curve |

**Constructor:**
```solidity
new OneMEMEAdapter(aggregatorAddress, bondingCurveAddress)
```

**`adapterData` encoding:**
```js
const adapterData = ethers.AbiCoder.defaultAbiCoder().encode(
  ['address', 'uint256'],
  [tokenAddress, deadline]   // token = the specific launchpad token; deadline forwarded to BC
)
```

| Field | Description |
|-------|-------------|
| `token` | The launchpad token being bought (`tokenOut`) or sold (`tokenIn`). Validated against `tokenIn`/`tokenOut` — mismatch reverts with `TokenMismatch`. |
| `deadline` | Unix timestamp forwarded to the bonding curve's own deadline check. Set to `block.timestamp + 60` at quote time. |

**Buy — BNB → Token:**
```js
// tokenIn  = address(0)  (attach BNB as msg.value)
// tokenOut = launchpadTokenAddress
aggregator.swap(
  keccak256("ONEMEME_BC"), address(0), 0n,
  tokenAddress, minTokensOut,
  recipient, outerDeadline,
  adapterData,
  { value: grossBNB }
)
```

**Sell — Token → BNB:**
```js
// tokenIn  = launchpadTokenAddress
// tokenOut = address(0)
aggregator.swap(
  keccak256("ONEMEME_BC"), tokenAddress, tokenAmount,
  address(0), minBNBOut,
  recipient, outerDeadline,
  adapterData
)
```

> **Note:** The bonding curve may refund excess BNB to the adapter when buying near the migration cap. The adapter forwards any such refund to `to` alongside the purchased tokens.

---

## Adding a New Platform

To integrate a new DEX, CEX bridge, lending protocol, or any other platform:

**1. Write the adapter**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import "./BaseAdapter.sol";

contract MyPlatformAdapter is BaseAdapter {

    address public immutable myPlatformContract;

    constructor(address aggregator_, address platform_)
        BaseAdapter(aggregator_)
    {
        if (platform_ == address(0)) revert ZeroAddress();
        myPlatformContract = platform_;
    }

    function name() external pure override returns (string memory) {
        return "My Platform";
    }

    function execute(
        address        tokenIn,
        uint256        amountIn,
        address        tokenOut,
        uint256        minOut,
        address        to,
        bytes calldata data
    ) external payable override onlyAggregator returns (uint256 amountOut) {
        // 1. Decode platform-specific params from `data`
        // 2. For ERC-20 input: use _selfBalance(tokenIn) as actual working amount
        // 3. _approve(tokenIn, myPlatformContract, actualIn)
        // 4. Execute the swap, deliver output to `to`
        // 5. _resetApproval(tokenIn, myPlatformContract)
        // 6. if (amountOut < minOut) revert InsufficientOutput()
    }
}
```

**Available helpers from BaseAdapter:**

| Helper | Description |
|--------|-------------|
| `_approve(token, spender, amount)` | USDT-safe approve — resets to 0 first, then sets |
| `_resetApproval(token, spender)` | Resets allowance to 0 after a swap completes |
| `_selfBalance(token)` | This adapter's current token balance — use instead of `amountIn` for ERC-20 inputs |
| `_balanceOf(token, account)` | Token balance of any address — used to measure output deltas |
| `_safeTransfer(token, to, amount)` | Low-level transfer (handles no-return tokens) |
| `_sendNative(to, amount)` | Send native BNB |
| `_unwrapAndSend(wbnb, amount, to)` | Unwrap WBNB → BNB and forward |

**Errors available to all adapters (declared in BaseAdapter):**

| Error | When to use |
|-------|-------------|
| `NotAggregator()` | Caller is not the registered aggregator (thrown by `onlyAggregator`) |
| `InsufficientOutput()` | `amountOut < minOut` after the swap |
| `TransferFailed()` | Token transfer or approval failed |
| `NativeSendFailed()` | Native BNB send failed |
| `ZeroAddress()` | Constructor received a zero address |

**2. Deploy and register**

```solidity
MyPlatformAdapter adapter = new MyPlatformAdapter(aggregatorAddress, platformAddress);

aggregator.registerAdapter(
    keccak256(abi.encodePacked("MY_PLATFORM")),
    address(adapter),
    true   // enabled immediately
);
```

No changes to `OneMEMEAggregator.sol` required.

---

## Aggregator Admin Reference

| Function | Description |
|----------|-------------|
| `registerAdapter(id, addr, enabled)` | Register a new adapter |
| `enableAdapter(id)` | Re-enable a disabled adapter |
| `disableAdapter(id)` | Pause an adapter without removing it |
| `upgradeAdapter(id, newAddr)` | Swap implementation without changing the registry ID |
| `setFeeRecipient(addr)` | Update the address that receives the 1% fee |
| `transferOwnership(addr)` | Step 1 of two-step ownership transfer |
| `acceptOwnership()` | Step 2 — new owner accepts |
| `rescueTokens(token, recipient, amount)` | Recover stuck ERC-20 tokens |
| `rescueNative(recipient, amount)` | Recover stuck BNB |

### Registry view functions

```solidity
aggregator.adapterCount()              // total registered adapters
aggregator.adapterAt(index)            // (id, addr, enabled, name) at index
aggregator.allAdapterIds()             // all bytes32 IDs
aggregator.adapters(id)                // (addr, enabled, name) for a specific ID
```

---

## Security Properties

| Property | How it is enforced |
|----------|--------------------|
| Only the aggregator calls adapters | `onlyAggregator` on `execute()` — by the time execute() is called, tokens are already in the adapter; without this guard anyone could drain them |
| Reentrancy | `nonReentrant` on `aggregator.swap()` |
| Time-based slippage (deadline) | `block.timestamp > deadline` check at aggregator entry — covers V3 routers that no longer accept deadline in their swap structs |
| Price-based slippage (minOut) | Enforced at DEX level for all routes; additionally checked via balance delta in V2 token-output branches (`if (amountOut < minOut) revert InsufficientOutput()`) |
| Fee-on-transfer input tokens | Aggregator measures actual received balance delta after `transferFrom`; adapters use `_selfBalance(tokenIn)` as working amount — never the nominal `amountIn` |
| Fee-on-transfer output tokens | V2 adapter measures balance delta at recipient after the swap and asserts `>= minOut` |
| Residual approvals | `_resetApproval` called after every DEX swap — no lingering allowances on DEX routers |
| Path cross-validation (V2) | Adapter asserts `path[0]` matches `tokenIn` and `path[last]` matches `tokenOut` before executing; mismatches revert with `InvalidPath` |
| Path byte alignment (V3 multi-hop) | `(length - 20) % 23 == 0` checked before executing; malformed paths revert with `InvalidPath` |
| Calldata cannot target arbitrary contracts | Each adapter has its DEX router hardcoded as an `immutable` — `adapterData` only controls parameters, never the target address |
| Non-standard ERC-20 support | All transfers use low-level calls; return value decoded only if present (handles USDT-style `void` returns) |
| USDT-style approve | `_approve` resets allowance to 0 before setting a new value |
| Registry mutations are owner-only | `onlyOwner` on all `registerAdapter`, `enableAdapter`, `disableAdapter`, `upgradeAdapter` calls |
| Two-step ownership | `transferOwnership` + `acceptOwnership` — prevents locking the contract by mistyping a new owner |
| `upgradeAdapter` CEI order | `IAdapter(newAddr).name()` is called and cached before any state is written |
| BC token identity (OneMEMEAdapter) | `adapterData.token` is validated against `tokenIn`/`tokenOut` before calling the bonding curve — mismatch reverts with `TokenMismatch` |
| BC BNB refund forwarding | Buy near migration cap may return excess BNB to the adapter; adapter forwards `address(this).balance` to `to` after token delivery |
| Unsupported directions (OneMEMEAdapter) | Token→Token and BNB→BNB revert with `UnsupportedDirection` — only BNB↔Token pairs are valid on a bonding curve |
