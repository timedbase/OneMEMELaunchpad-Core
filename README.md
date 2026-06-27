# OneMEME Launchpad — Core Contracts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.32-blue)](https://docs.soliditylang.org/)
[![Network: BSC](https://img.shields.io/badge/Network-BNB%20Smart%20Chain-yellow)](https://www.bnbchain.org/)

BSC meme-token launchpad with a USD-denominated bonding-curve presale, decaying antibot, creator vesting, and automatic DEX migration. Creators pick their own starting/migration market caps in dollars and their own curve/liquidity/creator allocation split per launch. StandardToken migrates to a PancakeSwap V3 1% pool with its LP locked in CreatorVault (creator earns an ongoing share of trading fees); TaxToken/ReflectionToken migrate to PancakeSwap V2 with LP permanently burned.

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
├── Launchpad.sol                Single contract: token creation, USD-denominated bonding
│                                 curve, buy/sell/migrate, DEX migration (V2 + V3), governance
└── CreatorVault.sol             Shared vesting escrow + locked V3 LP positions for all creators
```

---

## Architecture

The system is two contracts:

| Contract | Responsibilities |
|----------|-----------------|
| **Launchpad** | Everything: token clone deployment (CREATE2), USD→BNB conversion via a live USDC/WBNB spot price, per-token AMM state (`TokenConfig`), buy/sell/migrate execution, trade fee collection and dispatch, DEX migration (V2-and-burn for TaxToken/ReflectionToken, V3-and-lock for StandardToken), and all governance (ownership, timelocked config). One `owner`/`pendingOwner` gates everything — there is no separate factory/curve trust boundary to manage, and it is **not upgradeable** (a normal immutable contract, by design). |
| **CreatorVault** | Two roles in one shared contract: (1) vesting escrow for every creator allocation launched through Launchpad — beneficiaries claim linearly over 12 months, owner may void a schedule and burn the remainder; (2) SparkLocker-style lock for the V3 LP NFT minted on every StandardToken migration, splitting its accruing 1% trading fees 70/25/5 between creator/platform/charity. |

Tokens are minted **directly to Launchpad** at launch (it passes its own address as the single `launchManager_` parameter tokens expect). Launchpad distributes only the optional creator allocation out to CreatorVault; liquidity and bonding-curve supply simply stay in its own balance, since it's also the AMM.

---

## Token Lifecycle

```
createToken / createTT / createRFL
        │  (msg.value = creation fee + optional early buy)
        │  creator supplies: totalSupply (bounded — see Allocation Guardrails),
        │  curveBps, liquidityBps, creatorBps (must sum to 10000, each bounded),
        │  startMarketCapUSD, migrationMarketCapUSD (both 18-decimal USD, e.g. 5000e18 = $5,000)
        ▼
  Launchpad reads the live USDC/WBNB spot price and converts both $ targets into
  virtualBNB / migrationTarget (see USD-Denominated Launches below)
        ▼
  CREATE2 clone → initForLaunchpad(launchManager_ = address(launchpad))
  • 100 % of supply minted directly to Launchpad
  • Launchpad transfers only the creator allocation (if any) out to CreatorVault,
    calling addVesting(token, creator, amount) atomically
  • PancakeSwap V2 pair created immediately for TAX/RFL tokens (empty, no liquidity yet).
    StandardToken creates no pair up front — its V3 pool is created lazily at migration.
  • _inLaunchPhase = true  (taxes / reflection suppressed; StandardToken tracks this
    flag too, purely to gate transfers — see below)
  • TaxToken / ReflectionToken: CreatorVault excluded from fee and reflection during init
        │
        ▼
  Bonding-curve phase  (Launchpad acts as the AMM directly)
  • buy(token, minOut, deadline)    — user pays BNB, receives tokens
  • sell(token, amount, minBNB, dl) — user sells tokens back for BNB
  • Excess msg.value above creation fee used as an antibot-exempt early buy
  • While _inLaunchPhase: every transfer/transferFrom requires Launchpad or
    CreatorVault on at least one side (sender or recipient). Arbitrary peer-to-peer
    transfers — including a holder sending tokens directly into the pre-created TAX/RFL
    pair — revert with LaunchPhaseTransferRestricted(). This closes a front-running
    window where an attacker could seed an empty pair/pool and self-mint before
    migration, claiming real, un-burned LP. Pair/pool creation timing itself is
    unchanged; only token movement is gated.
        │
        ▼  raisedBNB ≥ migrationTarget
  Auto-migrate  (or call migrate() manually) — branches on token type:
  • TaxToken / ReflectionToken (useV3 = false): liquidityBps share of tokens + all raised
    BNB → PancakeSwap V2 addLiquidityETH; LP tokens sent to the dead wallet, permanently
    burned.
  • StandardToken (useV3 = true): raised BNB wrapped to WBNB; a fresh PancakeSwap V3 pool
    at the 1 % fee tier is created (or adopted if uninitialized) and initialized at the
    price implied by liqTokens:migrationBNB; a full-range [MIN_TICK, MAX_TICK] position
    is minted directly to CreatorVault and registered there — never burned. The creator
    (feeWallet) goes on to earn 70 % of that pool's own trading fees indefinitely; 25 %
    goes to a platform wallet, 5 % to a charity wallet (see Creator Vesting + LP Lock).
  • Launchpad calls postMigrateSetup() on the token — exits launch phase, enables DEX trading
  • _inLaunchPhase = false — normal DEX trading begins
```

---

## USD-Denominated Launches

Instead of fixed, owner-set `virtualBNB`/`migrationTarget` values, **every launch is priced
in dollars by the creator**, converted to BNB at creation time using a live spot read of a
configured USDC/WBNB pair.

```solidity
function _wbnbUsdReserves() private view returns (uint256 usdcReserve, uint256 wbnbReserve) {
    (uint112 r0, uint112 r1,) = IPancakePairMin(usdQuotePair).getReserves();
    (usdcReserve, wbnbReserve) = IPancakePairMin(usdQuotePair).token0() == usdcToken
        ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
}

virtualBNB      = (startMarketCapUSD     * wbnbReserve / totalSupply) * curveTokens / usdcReserve
migrationTarget = (migrationMarketCapUSD * wbnbReserve / totalSupply) * liqTokens   / usdcReserve
```

- **Spot price, not TWAP** — a deliberate choice: the read happens once, at launch time, not
  continuously, so the manipulation surface is far smaller than a real-time oracle (only the
  exact launch block's price matters, and only for that one transaction).
- **Migration cap is DEX-pool-implied**, not bonding-curve-implied — it's defined as the FDV
  the token will actually open at on the DEX once `liqTokens` + `migrationBNB` become
  liquidity: `FDV = (migrationBNB / liqTokens) × wbnbPriceUSD × totalSupply`. The bonding
  curve's own spot price diverges toward infinity right at the full-sell-through migration
  point, so it isn't usable as the basis for this definition.
- Both `startMarketCapUSD` and `migrationMarketCapUSD` are 18-decimal USD amounts (e.g.
  `5000e18` = $5,000) — BSC's USDC is 18 decimals (verified on-chain; **not** 6 like Ethereum
  mainnet's), matching this codebase's existing wei-scaled-everywhere convention.
- `migrationMarketCapUSD` must exceed `startMarketCapUSD` (both must be nonzero) —
  `InvalidMarketCaps()` otherwise.
- Division precedes the final multiply in both formulas, keeping intermediates within
  `uint256` range without needing a 512-bit `mulDiv`.
- `previewBNBTargets(...)` is a public view a frontend can call before submitting a launch,
  to show the creator the exact `virtualBNB`/`migrationTarget` (and therefore starting price)
  their chosen $ targets and allocation will resolve to right now.

### Allocation Guardrails

Creators set `curveBps`, `liquidityBps`, and `creatorBps` independently per launch (the
fixed 25/5/70-75 split is gone). Guardrails (owner-adjustable via `setAllocationBounds`,
default values shown) prevent degenerate splits:

| Bound | Default | Purpose |
|-------|---------|---------|
| `curveBps + liquidityBps + creatorBps == 10000` | — | Must sum to exactly 100 % |
| `liquidityBps >= minLiquidityBps` | 1000 (10 %) | Protects DEX liquidity depth at migration |
| `curveBps >= minCurveBps` | 3000 (30 %) | Protects against a degenerate near-zero presale |
| `creatorBps <= maxCreatorBps` | 2000 (20 %) | Protects buyers from an oversized creator cut |

Violating any bound reverts `InvalidAllocation()` before any oracle read or token deployment.

Creators also pick an arbitrary `totalSupply` per launch (18-decimal token amount), bounded
by owner-adjustable guardrails (`setSupplyBounds`):

| Bound | Default | Purpose |
|-------|---------|---------|
| `totalSupply >= minSupply` | 1e18 (1 token) | Blocks degenerate near-zero supplies |
| `totalSupply <= maxSupply` | 999_000_000_000_000e18 (999 trillion tokens) | Keeps amounts well within safe `uint256` headroom for the bonding-curve math |

Violating either bound reverts `InvalidSupply()`.

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

Note: since `grossNeeded` already accounts for the trade fee, a buy of exactly
`migrationTarget` (rather than the slightly larger `grossNeeded`) will fall just short of
triggering migration — integrators should send a small buffer above `migrationTarget`, or
simply call `getAmountOut`/`previewBNBTargets`-derived figures to size the exact buy.

---

## Trading

```solidity
launchpad.buy{value: bnbAmount}(token, minTokensOut, deadline);
launchpad.sell(token, tokenAmount, minBNBOut, deadline);   // requires prior approve(launchpad, amount)
launchpad.migrate(token);                                   // anyone may call once migrationTarget is reached
```

One contract, one approval target — there is no separate factory pass-through anymore.

---

## Parameters

| Parameter | Description |
|-----------|-------------|
| `creationFee` | BNB required to launch a token, in wei (default `0.0011 ether`; may be 0) |
| `platformFee` | BPS — goes to `feeRecipient` on each trade |
| `charityFee` | BPS — goes to `charityWallet` on each trade |
| `feeRecipient` | Receives platform fees and creation fees |
| `charityWallet` | Receives charity portion; `address(0)` redirects to `feeRecipient` |
| `pancakeRouter` | PancakeSwap V2 router; snapshotted per-token at creation |
| `v3PositionManager` / `v3Factory` | PancakeSwap V3 addresses used for StandardToken migrations |
| `usdcToken` / `usdQuotePair` | USD oracle config — see USD-Denominated Launches |
| `minCurveBps` / `minLiquidityBps` / `maxCreatorBps` | Allocation guardrails — see above |

`virtualBNB` and `migrationTarget` are computed per-launch from the creator's $ targets and
locked into that token's `TokenConfig` at creation; later oracle price movement never
retroactively affects an already-launched token.

---

## Fee Distribution

All fees are dispatched **immediately** — nothing is held in the contract.

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

Sensitive configuration changes go through a **48-hour timelock** using a propose → execute pattern.

| Action | Timelock ID |
|--------|-------------|
| Update PancakeSwap V2 router | `keccak256("SET_ROUTER")` |
| Update platform fee | `keccak256("SET_PLATFORM_FEE")` |
| Update charity fee | `keccak256("SET_CHARITY_FEE")` |
| Update fee recipient | `keccak256("SET_FEE_RECIPIENT")` |
| Update charity wallet | `keccak256("SET_CHARITY_WALLET")` |
| Update V3 position manager | `keccak256("SET_V3_POSITION_MANAGER")` |
| Update V3 factory | `keccak256("SET_V3_FACTORY")` |
| Update USDC/WBNB quote pair | `keccak256("SET_USD_QUOTE_PAIR")` |

Any queued action can be cancelled by the owner before execution.

`setCreatorVault`, `setStandardImpl`/`setTaxImpl`/`setReflectionImpl`, `setCreationFee`, and
`setAllocationBounds` are deliberately **not** timelocked (simple owner-only setters,
consistent with how factory-level settings worked before the merge) — wrapping them in the
same propose/execute pattern would be a reasonable follow-up if stronger time-delay
protection is wanted for these too.

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

## Creator Vesting + LP Lock (CreatorVault)

`CreatorVault` is the rebrand of the original `VestingWallet`, extended with a second,
independent responsibility: locking the V3 LP position minted on every StandardToken
migration (mirroring `spark/SparkLocker.sol`'s model exactly), so a creator earns an
ongoing reward from their own token's trading volume instead of the LP being burned.

### Vesting

- Optional, creator-chosen allocation (`creatorBps`, capped by `maxCreatorBps`), linear vest over **12 months**.
- Handled by a **single shared `CreatorVault` contract** — the same contract holds allocations for every token ever launched through Launchpad.
- At token creation, Launchpad transfers creator tokens directly to CreatorVault and calls `addVesting(token, creator, amount)` atomically.
- TaxToken and ReflectionToken exclude CreatorVault from fees and reflection during `initForLaunchpad`, so transfers to/from CreatorVault are always fee-free and never accumulate phantom reflection tokens.
- Beneficiary claims against their own address — ownership transfer on the token has no effect on vesting rights.

```solidity
// Beneficiary
creatorVault.claim(tokenAddress);                        // send claimable tokens to msg.sender
creatorVault.claimable(tokenAddress, beneficiary);       // view: tokens claimable now

// CreatorVault owner
creatorVault.voidSchedule(tokenAddress, beneficiary);    // burn all remaining unvested tokens immediately
creatorVault.transferOwnership(newOwner);
```

### V3 LP Lock (StandardToken only)

- At migration, Launchpad mints a full-range V3 position directly to CreatorVault and
  calls `registerPosition(token, tokenId, feeWallet, token0, token1, pool, positionManager)`
  — gated `onlyLaunchManager`, the same role used by `addVesting` (both are the Launchpad's
  address, tracked as one settable `launchManager` field).
- `feeWallet` is the token's creator (`tc.creator`), the same address used for vesting.
- Fees are split **70 % creator / 25 % platform / 5 % charity** by default — identical
  bps split and owner-adjustable via `setFeeBps`, exactly like `spark/SparkLocker.sol`.

```solidity
// Anyone may trigger a claim; proceeds always go to feeWallet/platformWallet/charityWallet
creatorVault.claimFees(tokenAddress);
creatorVault.pendingCreatorFees(tokenAddress);  // view: (token0, token1, amount0, amount1) creator share, uncollected
creatorVault.positions(tokenAddress);           // view: (tokenId, feeWallet, token0, token1, pool, positionManager)

// CreatorVault owner
creatorVault.setFeeBps(creatorBps, platformBps, charityBps);  // must sum to 10000
creatorVault.setPlatformWallet(addr);
creatorVault.setCharityWallet(addr);
creatorVault.claimAllFees();              // sweep every registered position; per-position failures don't revert the batch
creatorVault.claimFeesRange(from, to);    // paginated variant for large position counts
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

// impl: launchpad.standardImpl() | launchpad.taxImpl() | launchpad.reflectionImpl()
// creatorAddr: the EXACT wallet that will call createToken / createTT / createRFL
function mineVanitySalt(launchpadAddr, implAddr, creatorAddr) {
  const initcode = '0x3d602d80600a3d3981f3363d3d373d3d3d363d73'
    + implAddr.slice(2).toLowerCase()
    + '5af43d82803e903d91602b57fd5bf3';
  const initcodeHash = ethers.keccak256(ethers.getBytes(initcode));
  const abiCoder = ethers.AbiCoder.defaultAbiCoder();
  for (;;) {
    const userSalt = ethers.randomBytes(32);
    // Replicates the onchain binding: keccak256(abi.encode(msg.sender, userSalt))
    const onchainSalt = ethers.keccak256(abiCoder.encode(['address', 'bytes32'], [creatorAddr, userSalt]));
    const hash = ethers.keccak256(ethers.concat([new Uint8Array([0xff]), launchpadAddr, onchainSalt, initcodeHash]));
    const addr = ethers.getAddress('0x' + hash.slice(-40));
    if (addr.toLowerCase().endsWith('1111')) return { userSalt: ethers.hexlify(userSalt), address: addr };
  }
}

const { userSalt } = mineVanitySalt(launchpadAddr, implAddr, creatorAddr);
const creationFee = await launchpad.creationFee();

// All three creation calls share the same allocation + USD market-cap fields:
//   curveBps, liquidityBps, creatorBps (sum to 10000), startMarketCapUSD, migrationMarketCapUSD

// StandardToken
await launchpad.createToken(
  [name, symbol, totalSupply, curveBps, liquidityBps, creatorBps,
   startMarketCapUSD, migrationMarketCapUSD, enableAntibot, antibotBlocks, metaURI, userSalt],
  { value: creationFee + earlyBuyWei }  // earlyBuyWei = 0n if no early buy
);

// TaxToken
await launchpad.createTT(
  [name, symbol, metaURI, totalSupply, curveBps, liquidityBps, creatorBps,
   startMarketCapUSD, migrationMarketCapUSD, enableAntibot, antibotBlocks, userSalt],
  { value: creationFee + earlyBuyWei }
);

// ReflectionToken
await launchpad.createRFL(
  [name, symbol, metaURI, totalSupply, curveBps, liquidityBps, creatorBps,
   startMarketCapUSD, migrationMarketCapUSD, enableAntibot, antibotBlocks, userSalt],
  { value: creationFee + earlyBuyWei }
);
```

`totalSupply`: an arbitrary 18-decimal token amount, bounded by owner-adjustable `minSupply` (default 1e18 = 1 token) / `maxSupply` (default 999_000_000_000_000e18 = 999 trillion tokens) — see `setSupplyBounds`. Expected mining iterations: ~65 536 (2^16).

---

## Token Types

### `StandardToken`

Plain ERC-20. No taxes, no reflection. Creator vesting supported via CreatorVault if `creatorBps > 0`. Tracks its own launch phase (`_inLaunchPhase`, mirroring TaxToken/ReflectionToken) purely to enforce the transfer restriction described above — `postMigrateSetup()` exits it, after which the token trades exactly like a normal unrestricted ERC-20. **Migrates to a PancakeSwap V3 1 % pool**, full-range, locked in CreatorVault — see Creator Vesting + LP Lock.

### `TaxToken`

Configurable buy/sell taxes with up to 5 components per side: marketing, team, treasury, burn, and liquidity. Taxes accumulate in the token contract and are swapped to BNB on qualifying transfers post-migration. Max 10 % total per side. **Migrates to PancakeSwap V2, LP burned** — unchanged.

- Minimum `swapThreshold` is 0.02 % of total supply.
- Router and PancakeSwap pair are configured at token creation; `postMigrateSetup()` activates normal tax/swap behaviour after migration.
- CreatorVault is excluded from fees during init — transfers to/from it carry zero tax.

### `ReflectionToken`

RFI-style passive reflection plus optional custom reflection token distribution. **Migrates to PancakeSwap V2, LP burned** — unchanged.

- **Taxes default to 0 %** at deployment. The token owner must call `setBuyTaxes` / `setSellTaxes` post-deployment to activate fees.
- **Native mode** (`reflectionToken == address(0)`): the reflection tax passively increases all non-excluded holders' balances by reducing `_rTotal`.
- **Custom mode**: reflection tax is accumulated, swapped to a configured ERC-20 token, and pushed proportionally to qualifying holders.
- **Minimum balance threshold**: holders must hold at least 0.1 % of total supply to receive custom reflection distributions. The owner may raise this threshold but never lower it below 0.1 %.
- Minimum `swapThreshold` is 0.02 % of total supply.
- Router and PancakeSwap pair are configured at token creation; `postMigrateSetup()` activates normal behaviour after migration.
- CreatorVault is excluded from both fees and reflection during init — it never accumulates phantom tokens and transfers out of it are tax-free.

---

## Deployment

`CreatorVault` must be deployed after `Launchpad` (it takes Launchpad's address directly as
its `launchManager_` constructor argument) but Launchpad's constructor needs CreatorVault's
address too — broken by passing a placeholder `launchManager_` to CreatorVault at construction
and correcting it afterward (see step 3 below).

### 1. Deploy StandardToken / TaxToken / ReflectionToken

No constructor arguments. Implementation contracts — never initialised directly, only cloned.

### 2. Deploy Launchpad

```
constructor(
    address router_,             // PancakeSwap V2 router
    address v3PositionManager_,  // PancakeSwap V3 NonfungiblePositionManager
    address v3Factory_,          // PancakeSwap V3 factory
    address feeRecipient_,       // receives platform fees and creation fees
    uint256 platformFee_,        // BPS → feeRecipient (e.g. 100 = 1 %)
    uint256 charityFee_,         // BPS → charityWallet (e.g. 0)
    address standardImpl_,       // step 1 address
    address taxImpl_,            // step 1 address
    address reflectionImpl_,     // step 1 address
    address creatorVault_,       // CreatorVault address (deploy that first, see below — or
                                  // deploy Launchpad and CreatorVault in either order, since
                                  // neither's constructor actually calls the other)
    address usdcToken_,          // USDC token address
    address usdQuotePair_,       // a real pair containing usdcToken_ + WBNB
    uint256 creationFee_         // BNB wei (may be 0)
)
```

BSC mainnet addresses (verified on-chain): V3 NonfungiblePositionManager
`0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`, V3 factory
`0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` (`feeAmountTickSpacing(10000) == 200`), USDC
`0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` (18 decimals on BSC, **not** 6), real USDC/WBNB
PancakeSwap V2 pair `0xd99c7F6C65857AC913a8f880A4cb84032AB2FC5b`.

### 3. Deploy CreatorVault

```
constructor(
    address owner_,         // deployer EOA — can void schedules, claim/configure LP fees, transfer ownership
    address launchManager_  // step 2 Launchpad address
)
```

If CreatorVault is deployed *before* Launchpad (since Launchpad's constructor needs its
address), pass a temporary placeholder for `launchManager_` and correct it afterward:

```
CreatorVault.setLaunchManager(<Launchpad address>)   // owner-only
```

### 4. Sync CreatorVault into Launchpad (if not supplied correctly at construction)

```
Launchpad.setCreatorVault(<CreatorVault address>)
```

Owner-only.

---

## Security Model

| Role | Address | Powers |
|------|---------|--------|
| **Launchpad owner** | `launchpad.owner()` | Everything — timelocked for sensitive DEX/fee/oracle config, instant for the rest (implementation addresses, creation fee, allocation bounds, CreatorVault address, rescue) |
| **CreatorVault owner** | `vault.owner()` | Void vesting schedules, configure/claim LP fees, transfer ownership |

There is no separate deployer/factory split anymore — the prior two-tier permission system
existed solely so `BondingCurve` could trust an external, swappable `LaunchpadFactory`. With
both merged into one contract, a single owner (2-step transfer, same pattern as before) is
the entire trust model.

---

## Owner Administration

### Launchpad (instant)

| Function | Description |
|----------|-------------|
| `setCreationFee(bnbWei)` | Update creation fee |
| `setAllocationBounds(minCurveBps, minLiquidityBps, maxCreatorBps)` | Update the per-launch allocation guardrails |
| `setSupplyBounds(minSupply, maxSupply)` | Update the per-launch total-supply guardrails |
| `setStandardImpl(addr)` / `setTaxImpl(addr)` / `setReflectionImpl(addr)` | Swap the clone target for new launches |
| `setCreatorVault(addr)` | Update the CreatorVault address |
| `transferOwnership(addr)` / `acceptOwnership()` | Two-step ownership transfer |
| `cancelAction(bytes32)` | Cancel a queued timelock action |
| `rescueBNB(addr)` | Sweep stray BNB (balance above all active pools' raised totals) to `addr` |
| `rescueToken(token, addr)` | Sweep a token's balance to `addr` — reverts `ActivePool()` while that token's bonding curve is still active |

### CreatorVault (instant)

| Function | Description |
|----------|-------------|
| `voidSchedule(token, beneficiary)` | Burn all remaining unvested tokens for a given schedule — owner only |
| `transferOwnership(newOwner)` | Transfer CreatorVault admin rights |
| `setLaunchManager(addr)` | Update the address allowed to call `addVesting` and `registerPosition` — owner only |
| `setPlatformWallet(addr)` / `setCharityWallet(addr)` | Update LP-fee split recipients — owner only |
| `setFeeBps(creator, platform, charity)` | Update the LP-fee split (must sum to 10000) — owner only |
| `claimFees(token)` | Collect + distribute a position's accrued V3 fees — anyone may call; proceeds go to feeWallet/platformWallet/charityWallet, not the caller |
| `claimAllFees()` / `claimFeesRange(from, to)` | Batch/paginated fee sweep across every registered position — owner only |

### Launchpad Config (48h timelock)

| Propose | Execute | Description |
|---------|---------|-------------|
| `proposeSetRouter(addr)` | `executeSetRouter()` | Update PancakeSwap V2 router |
| `proposeSetV3PositionManager(addr)` | `executeSetV3PositionManager()` | Update PancakeSwap V3 position manager |
| `proposeSetV3Factory(addr)` | `executeSetV3Factory()` | Update PancakeSwap V3 factory |
| `proposeSetUsdQuotePair(addr)` | `executeSetUsdQuotePair()` | Update the USDC/WBNB oracle pair (validated to actually contain USDC at propose time) |
| `proposeSetPlatformFee(bps)` | `executeSetPlatformFee()` | Update platform fee BPS |
| `proposeSetCharityFee(bps)` | `executeSetCharityFee()` | Update charity fee BPS |
| `proposeSetFeeRecipient(addr)` | `executeSetFeeRecipient()` | Update fee recipient |
| `proposeSetCharityWallet(addr)` | `executeSetCharityWallet()` | Set charity wallet (0x0 to disable) |

---

## Key View Functions

### On Launchpad

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
| `previewBNBTargets(startUSD, migUSD, supply, curveBps, liquidityBps, creatorBps)` | `(virtualBNB, migrationTarget)` a launch with these parameters would resolve to right now |
| `predictTokenAddress(creator, salt, impl)` | Off-chain vanity salt mining helper |
| `v3PositionManager()` / `v3Factory()` | Configured PancakeSwap V3 addresses |
| `usdcToken()` / `usdQuotePair()` | Configured USD oracle addresses |
| `minCurveBps()` / `minLiquidityBps()` / `maxCreatorBps()` | Current allocation guardrails |
| `minSupply()` / `maxSupply()` | Current total-supply guardrails |
| `creatorVault()` | Configured CreatorVault address |
| `timelockExpiry(bytes32)` | Unix timestamp when a queued action unlocks |

### On CreatorVault

| Function | Returns |
|----------|---------|
| `claimable(token, beneficiary)` | Tokens claimable right now |
| `schedules(token, beneficiary)` | `(total, start, claimed)` — full vesting schedule |
| `positions(token)` | `(tokenId, feeWallet, token0, token1, pool, positionManager)` — locked V3 position |
| `pendingCreatorFees(token)` | `(token0, token1, amount0, amount1)` — creator's uncollected share estimate |
| `positionTokenCount()` | Number of tokens with a registered V3 position |
| `creatorBps()` / `platformBps()` / `charityBps()` | Current LP-fee split (default 7000/2500/500) |

---

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Creation fee | BNB wei — default `0.0011 ether`, set by owner |
| Max total trade fee | 2.5 % (250 BPS) |
| Allocation guardrails | curve ≥30 %, liquidity ≥10 %, creator ≤20 % of supply (owner-adjustable) |
| Timelock delay | 48 hours |
| Vesting duration | 365 days linear |
| Vesting + LP-lock escrow | Shared `CreatorVault` contract (one per deployment) |
| Max buy/sell tax | 10 % (1 000 BPS) per side |
| Min swap threshold | 0.02 % of token total supply |
| Reflection token default taxes | 0 % — owner configures post-deployment |
| Reflection minimum balance | 0.1 % of total supply (floor; owner may only raise) |
| Antibot range | 10–199 blocks |
| V2 LP lock destination (TaxToken/ReflectionToken) | `0x000…dEaD` (permanent burn) |
| V3 LP lock destination (StandardToken) | `CreatorVault` (NFT held, never burned; fees flow to creator/platform/charity) |
| V3 fee tier / tick range (StandardToken) | 1 % (10000), full range `[-887200, 887200]` |
| V3 LP fee split | 70 % creator / 25 % platform / 5 % charity (owner-adjustable) |
| Vanity address suffix | `0x1111` (last 4 hex digits) |
| Compiler | `solc ^0.8.32`, `optimizer: 200 runs`, `viaIR: true` |

---

## License

[MIT](LICENSE)
