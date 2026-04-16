# FourMEMEAdapter

Aggregator adapter for trading tokens on the [FourMEME](https://four.meme) bonding curve (pre-migration only).

---

## Registry

| Registry ID (bytes32) | Value |
|-----------------------|-------|
| `keccak256("FOURMEME")` | — one instance covers all FourMEME tokens |

**Constructor:**
```solidity
new FourMEMEAdapter(aggregatorAddress)
```

No external addresses are injected at construction — all protocol contracts are hardcoded as `constant`.

---

## Protocol Addresses (BSC Mainnet)

| Constant | Role | Address |
|----------|------|---------|
| `V1_MANAGER` | TokenManager V1 — tokens created before 2024-09-05 | `0xEC4549caDcE5DA21Df6E6422d448034B5233bFbC` |
| `V2_MANAGER` | TokenManager V2 — tokens created after 2024-09-05 | `0x5c952063c7fc8610FFDB798152D69F0B9550762b` |
| `HELPER_V3` | TokenManagerHelper V3 — info queries & ERC20-pair helpers | `0xF251F83e40a78868FcfA3FA4599Dad6494E46034` |

---

## Supported Directions

| `tokenIn` | `tokenOut` | Action |
|-----------|------------|--------|
| `address(0)` (BNB) | FourMEME token | Buy on bonding curve |
| FourMEME token | `address(0)` (BNB) | Sell on bonding curve |

Token → Token and BNB → BNB revert with `UnsupportedDirection`.

---

## adapterData Encoding

```js
const adapterData = ethers.AbiCoder.defaultAbiCoder().encode(
  ['address'],
  [tokenAddress]
)
```

| Field | Description |
|-------|-------------|
| `token` | The FourMEME bonding-curve token to trade |

No deadline or path is needed — routing is resolved on-chain at execution time via `HELPER_V3.getTokenInfo()`.

---

## Swap Examples

**Buy — BNB → Token:**
```js
// tokenIn  = address(0)  (attach BNB as msg.value)
// tokenOut = fourMEMETokenAddress
aggregator.swap(
  keccak256("FOURMEME"), address(0), 0n,
  tokenAddress, minTokensOut,
  recipient, deadline,
  adapterData,
  { value: grossBNB }
)
```

**Sell — Token → BNB:**
```js
// tokenIn  = fourMEMETokenAddress
// tokenOut = address(0)
aggregator.swap(
  keccak256("FOURMEME"), tokenAddress, tokenAmount,
  address(0), minBNBOut,
  recipient, deadline,
  adapterData
)
```

---

## Routing Logic

The adapter calls `HELPER_V3.getTokenInfo(token)` on every swap to determine the correct execution path. No offchain routing hint is required.

```
getTokenInfo(token)
  │
  ├─ liquidityAdded == true  →  revert TokenMigrated()
  │
  ├─ version == 1 (pre-Sept 2024)
  │    BUY   →  V1.purchaseTokenAMAP{value}(0, token, to, netIn, minOut)
  │    SELL  →  approve V1 → V1.saleToken(token, amount) → resetApproval
  │
  ├─ version == 2, quote == address(0)  (BNB pair)
  │    BUY   →  V2.buyToken{value}(abi.encode(BuyTokenParams), 0, "")
  │    SELL  →  approve V2 → V2.sellToken(0, token, amount, minOut, 0, 0x0) → resetApproval
  │
  └─ version == 2, quote != address(0)  (ERC20-quote pair)
       BUY   →  HELPER_V3.buyWithEth{value}(0, token, to, netIn, minOut)
       SELL  →  approve HELPER_V3 → HELPER_V3.sellForEth(0, token, amount, minOut, 0, 0x0) → resetApproval
```

### V2 Buy Params (BNB pair)

The adapter uses `V2.buyToken(bytes args, 0, "")` for all V2 BNB-pair buys. This single interface handles both regular tokens and X-Mode exclusive tokens.

`args` is `abi.encode(BuyTokenParams)`:

| Field | Value |
|-------|-------|
| `origin` | `0` |
| `token` | bonding-curve token address |
| `to` | output recipient |
| `amount` | `0` (AMAP mode — spend fixed BNB) |
| `maxFunds` | `0` |
| `funds` | `netIn` (BNB to spend) |
| `minAmount` | `minOut` |

### V2 Sell (BNB pair)

`feeRate` and `feeRecipient` are passed as `0` / `address(0)` — the aggregator collects its own fee on the input side; no third-party fee is applied on the output.

### ERC20-Quote Pair Sells

The adapter approves `HELPER_V3` (not the tokenManager). The helper internally approves the tokenManager and handles the `quote → BNB` conversion. BNB proceeds are delivered to the adapter (msg.sender), then forwarded to `to`.

---

## Output Delivery

| Path | How output reaches `to` |
|------|--------------------------|
| V1/V2 buy | Manager sends tokens directly to `to` — adapter returns `amountOut = 0` |
| V1/V2 BNB-pair sell | BNB sent to adapter (msg.sender); adapter measures delta and forwards to `to` |
| ERC20-pair buy | Helper sends tokens directly to `to` — adapter returns `amountOut = 0` |
| ERC20-pair sell | BNB sent to adapter (msg.sender); adapter measures delta and forwards to `to` |

---

## Slippage Enforcement

| Path | Enforced by |
|------|-------------|
| V2 BNB-pair buy | `minAmount` inside `BuyTokenParams` — enforced by V2 manager |
| V1 buy | `minAmount` param — enforced by V1 manager |
| ERC20-pair buy | `minAmount` param — enforced by HELPER_V3 |
| V2 BNB-pair sell | `minFunds` param passed to `sellToken` — enforced by V2 manager; adapter balance-delta check as backstop |
| V1 BNB-pair sell | No onchain `minFunds` in V1 `saleToken` — enforced entirely by adapter balance-delta check |
| ERC20-pair sell | `minFunds` param passed to `sellForEth` — enforced by helper; adapter balance-delta check as backstop |

---

## Migration Guard

`getTokenInfo` returns `liquidityAdded == true` once the token's bonding curve fills and a PancakeSwap pair is created. The adapter reverts with `TokenMigrated()` in that case. After migration, use a `GenericV2Adapter` or `GenericV3Adapter` targeting the PancakeSwap pair instead.

---

## Error Reference

| Error | Condition |
|-------|-----------|
| `TokenMigrated()` | `liquidityAdded == true` — token has moved to PancakeSwap |
| `UnsupportedDirection()` | Both or neither of `tokenIn`/`tokenOut` are `address(0)` |
| `InsufficientOutput()` | BNB received after sell is below `minOut` |
| `NotAggregator()` | `execute()` called by any address other than the registered aggregator |
| `TransferFailed()` | Token approval or transfer failed |
| `NativeSendFailed()` | BNB forwarding to `to` failed |
