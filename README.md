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
├── LaunchpadFactory.sol         Token creation, clone deployment, admin, trading pass-throughs
└── VestingWallet.sol            Shared vesting escrow for all creator allocations

coremanagement/
└── index.html                   Browser-based admin dashboard (MetaMask, BSC)
```

---

## Architecture

The system is split into three contracts with distinct responsibilities:

| Contract | Responsibilities |
|----------|-----------------|
| **LaunchpadFactory** | Token clone deployment (CREATE2), creation fee collection, default bonding-curve parameters, ownership + manager roles, timelocked configuration of BondingCurve, buy/sell/migrate convenience pass-throughs. `bondingCurve` address is immutable — set once at deployment. |
| **BondingCurve** | All per-token AMM state (`TokenConfig`), buy/sell/migrate execution, trade fee collection and dispatch, DEX migration. The `deployer` (immutable, set at construction) is the only address that can call `setFactory()` — all other admin is `onlyFactory`. |
| **VestingWallet** | Single shared vesting escrow for all tokens launched through the factory. Receives creator allocations at token creation. Beneficiaries claim linearly over 12 months. Owner may void any schedule, burning remaining tokens immediately. |

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
  • TaxToken / ReflectionToken: VestingWallet excluded from fee and reflection during init
  • If creator allocation enabled: 5 % transferred to VestingWallet, schedule registered
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
- Handled by a **single shared `VestingWallet` contract** — the same contract holds allocations for every token ever launched through the factory.
- At token creation, the factory transfers creator tokens directly to VestingWallet and calls `addVesting(token, creator, amount)` atomically.
- TaxToken and ReflectionToken exclude VestingWallet from fees and reflection during `initForLaunchpad`, so transfers to/from VestingWallet are always fee-free and never accumulate phantom reflection tokens.
- Beneficiary claims against their own address — ownership transfer on the token has no effect on vesting rights.

```solidity
// Beneficiary
vestingWallet.claim(tokenAddress);                        // send claimable tokens to msg.sender
vestingWallet.claimable(tokenAddress, beneficiary);       // view: tokens claimable now

// VestingWallet owner
vestingWallet.voidSchedule(tokenAddress, beneficiary);    // burn all remaining unvested tokens immediately
vestingWallet.transferOwnership(newOwner);
```

---

## Vanity Addresses (ending `1111`)

Every token clone is deployed via CREATE2 and **must** end in `0x1111` (last 4 hex digits).

The on-chain CREATE2 salt is `keccak256(abi.encode(msg.sender, userSalt))`, binding the salt to the creator so the same `userSalt` cannot be front-run by a different sender.

**Off-chain salt mining (JavaScript — local, no RPC):**

> **Salt is wallet-specific.** The on-chain formula is `keccak256(abi.encode(msg.sender, userSalt))` — a salt mined for wallet A produces a non-vanity address if submitted by wallet B. Always mine with the same wallet that will send the `createToken` transaction.

Compute CREATE2 addresses entirely client-side. No RPC calls required — mines ~65 536 candidates in under a second.

```js
import { ethers } from 'ethers';

// impl: factory.standardImpl() | factory.taxImpl() | factory.reflectionImpl()
// creatorAddr: the EXACT wallet that will call createToken / createTT / createRFL
function mineVanitySalt(factoryAddr, implAddr, creatorAddr) {
  const initcode = '0x3d602d80600a3d3981f3363d3d373d3d3d363d73'
    + implAddr.slice(2).toLowerCase()
    + '5af43d82803e903d91602b57fd5bf3';
  const initcodeHash = ethers.keccak256(ethers.getBytes(initcode));
  const abiCoder = ethers.AbiCoder.defaultAbiCoder();
  for (;;) {
    const userSalt = ethers.randomBytes(32);
    // Replicates the onchain binding: keccak256(abi.encode(msg.sender, userSalt))
    const onchainSalt = ethers.keccak256(abiCoder.encode(['address', 'bytes32'], [creatorAddr, userSalt]));
    const hash = ethers.keccak256(ethers.concat([new Uint8Array([0xff]), factoryAddr, onchainSalt, initcodeHash]));
    const addr = ethers.getAddress('0x' + hash.slice(-40));
    if (addr.toLowerCase().endsWith('1111')) return { userSalt: ethers.hexlify(userSalt), address: addr };
  }
}

const { userSalt } = mineVanitySalt(factoryAddr, implAddr, creatorAddr);
const creationFee = await factory.creationFee();

// StandardToken
await factory.createToken(
  [name, symbol, supplyOption, enableCreatorAlloc, enableAntibot, antibotBlocks, metaURI, userSalt],
  { value: creationFee + earlyBuyWei }  // earlyBuyWei = 0n if no early buy
);

// TaxToken
await factory.createTT(
  [name, symbol, metaURI, supplyOption, enableCreatorAlloc, enableAntibot, antibotBlocks, userSalt],
  { value: creationFee + earlyBuyWei }
);

// ReflectionToken
await factory.createRFL(
  [name, symbol, metaURI, supplyOption, enableCreatorAlloc, enableAntibot, antibotBlocks, userSalt],
  { value: creationFee + earlyBuyWei }
);
```

`supplyOption`: `0` = ONE, `1` = THOUSAND, `2` = MILLION, `3` = BILLION. Expected mining iterations: ~65 536 (2^16). The Core Management dashboard includes a built-in one-click miner.

---

## Token Types

### `StandardToken`

Plain ERC-20. No taxes, no reflection. Creator vesting supported via VestingWallet if creator allocation is enabled.

### `TaxToken`

Configurable buy/sell taxes with up to 5 components per side: marketing, team, treasury, burn, and liquidity. Taxes accumulate in the token contract and are swapped to BNB on qualifying transfers post-migration. Max 10 % total per side.

- Minimum `swapThreshold` is 0.02 % of total supply.
- Router and PancakeSwap pair are configured at token creation; `postMigrateSetup()` activates normal tax/swap behaviour after migration.
- VestingWallet is excluded from fees during init — transfers to/from it carry zero tax.

### `ReflectionToken`

RFI-style passive reflection plus optional custom reflection token distribution.

- **Taxes default to 0 %** at deployment. The token owner must call `setBuyTaxes` / `setSellTaxes` post-deployment to activate fees.
- **Native mode** (`reflectionToken == address(0)`): the reflection tax passively increases all non-excluded holders' balances by reducing `_rTotal`.
- **Custom mode**: reflection tax is accumulated, swapped to a configured ERC-20 token, and pushed proportionally to qualifying holders.
- **Minimum balance threshold**: holders must hold at least 0.1 % of total supply to receive custom reflection distributions. The owner may raise this threshold but never lower it below 0.1 %.
- Minimum `swapThreshold` is 0.02 % of total supply.
- Router and PancakeSwap pair are configured at token creation; `postMigrateSetup()` activates normal behaviour after migration.
- VestingWallet is excluded from both fees and reflection during init — it never accumulates phantom tokens and transfers out of it are tax-free.

---

## Deployment

Eight transactions total. Each contract is independently deployable and verifiable.

### 1. Deploy StandardToken

No constructor arguments. Implementation contract — never initialised directly, only cloned.

### 2. Deploy TaxToken

No constructor arguments.

### 3. Deploy ReflectionToken

No constructor arguments.

### 4. Deploy BondingCurve

```
constructor(
    address router_,        // PancakeSwap V2 router
    address feeRecipient_,  // receives platform fees and creation fees
    uint256 platformFee_,   // BPS → feeRecipient (e.g. 100 = 1 %)
    uint256 charityFee_     // BPS → charityWallet (e.g. 0)
)
```

`deployer = msg.sender` is stored as an immutable. The factory address starts as `address(0)` and is set separately in step 8. `platformFee_ + charityFee_` must not exceed 250 BPS (2.5 %).

### 5. Deploy LaunchpadFactory

```
constructor(
    address bondingCurve_,           // step 4 address
    uint256 creationFee_,            // BNB wei (may be 0)
    uint256 defaultVirtualBNB_,      // BNB wei
    uint256 defaultMigrationTarget_, // BNB wei
    address standardImpl_,           // step 1 address
    address taxImpl_,                // step 2 address
    address reflectionImpl_,         // step 3 address
    address vestingWallet_           // address(0) — wired in step 7
)
```

### 6. Deploy VestingWallet

```
constructor(
    address owner_,    // deployer EOA — can void schedules and transfer ownership
    address factory_   // step 5 LaunchpadFactory address
)
```

### 7. Wire VestingWallet into the factory

```
LaunchpadFactory.setVestingWallet(<step 6 address>)
```

Owner-only. Can only be called once (reverts if `vestingWallet` is already set).

### 8. Point BondingCurve at the factory

```
BondingCurve.setFactory(<step 5 LaunchpadFactory address>)
```

Callable only by the `deployer` EOA (set at construction). Can be called again later to upgrade the factory.

---

## Security Model

| Role | Address | Powers |
|------|---------|--------|
| **BondingCurve deployer** | Immutable EOA set at construction | `setFactory()` only — swap the factory contract for upgrades |
| **LaunchpadFactory** (contract) | `bc.factory()` | All BondingCurve admin: register tokens, execute trades, set router/fees/recipients |
| **Factory owner** | `factory.owner()` | Factory admin via 48h timelocks for sensitive BondingCurve config; instant factory-level settings |

The BondingCurve deployer **cannot** directly call `setRouter`, `setFees`, `rescueBNB`, or any trading function. Updating the factory via `setFactory` only redirects admin control — the deployer gains no direct trading or fee power.

---

## Test Values (BSC Testnet)

Router: `0xD99D1c33F9fC3444f8101754aBC46c52416550D1`

| Parameter | Value |
|-----------|-------|
| `creationFee` | `1000000000000000` (0.001 BNB) |
| `defaultVirtualBNB` | `1000000000000000000` (1 BNB) |
| `defaultMigrationTarget` | `5000000000000000000` (5 BNB) |
| `platformFee` | `100` (1 %) |
| `charityFee` | `0` |

With these values and a MILLION supply token (620,000 tokens on the BC):
- Starting price ≈ 0.0000016 BNB/token
- Hit migration by sending ~5 BNB total across buys — the crossing buy auto-migrates

Testnet BNB faucet: `https://testnet.bnbchain.org/faucet-smart`

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
| `rescueBNB(addr)` | Sweep stray BNB from BondingCurve (above active pool totals) to `addr` |
| `setVestingWallet(addr)` | Wire in the VestingWallet address — owner only, callable once |

### VestingWallet (instant)

| Function | Description |
|----------|-------------|
| `voidSchedule(token, beneficiary)` | Burn all remaining unvested tokens for a given schedule — owner only |
| `transferOwnership(newOwner)` | Transfer VestingWallet admin rights |

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
| `getToken(addr)` | Full `TokenConfig` struct (mapping is `internal`; this replaces the public getter) |
| `getAmountOut(token, bnbIn)` | `(tokensOut, feeBNB)` — buy quote, migration-cap aware |
| `getAmountOutSell(token, tokensIn)` | `(bnbOut, feeBNB)` — sell quote |
| `getSpotPrice(token)` | BNB per whole token ×1e18 |

### On VestingWallet

| Function | Returns |
|----------|---------|
| `claimable(token, beneficiary)` | Tokens claimable right now |
| `schedules(token, beneficiary)` | `(total, start, claimed)` — full schedule |

### On LaunchpadFactory

| Function | Returns |
|----------|---------|
| `predictTokenAddress(creator, salt, impl)` | Off-chain vanity salt mining helper |
| `bondingCurve()` | Immutable BondingCurve address |
| `vestingWallet()` | VestingWallet address |
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
| Vesting escrow | Shared `VestingWallet` contract (one per deployment) |
| Max buy/sell tax | 10 % (1 000 BPS) per side |
| Min swap threshold | 0.02 % of token total supply |
| Reflection token default taxes | 0 % — owner configures post-deployment |
| Reflection minimum balance | 0.1 % of total supply (floor; owner may only raise) |
| Antibot range | 10–199 blocks |
| LP lock destination | `0x000…dEaD` (permanent) |
| Vanity address suffix | `0x1111` (last 4 hex digits) |
| Compiler | `solc ^0.8.32`, `optimizer: 200 runs` |

---

## Core Management Dashboard

Open [`coremanagement/index.html`](coremanagement/index.html) in a browser. Connect MetaMask (or any injected wallet) on BSC / BSC Testnet and enter the LaunchpadFactory address. Works read-only without a wallet via a configurable RPC endpoint.

Five tabs:

| Tab | Purpose |
|-----|---------|
| **Overview** | Factory and BondingCurve state side-by-side; active timelock countdown |
| **Create Token** | Full token creation flow — type selector, parameters, built-in salt miner (local, no RPC), one-click deploy |
| **Registry** | Browse all launched tokens or filter by creator; progress bars; quick Inspect link |
| **Inspector** | Per-token config, progress, spot price, live buy/sell/migrate with slippage and quote previews |
| **Admin** | Creation fee, default params, rescue BNB, manager access, ownership transfer, all five timelocked BondingCurve actions |

---

## License

[MIT](LICENSE)
