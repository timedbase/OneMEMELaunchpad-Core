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
```

The factory deploys one implementation contract per token type at construction and uses **EIP-1167 minimal proxies** (clones via CREATE2) for every launch, keeping deployment gas low while producing deterministic vanity addresses.

---

## Token Lifecycle

```
createToken / createTT / createRFL
        │  (msg.value = creation fee + optional early buy)
        ▼
  CREATE2 clone → initForLaunchpad()
  • 100 % of supply minted to factory
  • PancakeSwap pair created immediately (empty — no liquidity yet)
  • _inBondingPhase = true  (taxes / reflection suppressed)
  • Creator vesting tokens transferred to token contract as self-escrow
        │
        ▼
  Bonding-curve phase  (factory acts as AMM)
  • buy()  — constant-product curve, antibot penalty on early blocks
  • sell() — sell tokens back to factory for BNB
  • Excess BNB above creation fee is used as an immediate buy
        │
        ▼  raisedBNB ≥ migrationTarget
  Auto-migrate  (or call migrate() manually)
  • 38 % tokens + all raised BNB → PancakeSwap addLiquidityETH
  • LP tokens sent to dead wallet (permanently locked)
  • postMigrateSetup() called on token — exits bonding phase, enables DEX trading
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
| Bonding curve (with creator) | 5700 | 57 % |
| Bonding curve (no creator) | 6200 | 62 % |

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

## Factory Parameters

All bonding-curve parameters are set and maintained in **BNB wei** by the factory owner or managers. There is no on-chain price oracle — values are configured directly.

| Parameter | Description |
|-----------|-------------|
| `creationFee` | BNB required to launch a token in BNB wei (default `0.0011 ether`; may be 0) |
| `defaultVirtualBNB` | Virtual BNB seeded into the bonding curve in BNB wei |
| `defaultMigrationTarget` | BNB that must be raised before DEX migration in BNB wei |

- At launch time `virtualBNB` and `migrationTarget` are locked into `TokenConfig`. Subsequent owner/manager updates only affect future tokens.
- Creators can override both values per-token via `BaseParams.customVirtualBNB` and `BaseParams.customMigrationTarget` in BNB wei (set to 0 to use factory defaults).

---

## Fee Distribution

All fees (creation fee and per-trade fees) are dispatched **immediately** — nothing is held in the factory.

```
totalFeeBPS = platformFee + charityFee   (max 250 BPS = 2.5 %)

fee = bnbIn × totalFeeBPS / 10000
  └─ charityWallet  ← fee × charityFee / totalFeeBPS
  └─ feeRecipient   ← remainder
```

| Recipient | Condition |
|-----------|-----------|
| `charityWallet` | `charityFee` BPS share (if charity wallet is set and `charityFee > 0`) |
| `feeRecipient` | remainder (100 % if no charity wallet or `charityFee == 0`) |

- `feeRecipient` and `owner` are distinct addresses.
- `charityWallet` defaults to `address(0)` (disabled). Set via `setCharityWallet`.
- The combined `platformFee + charityFee` may not exceed 250 BPS (2.5 %).
- Managers may update `creationFee` and default bonding-curve params but cannot change fee routing addresses.

---

## Manager Role

Managers are addresses granted limited admin rights by the owner. A manager can call:

- `setCreationFee(bnbWei)`
- `setDefaultParams(virtualBNB, migrationTarget)`

All other admin functions (`setPlatformFee`, `setCharityFee`, `setFeeRecipient`, `setCharityWallet`, `setRouter`, ownership transfer, `rescueBNB`) remain owner-only.

---

## Decaying Antibot

Configurable per-token at creation (`antibotBlocks`: 10–199).

```
penaltyBPS = 10000 × (tradingBlock − block.number) / (tradingBlock − creationBlock)
tokensToDeadWallet = tokensOut × penaltyBPS / 10000
```

- Penalty decays linearly from 100 % at the creation block to 0 % at `tradingBlock`.
- Applies to **all** `buy()` callers including the creator.
- The only exempt buy is the atomic early buy embedded in `createToken` / `createTT` / `createRFL` — it fires within the same transaction as deployment before any other buyer can act.
- Disabled if `enableAntibot = false`.

---

## Creator Vesting

- Optional 5 % allocation, linear vest over **12 months**.
- The token contract itself acts as the vesting escrow — no separate contract required.
- Factory transfers creator tokens to the token contract and calls `setupVesting` atomically at launch.
- **Claimable by the current token owner.** Ownership transfer passes vesting rights to the new owner. `vestingCreator` is stored for transparency only.
- Vesting tokens are tracked separately (`_vestingBalance`) and are never consumed by `swapAndDistribute`.

```solidity
token.claimVesting();            // msg.sender must be current owner
token.claimableVesting();        // view: tokens available now
token.transferOwnership(addr);   // new owner inherits vesting rights
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

Plain ERC-20. No taxes, no reflection. Vesting is supported if creator allocation is enabled.

### `TaxToken`

Configurable buy/sell taxes with up to 5 components per side: marketing, team, treasury, burn, and liquidity. Taxes accumulate in the token contract and are swapped to BNB on qualifying transfers post-migration. Max 10 % total per side.

- Minimum `swapThreshold` is 0.02 % of total supply.
- Router and PancakeSwap pair are configured at token creation; `postMigrateSetup()` activates normal tax/swap behaviour after migration.

### `ReflectionToken`

RFI-style passive reflection plus optional custom reflection token distribution.

- **Taxes default to 0 %** at deployment. The token owner must call `setBuyTaxes` / `setSellTaxes` post-deployment to activate fees.
- **Native mode** (`reflectionToken == address(0)`): the reflection tax passively increases all non-excluded holders' balances by reducing `_rTotal`.
- **Custom mode**: reflection tax is accumulated, swapped to a configured ERC-20 token, and pushed proportionally to qualifying holders.
- **Minimum balance threshold**: holders must hold at least 0.1 % of total supply to receive custom reflection distributions. The owner may raise this threshold but never lower it below 0.1 %.
- Minimum `swapThreshold` is 0.02 % of total supply.
- Router and PancakeSwap pair are configured at token creation; `postMigrateSetup()` activates normal behaviour after migration.

---

## Deployment

### Factory Constructor

```solidity
constructor(
    address router_,                  // PancakeSwap V2 router
    address feeRecipient_,            // receives platform fees
    uint256 creationFee_,             // BNB wei (may be 0)
    uint256 platformFee_,             // BPS → feeRecipient
    uint256 charityFee_,              // BPS → charityWallet
    uint256 defaultVirtualBNB_,       // BNB wei
    uint256 defaultMigrationTarget_   // BNB wei
)
```

`platformFee_ + charityFee_` must not exceed 250 BPS (2.5 %).

### Owner Administration

| Function | Description |
|----------|-------------|
| `setCreationFee(bnbWei)` | Update creation fee in BNB wei (may be 0) — owner or manager |
| `setPlatformFee(bps)` | Update platform fee BPS — combined total must stay ≤ 250 BPS |
| `setCharityFee(bps)` | Update charity fee BPS — combined total must stay ≤ 250 BPS |
| `setDefaultParams(virtualBNB, migrationTarget)` | Update default bonding-curve parameters in BNB wei — owner or manager |
| `setRouter(addr)` | Update PancakeSwap V2 router |
| `setFeeRecipient(addr)` | Update fee recipient address |
| `setCharityWallet(addr)` | Set charity wallet; `address(0)` disables the split (all fees go to `feeRecipient`) |
| `addManager(addr)` | Grant manager role (may update creation fee and default params) |
| `removeManager(addr)` | Revoke manager role |
| `transferOwnership(addr)` | Propose ownership transfer (two-step; candidate calls `acceptOwnership()`) |
| `acceptOwnership()` | Pending owner accepts the proposed transfer |
| `rescueBNB()` | Sweep stray BNB (not part of any active pool) to `feeRecipient` |

---

## Key View Functions

### Token Registry

| Function | Returns |
|----------|---------|
| `totalTokensLaunched()` | Global token count |
| `allTokens(i)` | Token address at index `i` |
| `getTokensByCreator(addr)` | All tokens launched by `addr` |
| `tokenCountByCreator(addr)` | Token count for `addr` |
| `tokens(addr)` | Full `TokenConfig` struct (includes `pair` address) |

### AMM Quotes

| Function | Returns |
|----------|---------|
| `getAmountOut(token, bnbIn)` | `(tokensOut, feeBNB)` — buy quote, migration-cap aware |
| `getAmountOutSell(token, tokensIn)` | `(bnbOut, feeBNB)` — sell quote |
| `getSpotPrice(token)` | BNB per whole token ×1e18 |
| `predictTokenAddress(creator, salt, impl)` | Off-chain vanity salt mining helper |

---

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Creation fee | BNB wei — default `0.0011 ether`, set by factory owner/manager |
| Max total trade fee | 2.5 % (250 BPS) |
| Default virtual BNB | BNB wei — set by factory owner/manager |
| Default migration target | BNB wei — set by factory owner/manager |
| Vesting duration | 365 days linear |
| Max buy/sell tax | 10 % (1 000 BPS) per side |
| Min swap threshold | 0.02 % of token total supply (floor; enforced at creation and via setter) |
| Reflection token default taxes | 0 % — owner configures post-deployment |
| Reflection minimum balance | 0.1 % of total supply (floor; owner may only raise) |
| Antibot range | 10–199 blocks |
| LP lock destination | `0x000…dEaD` (permanent) |
| Vanity address suffix | `0x1111` (last 4 hex digits) |

---

## License

[MIT](LICENSE)
