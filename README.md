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
│   ├── ILaunchpadToken.sol      Minimal interface every token type implements
│   ├── IPancakeRouter02.sol     PancakeSwap V2 router interface
│   └── IPostMigrate.sol         Callback interface for post-migration setup
├── tokens/
│   ├── StandardToken.sol        Plain ERC-20 clone
│   ├── TaxToken.sol             Buy/sell tax clone
│   └── ReflectionToken.sol      RFI-style reflection clone
├── BondingCurve.sol             All AMM state, buy/sell/migrate execution, fee dispatch
└── LaunchpadFactory.sol         Token creation, clone deployment, admin, trading pass-throughs

coremanagement/
└── index.html                   Browser-based admin dashboard (MetaMask, BSC)
```

---

## Architecture

The system is split into two contracts with distinct responsibilities:

| Contract | Responsibilities |
|----------|-----------------|
| **LaunchpadFactory** | Token clone deployment (CREATE2), creation fee collection, default bonding-curve parameters, ownership + manager roles, timelocked configuration of BondingCurve, buy/sell/migrate convenience pass-throughs. `bondingCurve` address is immutable — set once at deployment. |
| **BondingCurve** | All per-token AMM state (`TokenConfig`), buy/sell/migrate execution, trade fee collection and dispatch, DEX migration. Acts as the token's `factory` so it can call `setupVesting()` and `postMigrateSetup()` |

Tokens are minted **directly to BondingCurve** at launch. The `factory` field on each token is set to `address(bondingCurve)` so BondingCurve has the authority to call token-internal lifecycle functions.

Users may trade directly with BondingCurve or through the factory pass-throughs. For direct sells the user approves BondingCurve; for factory-routed sells the user approves LaunchpadFactory.

---

## Token Lifecycle

```
createToken / createTT / createRFL
        │  (msg.value = creation fee + optional early buy)
        ▼
  CREATE2 clone → initForLaunchpad(factory_ = address(bondingCurve))
  • 100 % of supply minted to BondingCurve
  • PancakeSwap pair created immediately (TAX/RFL tokens — empty, no liquidity yet)
  • _inBondingPhase = true  (taxes / reflection suppressed)
  • Creator vesting tokens transferred to token contract as self-escrow
        │
        ▼
  Bonding-curve phase  (BondingCurve acts as AMM)
  • buy(token, minOut, deadline)    — user pays BNB, receives tokens
  • sell(token, amount, minBNB, dl) — user sells tokens back for BNB
  • Excess msg.value above creation fee used as an antibot-exempt early buy
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

## Trading Paths

| Path | Who approves | Deadline checked |
|------|-------------|-----------------|
| `BondingCurve.buy(token, minOut, deadline)` | — (payable) | BondingCurve |
| `BondingCurve.sell(token, amount, minBNB, deadline)` | User approves **BondingCurve** | BondingCurve |
| `LaunchpadFactory.buy(token, minOut, deadline)` | — (payable) | Factory |
| `LaunchpadFactory.sell(token, amount, minBNB, deadline)` | User approves **Factory** | Factory |

---

## Parameters

### Factory Parameters (LaunchpadFactory)

| Parameter | Description |
|-----------|-------------|
| `creationFee` | BNB required to launch a token in BNB wei (default `0.0011 ether`; may be 0) |
| `defaultVirtualBNB` | Virtual BNB seeded into the bonding curve in BNB wei |
| `defaultMigrationTarget` | BNB that must be raised before DEX migration in BNB wei |

- `virtualBNB` and `migrationTarget` are locked into each token's `TokenConfig` at creation. Subsequent updates only affect future tokens.

### BondingCurve Parameters

| Parameter | Description |
|-----------|-------------|
| `platformFee` | BPS — goes to `feeRecipient` on each trade |
| `charityFee` | BPS — goes to `charityWallet` on each trade |
| `feeRecipient` | Receives platform fees and creation fees |
| `charityWallet` | Receives charity portion; `address(0)` redirects to `feeRecipient` |
| `pancakeRouter` | PancakeSwap V2 router; snapshotted per-token at creation |

All BondingCurve parameters are updated through the factory using 48-hour timelocks.

---

## Fee Distribution

All fees are dispatched **immediately** — nothing is held in either contract.

```
totalFeeBPS = platformFee + charityFee   (max 250 BPS = 2.5 %)

tradeFee = bnbIn × totalFeeBPS / 10000
  └─ charityWallet  ← fee × charityFee / totalFeeBPS
  └─ feeRecipient   ← remainder

creationFee → feeRecipient  (collected at token launch)
```

| Recipient | Condition |
|-----------|-----------|
| `charityWallet` | `charityFee` BPS share (if charity wallet is set and `charityFee > 0`) |
| `feeRecipient` | remainder (100 % if no charity wallet or `charityFee == 0`) |

The combined `platformFee + charityFee` may not exceed 250 BPS (2.5 %).

---

## Timelock

All BondingCurve configuration changes are routed through the factory with a **48-hour timelock** using a propose → execute pattern.

| Action | Timelock ID |
|--------|-------------|
| Update PancakeSwap router | `keccak256("SET_ROUTER")` |
| Update platform fee | `keccak256("SET_PLATFORM_FEE")` |
| Update charity fee | `keccak256("SET_CHARITY_FEE")` |
| Update fee recipient | `keccak256("SET_FEE_RECIPIENT")` |
| Update charity wallet | `keccak256("SET_CHARITY_WALLET")` |

Any queued action can be cancelled by the owner before execution.

---

## Manager Role

Managers are addresses granted limited admin rights by the owner. A manager can call:

- `setDefaultParams(virtualBNB, migrationTarget)` on the factory

All other admin functions (timelocked BondingCurve config, ownership transfer) remain owner-only.

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
- BondingCurve transfers creator tokens to the token contract and calls `setupVesting` atomically at launch.
- **Claimable by the current token owner.** Ownership transfer passes vesting rights to the new owner.

```solidity
token.claimVesting();         // msg.sender must be current owner
token.claimableVesting();     // view: tokens available now
token.transferOwnership(addr); // new owner inherits vesting rights
```

---

## Vanity Addresses (ending `1111`)

Every token clone is deployed via CREATE2 and **must** end in `0x1111` (last 4 hex digits).

The on-chain CREATE2 salt is `keccak256(abi.encode(msg.sender, userSalt))`, binding the salt to the creator so the same `userSalt` cannot be front-run by a different sender.

**Off-chain salt mining (JavaScript):**

```js
// Choose the implementation address for the token type you want to create:
//   factory.standardImpl()    → createToken()
//   factory.taxImpl()         → createTT()
//   factory.reflectionImpl()  → createRFL()
const impl = await factory.standardImpl();

let userSalt;
for (let n = 0n; ; n++) {
  userSalt = ethers.zeroPadValue(ethers.toBeHex(n), 32);
  const addr = await factory.predictTokenAddress(creatorAddr, userSalt, impl);
  if (addr.toLowerCase().endsWith("1111")) break;
}

// StandardToken
await factory.createToken(
  { name, symbol, supplyOption, enableCreatorAlloc, enableAntibot, antibotBlocks,
    metaURI, salt: userSalt },
  { value: creationFee }
);

// TaxToken
await factory.createTT(
  { name, symbol, metaURI, supplyOption, enableCreatorAlloc, enableAntibot,
    antibotBlocks, salt: userSalt },
  { value: creationFee }
);

// ReflectionToken
await factory.createRFL(
  { name, symbol, metaURI, supplyOption, enableCreatorAlloc, enableAntibot,
    antibotBlocks, salt: userSalt },
  { value: creationFee }
);
```

`creationFee` defaults to `DEFAULT_CREATION_FEE` (`0.0011 ether`); read it at call time via `factory.creationFee()`. Expected mining iterations: ~65 536 (2^16). Completes in under a second in JS.

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

### 1. Deploy BondingCurve

```solidity
constructor(
    address factory_,       // set to address(0) initially, or use a 2-step deploy
    address router_,        // PancakeSwap V2 router
    address feeRecipient_,  // receives platform and creation fees
    uint256 platformFee_,   // BPS → feeRecipient
    uint256 charityFee_     // BPS → charityWallet
)
```

`platformFee_ + charityFee_` must not exceed 250 BPS (2.5 %).

### 2. Deploy LaunchpadFactory

```solidity
constructor(
    address bondingCurve_,           // deployed BondingCurve
    uint256 creationFee_,             // BNB wei (may be 0)
    uint256 defaultVirtualBNB_,       // BNB wei
    uint256 defaultMigrationTarget_   // BNB wei
)
```

The factory deploys the three implementation contracts (`StandardToken`, `TaxToken`, `ReflectionToken`) in its constructor.

### 3. Update BondingCurve factory pointer

Call `BondingCurve.setFactory(address(launchpadFactory))` — this must be done once before any tokens are launched.

---

## Owner Administration

### Factory (instant)

| Function | Description |
|----------|-------------|
| `setCreationFee(bnbWei)` | Update creation fee — owner only |
| `setDefaultParams(virtualBNB, migrationTarget)` | Update default bonding-curve parameters — owner or manager |
| `addManager(addr)` | Grant manager role |
| `removeManager(addr)` | Revoke manager role |
| `transferOwnership(addr)` | Propose two-step ownership transfer |
| `acceptOwnership()` | Pending owner confirms the transfer |
| `cancelAction(bytes32)` | Cancel a queued timelock action |

### BondingCurve Config (48h timelock, via factory)

| Propose | Execute | Description |
|---------|---------|-------------|
| `proposeSetRouter(addr)` | `executeSetRouter()` | Update PancakeSwap router |
| `proposeSetPlatformFee(bps)` | `executeSetPlatformFee()` | Update platform fee BPS |
| `proposeSetCharityFee(bps)` | `executeSetCharityFee()` | Update charity fee BPS |
| `proposeSetFeeRecipient(addr)` | `executeSetFeeRecipient()` | Update fee recipient |
| `proposeSetCharityWallet(addr)` | `executeSetCharityWallet()` | Set charity wallet (0x0 to disable) |

---

## Key View Functions

### On BondingCurve

| Function | Returns |
|----------|---------|
| `totalTokensLaunched()` | Global token count |
| `allTokens(i)` | Token address at index `i` |
| `getTokensByCreator(addr)` | All tokens launched by `addr` |
| `tokenCountByCreator(addr)` | Token count for `addr` |
| `tokens(addr)` | Full `TokenConfig` struct |
| `getAmountOut(token, bnbIn)` | `(tokensOut, feeBNB)` — buy quote, migration-cap aware |
| `getAmountOutSell(token, tokensIn)` | `(bnbOut, feeBNB)` — sell quote |
| `getSpotPrice(token)` | BNB per whole token ×1e18 |

### On LaunchpadFactory

| Function | Returns |
|----------|---------|
| `predictTokenAddress(creator, salt, impl)` | Off-chain vanity salt mining helper |
| `bondingCurve()` | Immutable BondingCurve address |
| `timelockExpiry(bytes32)` | Unix timestamp when a queued action unlocks |

---

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Creation fee | BNB wei — default `0.0011 ether`, set by factory owner |
| Max total trade fee | 2.5 % (250 BPS) |
| Default virtual BNB | BNB wei — set by factory owner/manager |
| Default migration target | BNB wei — set by factory owner/manager |
| Timelock delay | 48 hours |
| Vesting duration | 365 days linear |
| Max buy/sell tax | 10 % (1 000 BPS) per side |
| Min swap threshold | 0.02 % of token total supply |
| Reflection token default taxes | 0 % — owner configures post-deployment |
| Reflection minimum balance | 0.1 % of total supply (floor; owner may only raise) |
| Antibot range | 10–199 blocks |
| LP lock destination | `0x000…dEaD` (permanent) |
| Vanity address suffix | `0x1111` (last 4 hex digits) |
| Compiler | `solc ^0.8.32` with `viaIR: true`, `optimizer: 200 runs` |

---

## Core Management Dashboard

Open [`coremanagement/index.html`](coremanagement/index.html) in a browser. Connect MetaMask on BSC and paste the LaunchpadFactory address to:

- View factory and BondingCurve state side-by-side
- Set creation fee and default bonding-curve parameters
- Propose and execute timelocked BondingCurve configuration changes
- Manage the owner and manager roles
- Browse the token registry (reads directly from BondingCurve)

---

## License

[MIT](LICENSE)
