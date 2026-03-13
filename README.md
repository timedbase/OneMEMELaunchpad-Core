# OneMEME Launchpad — Core Contracts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.32-blue)](https://docs.soliditylang.org/)
[![Network: BSC](https://img.shields.io/badge/Network-BNB%20Smart%20Chain-yellow)](https://www.bnbchain.org/)

BSC meme-token launchpad with a bonding-curve presale, decaying antibot, creator vesting, and automatic PancakeSwap V2 migration.

---

## Repository Layout

```
contracts/
├── interfaces/
│   └── ILaunchpadToken.sol      Minimal interface every token type implements
├── tokens/
│   ├── StandardToken.sol        Plain ERC-20 clone
│   ├── TaxToken.sol             Buy/sell tax clone
│   └── ReflectionToken.sol      RFI-style reflection clone
└── LaunchpadFactory.sol         Bonding curve · antibot · vesting · migration
LICENSE
README.md
```

The factory deploys one implementation contract per token type at construction time and uses **EIP-1167 minimal proxies** (clones via CREATE2) for every token launch, keeping deployment gas low while producing predictable, vanity addresses.

---

## Token Lifecycle

```
createToken / createTT / createRFL
        │  (msg.value = creation fee + optional early buy)
        ▼
  CREATE2 clone → initForLaunchpad()
  • 100 % of supply minted to factory
  • _inBondingPhase = true  (fees / reflection suppressed)
  • Creator vesting tokens held in token contract as self-escrow
        │
        ▼
  Bonding-curve phase  (factory acts as AMM)
  • buy()  — constant-product curve, antibot penalty on early blocks
  • sell() — sell tokens back to factory for BNB
  • Excess BNB sent on createToken is used as an immediate buy
        │
        ▼  raisedBNB ≥ migrationTarget
  Auto-migrate  (or call migrate() manually)
  • 38 % tokens + all raised BNB → PancakeSwap addLiquidityETH
  • LP tokens sent to dead wallet (permanently locked)
  • enableTrading(pair, router) called on token contract
  • _inBondingPhase = false — normal DEX trading begins
```

---

## Supply & Allocation

| Option | Total supply |
|--------|-------------|
| `ONE` | 1 token |
| `THOUSAND` | 1,000 tokens |
| `MILLION` | 1,000,000 tokens |
| `BILLION` | 1,000,000,000 tokens |

All supplies are 18-decimal.

| Allocation | BPS | % |
|------------|-----|---|
| Liquidity (migrates to DEX) | 3800 | 38 % |
| Creator vesting (optional) | 500 | 5 % |
| Bonding curve | 5700 / 6200 | 57 % / 62 % |

---

## Bonding Curve

Constant-product AMM with **virtual BNB** liquidity — the curve is pre-seeded without requiring real capital.

```
k = virtualBNB × bcTokensTotal         (invariant, set at launch)

Buy:  tokensOut = poolTokens − k / (poolBNB + netBNB)
Sell: grossBNB  = poolBNB   − k / (poolTokens + amountIn)

netBNB = bnbIn × (10000 − tradeFee) / 10000
```

### Full sell-through guarantee

The buy that crosses `migrationTarget` is capped so all remaining BC tokens are sold and excess BNB is refunded to the buyer — ensuring zero unsold BC tokens at migration.

```
grossNeeded = ⌈bnbNeeded ÷ (1 − tradeFee%)⌉

if bnbIn ≥ grossNeeded:
    tokensOut = all remaining BC tokens
    refund    = bnbIn − grossNeeded
    → migration fires immediately
```

---

## Price Oracle (TWAP)

- **Source**: PancakeSwap V2 USDC/WBNB pair, 30-minute observation window.
- **Staleness**: measured in blocks (default **1 440 blocks ≈ 2 h** on BSC), configurable by factory owner.
- **`isToken0`** is derived on-chain — provide the USDC token address, not a boolean.
- `_tryUpdateTWAP()` fires on every factory interaction but executes at most once per block.
- Converts `creationFeeUSD`, `virtualBNBUSD`, and `migrationTargetUSD` to BNB at launch time.

---

## Decaying Antibot

Configurable per-token at creation (`antibotBlocks`: 10–199).

```
penaltyBPS = 10000 × (tradingBlock − block.number) / (tradingBlock − creationBlock)
tokensToDeadWallet = tokensOut × penaltyBPS / 10000
```

- Penalty decays linearly from 100 % at creation block to 0 % at `tradingBlock`.
- Creator address is always exempt.
- Disabled if `enableAntibot = false`.

---

## Creator Vesting

- Optional 5 % allocation, linear vest over **12 months**.
- The token contract itself acts as the vesting escrow — no separate contract required.
- Factory transfers creator tokens to the token contract and calls `setupVesting` at launch.
- **Claimable by the current token owner.** Ownership transfer passes vesting rights to the new owner. `vestingCreator` is stored for transparency only.

```solidity
token.claimVesting();            // msg.sender must be current owner
token.claimableVesting();        // view: tokens available now
token.transferOwnership(addr);   // new owner inherits the vesting
```

---

## Vanity Addresses (ending `1111`)

Every token clone is deployed via CREATE2 and **must** end in `0x1111` (last 4 hex digits).

The on-chain CREATE2 salt is `keccak256(abi.encode(msg.sender, userSalt))`, binding the salt to the creator so the same `userSalt` cannot be front-run by a different sender.

**Off-chain salt mining (JavaScript):**

```js
const impl = await factory.standardImpl(); // or taxImpl / reflectionImpl

let userSalt;
for (let n = 0n; ; n++) {
  userSalt = ethers.zeroPadValue(ethers.toBeHex(n), 32);
  const addr = await factory.predictTokenAddress(creatorAddr, userSalt, impl);
  if (addr.toLowerCase().endsWith("1111")) break;
}

// Pass in BaseParams
await factory.createToken({ ..., salt: userSalt }, { value: creationFee });
```

Expected iterations: ~65 536 (2^16). Completes in under a second in JS.

---

## Token Types

### `StandardToken`
Plain ERC-20. No taxes, no reflection. `enableTrading` is a no-op (interface compatibility only).

### `TaxToken`
Configurable buy/sell taxes distributed to up to 5 wallets/purposes (marketing, team, treasury, burn, liquidity). Taxes are accumulated and swapped to BNB post-migration. Max 10 % total per side.

### `ReflectionToken`
RFI-style passive reflection distributed to all non-excluded holders on every transfer. Supports marketing, team, LP, burn, and reflection allocations. Max 10 % total per side.

---

## Deployment

### Factory Constructor

```solidity
constructor(
    address router_,       // PancakeSwap V2 router
    address feeRecipient_, // receives platform fees
    address usdc_,         // USDC token address (isToken0 derived on-chain)
    address usdcWbnbPair_, // USDC/WBNB pair for TWAP oracle
    uint8   usdcDecimals_, // 6 (Circle USDC) or 18 (Binance-peg)
    uint256 tradeFee_      // BPS — recommended: 100 (1 %)
)
```

After deploying, call `updateTWAP()` once to seed the oracle before the first token launch.

### Owner Administration

| Function | Description |
|----------|-------------|
| `setRouter(addr)` | Update PancakeSwap V2 router |
| `setFeeRecipient(addr)` | Update fee collection address |
| `setTradeFee(bps)` | Update trade fee — max 500 (5 %) |
| `setCreationFeeUSD(usd18)` | Update creation fee in USD (18-dec) |
| `setUsdcPair(usdc, pair, decimals)` | Swap oracle pair; `isToken0` derived on-chain; resets TWAP |
| `setTwapMaxAgeBlocks(blocks)` | TWAP staleness threshold in blocks (min 60) |
| `setDefaultParams(vBNBusd, mTgtusd)` | Default virtual BNB / migration target (USD, 18-dec) |
| `withdrawFees()` | Push accumulated platform fees to `feeRecipient` |
| `transferOwnership(addr)` | Transfer factory ownership |

---

## Key View Functions

### Token Registry

| Function | Returns |
|----------|---------|
| `totalTokensLaunched()` | Global token count |
| `allTokens(i)` | Token address at index `i` |
| `getTokensByCreator(addr)` | All tokens launched by `addr` |
| `tokenCountByCreator(addr)` | Token count for `addr` |
| `tokens(addr)` | Full `TokenConfig` struct |

### AMM Quotes

| Function | Returns |
|----------|---------|
| `getAmountOut(token, bnbIn)` | `(tokensOut, feeBNB)` — buy quote, migration-cap aware |
| `getAmountOutSell(token, tokensIn)` | `(bnbOut, feeBNB)` — sell quote |
| `getSpotPrice(token)` | BNB/token spot price ×1e18 |
| `creationFeeBNB()` | Current creation fee in BNB (live TWAP) |
| `predictTokenAddress(creator, salt, impl)` | Off-chain salt mining helper |

---

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Creation fee | $1 USD (converted to BNB via TWAP at launch) |
| Default trade fee | 1 % (100 BPS) |
| TWAP observation period | 30 minutes |
| TWAP max age | 1 440 blocks default (~2 h on BSC), configurable |
| Vesting duration | 365 days linear |
| Max buy/sell tax | 10 % (1 000 BPS) per side |
| Antibot range | 10–199 blocks |
| LP lock destination | `0x000…dEaD` (permanent) |
| Vanity address suffix | `0x1111` (last 4 hex digits) |

---

## License

[MIT](LICENSE)
