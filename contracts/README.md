# OneMEME Launchpad — Contracts

## Architecture

```
contracts/
├── Launchpad.sol       — single entry point: token creation, bonding curve, migration
├── CreatorVault.sol    — vesting + V3 LP-lock and fee distribution
├── tokens/
│   ├── StandardToken.sol    — plain ERC-20 + permit; migrates to PancakeSwap V3
│   ├── TaxToken.sol         — buy/sell tax with auto-swap; migrates to V2
│   └── ReflectionToken.sol  — holder reflection; migrates to V2
└── interfaces/
    ├── ILaunchpadToken.sol
    ├── ICreatorVault.sol
    ├── IPancakeRouter02.sol
    └── ...
```

There is no proxy, no upgradeability, and no cross-contract trust boundary between a "factory" and a "bonding curve". Everything lives in `Launchpad.sol`. A single `owner` / 2-step `pendingOwner` governs it, with sensitive parameters behind a 48-hour timelock.

---

## Token Types

| Type | Tax on transfer | Post-migration DEX | LP fate |
|---|---|---|---|
| `StandardToken` | None | PancakeSwap V3, 1% pool | Locked in `CreatorVault`; creator earns ongoing fees |
| `TaxToken` | Buy/sell tax, auto-swap to BNB | PancakeSwap V2 | Burned to dead address |
| `ReflectionToken` | Transfer tax redistributed to holders | PancakeSwap V2 | Burned to dead address |

During the bonding phase all three types restrict transfers to `launchManager` and `creatorVault` only, preventing secondary markets from forming before migration. This is lifted by `postMigrateSetup()` on migration.

---

## Launch Flow

### 1. Mine a vanity salt

Token addresses are deployed via EIP-1167 minimal proxy (`CREATE2`). The launchpad requires the resulting address to end in `0x1111`. Callers mine an off-chain salt and pass it in the creation params. The salt is bound to `msg.sender` inside the contract, so front-runners cannot steal a mined salt.

```solidity
// Predicted address helper (view, free to call)
launchpad.predictTokenAddress(creator, userSalt, implAddress);
```

### 2. Create a token

Three creation functions, one per token type:

```solidity
launchpad.createToken(BaseParams memory p)      payable → address  // StandardToken
launchpad.createTT(CreateTTParams memory p)     payable → address  // TaxToken
launchpad.createRFL(CreateRFLParams memory p)   payable → address  // ReflectionToken
```

All accept the same core fields:

| Field | Type | Description |
|---|---|---|
| `name`, `symbol`, `metaURI` | string | Token metadata |
| `totalSupply` | uint256 | 18-decimal, bounded by `minSupply`/`maxSupply` |
| `curveBps` | uint256 | % of supply sold on the bonding curve |
| `liquidityBps` | uint256 | % of supply sent to DEX at migration |
| `creatorBps` | uint256 | % of supply vested to creator (may be 0) |
| `startMarketCapUSD` | uint256 | 18-decimal USD; sets the curve's opening price |
| `migrationMarketCapUSD` | uint256 | 18-decimal USD; triggers migration when reached |
| `enableAntibot` | bool | Applies a linearly-decaying penalty during the first N blocks |
| `antibotBlocks` | uint256 | 10–199; duration of the antibot decay window |
| `vestingDuration` | uint256 | Seconds the creator allocation vests over; minimum 30 days; ignored when `creatorBps == 0` |
| `salt` | bytes32 | Creator-mined vanity salt |

The three bps fields must sum to exactly 10,000. Guardrails enforced at launch:

| Bound | Default | Meaning |
|---|---|---|
| `minCurveBps` | 3000 (30%) | Minimum presale allocation |
| `minLiquidityBps` | 1000 (10%) | Minimum DEX liquidity at migration |
| `maxCreatorBps` | 2000 (20%) | Maximum creator vesting allocation |

Any BNB sent above the `creationFee` is treated as an early buy and executed immediately after registration.

### 3. USD-Denominated Pricing

Market-cap targets are specified in USD (`18-decimal`), not BNB. At launch time, the contract reads a live spot price from a configured USDC/WBNB PancakeSwap V2 pair and converts both targets to BNB:

```
virtualBNB      = (startMarketCapUSD     × wbnbReserve / totalSupply) × curveTokens / usdcReserve
migrationTarget = (migrationMarketCapUSD × wbnbReserve / totalSupply) × liqTokens   / usdcReserve
```

Division precedes the final multiply to stay within `uint256` without needing 512-bit arithmetic.

The quote pair address is owner-configurable (48h timelock, validated against the configured router's WETH address on set). USDC on BSC is **18 decimals** (`0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d`).

Off-chain preview (view, free):

```solidity
launchpad.previewBNBTargets(startUSD, migrationUSD, supply, curveBps, liqBps, creatorBps);
```

### 4. Buy / Sell

```solidity
launchpad.buy{value: bnbIn}(token, minTokensOut, deadline)
launchpad.sell(token, tokenAmount, minBNBOut, deadline)
```

Both are guarded by `nonReentrant` and revert after `deadline`. A `minOut` / `minBNBOut` slippage guard is enforced before any state change.

**Bonding curve** — constant-product `k = virtualBNB × bcTokensTotal`:

```
tokensOut = poolTokens - k / (poolBNB + netBNBIn)   [buy]
grossBNB  = poolBNB    - k / (poolTokens + tokensIn) [sell]
```

where `poolBNB = virtualBNB + raisedBNB` and `poolTokens = bcTokensTotal - bcTokensSold`.

The sell path is capped at `raisedBNB` — the curve can never pay out BNB it hasn't actually received (`InsufficientPoolBNB`).

**Antibot** — during the first `antibotBlocks` blocks after creation a linearly-decaying fraction of bought tokens is sent to `0x...dEaD`. By the last block of the window the penalty is 0. The creator's early buy (if any) skips the antibot.

### 5. Migration

Migration is triggered automatically at the end of the buy that pushes `raisedBNB` to `migrationTarget`. If it fails (e.g. DoS via pre-initialized V3 pool), the buy still commits and `migrationPending = true` is set so that trading is paused and recovery can proceed in a separate transaction.

```solidity
launchpad.migrate(token)             // anyone; requires migrationPending == true
launchpad.emergencyMigrate(token)    // owner only; bypasses the DEX, sends funds to owner
```

**StandardToken → V3:**
1. BNB is wrapped to WBNB
2. A fresh PancakeSwap V3 1% pool is created (or an uninitialised shell is adopted if one was pre-created)
3. A full-range position is minted directly to `CreatorVault`
4. The position is registered so the creator can claim its 1% fee accrual indefinitely

**TaxToken / ReflectionToken → V2:**
1. `addLiquidityETH` is called with the raised BNB and liquidity token allocation
2. LP tokens go directly to the dead address — permanently burned

Both paths enforce 99% minimums on token and BNB amounts to protect against sandwich attacks on migration.

After migration, `postMigrateSetup()` is called on the token contract to lift the bonding-phase transfer restriction.

**Invariants maintained throughout:**
- `tc.raisedBNB ≤ _totalRaisedBNB ≤ address(this).balance`
- `bcTokensSold == bcTokensTotal` when migration triggers (no unsold tokens exist at the cap)
- `rescueBNB` can only withdraw `balance - _totalRaisedBNB` (never touches active pool BNB)

---

## CreatorVault

One shared contract for every token launched. Two independent responsibilities:

### Linear vesting

Creator token allocations (when `creatorBps > 0`) vest linearly over the `vestingDuration` chosen at launch (minimum 30 days, no upper bound).

```solidity
creatorVault.claim(token)                          // creator claims vested tokens
creatorVault.claimable(token, beneficiary)         // view: how much is claimable now
creatorVault.voidSchedule(token, beneficiary)      // owner only; burns remainder
```

### V3 LP lock and fee distribution

For every `StandardToken` migration, the V3 NFT position is minted to `CreatorVault` and registered. Trading fees accrued by the pool are split on each `claimFees` call:

| Recipient | Default share |
|---|---|
| Creator (`feeWallet`) | 70% |
| Platform | 25% |
| Charity | 5% |

```solidity
creatorVault.claimFees(token)           // creator or owner; claims one token's fees
creatorVault.claimAllFees()             // owner; sweeps all positions (skips failures)
creatorVault.claimFeesRange(from, to)   // paginated variant for large position lists
creatorVault.pendingCreatorFees(token)  // view; estimates uncollected creator share via fee-growth math
```

Fee bps and wallet addresses are owner-configurable.

---

## Governance

### Instant (owner only)

| Function | What it changes |
|---|---|
| `setCreationFee` | BNB fee required to create a token |
| `setAllocationBounds` | `minCurveBps`, `minLiquidityBps`, `maxCreatorBps` |
| `setSupplyBounds` | `minSupply`, `maxSupply` |
| `setStandardImpl` / `setTaxImpl` / `setReflectionImpl` | Clone implementation addresses |
| `setCreatorVault` | CreatorVault address |
| `transferOwnership` / `acceptOwnership` | 2-step ownership transfer |
| `cancelAction` | Cancel a pending timelock action |

### 48-hour timelock

These require a `propose*` call first, then `execute*` after 48 hours:

| Action | Key |
|---|---|
| Router | `TL_SET_ROUTER` |
| V3 position manager | `TL_SET_V3_POSITION_MANAGER` |
| V3 factory | `TL_SET_V3_FACTORY` |
| USDC/WBNB quote pair | `TL_SET_USD_QUOTE_PAIR` |
| Platform fee | `TL_SET_PLATFORM_FEE` |
| Charity fee | `TL_SET_CHARITY_FEE` |
| Fee recipient | `TL_SET_FEE_RECIPIENT` |
| Charity wallet | `TL_SET_CHARITY_WALLET` |

Total fees (platform + charity) are hard-capped at 2.5% (`MAX_TOTAL_FEE = 250 bps`), enforced at both propose and execute time.

### Rescue

```solidity
launchpad.rescueBNB(to)            // only withdraws balance surplus above _totalRaisedBNB
launchpad.rescueToken(token, to)   // only callable after migration or for unrelated ERC-20s
```

---

## Security Properties

**Reentrancy** — `nonReentrant` guard on all state-mutating public functions. `_tryMigrateExternal` is intentionally not guarded so the outer buy can `try/catch` it internally; it is gated to `msg.sender == address(this)` instead.

**DoS via pre-initialized V3 pool** — An attacker can call `createPool` on the V3 factory for a CREATE2-predicted token address before migration. If the pool is already initialised when migration runs, `_getOrCreateV3Pool` reverts with `PoolAlreadyExists`. The outer `try/catch` lets the cap-triggering buy commit its BNB accounting to storage, sets `migrationPending = true`, and pauses further trading. The owner can then either retry `migrate()` once the DoS is lifted or call `emergencyMigrate()` to redirect funds to themselves for manual liquidity provisioning.

**BNB accounting** — `InsufficientContractBalance` is checked in both `_doMigrate` and `emergencyMigrate` before any external BNB transfer. This mirrors the `InsufficientPoolBNB` guard on the sell path and prevents any unexpected accounting drift from causing an overspend.

**Front-running salt** — `_cloneCreate2` binds the salt to `keccak256(abi.encode(msg.sender, userSalt))`, so a mined salt cannot be stolen by a front-runner deploying from a different address.

**Launch-phase transfer restriction** — All three token types block transfers to or from any address other than `launchManager` and `creatorVault` until `postMigrateSetup()` is called. This prevents pre-migration DEX pools from receiving tokens, nullifying the pre-initialization DoS vector for token balance (as opposed to the BNB price vector covered above).

**Router snapshot** — `tc.router` is snapshotted at registration. A future `setRouter` call does not affect tokens already on the curve.

---

## Deployment

Constructor parameters (all addresses validated non-zero):

| Parameter | Description |
|---|---|
| `router_` | PancakeSwap V2 router (validated: `factory()` and `WETH()` must be non-zero) |
| `v3PositionManager_` | PancakeSwap V3 NonfungiblePositionManager |
| `v3Factory_` | PancakeSwap V3 Factory |
| `feeRecipient_` | Address receiving platform fees |
| `platformFee_` | Bps charged on each buy/sell as platform fee |
| `charityFee_` | Bps charged on each buy/sell as charity fee |
| `standardImpl_` | Deployed `StandardToken` implementation |
| `taxImpl_` | Deployed `TaxToken` implementation |
| `reflectionImpl_` | Deployed `ReflectionToken` implementation |
| `creatorVault_` | Deployed `CreatorVault` |
| `usdcToken_` | USDC address (`0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` on BSC — 18 decimals) |
| `usdQuotePair_` | USDC/WBNB PancakeSwap V2 pair (validated at construction) |
| `creationFee_` | BNB required to launch a token (may be 0) |

`CreatorVault` constructor takes `(owner_, launchManager_)`. Both will be the deployer address initially; `launchManager` is updated to the `Launchpad` address after deployment via `setLaunchManager`.

---

## Key View Functions

```solidity
launchpad.getToken(token)                              // full TokenConfig struct
launchpad.getAmountOut(token, bnbIn)                   // (tokensOut, feeBNB) — buy quote
launchpad.getAmountOutSell(token, tokensIn)            // (bnbOut, feeBNB)    — sell quote
launchpad.getSpotPrice(token)                          // price in BNB per token (18-decimal)
launchpad.previewBNBTargets(startUSD, migUSD, ...)     // (virtualBNB, migrationTarget) for given params
launchpad.predictTokenAddress(creator, salt, impl)     // CREATE2 address before deployment
launchpad.totalTokensLaunched()                        // allTokens.length
launchpad.getTokensByCreator(creator)                  // all tokens by one address
```

---

## Error Reference

| Error | Where | Meaning |
|---|---|---|
| `NotOwner` / `NotPendingOwner` | Admin | Access control |
| `Reentrancy` | All mutating fns | Nested call blocked |
| `ZeroAddress` / `ZeroAmount` | Validation | Input sanity |
| `FeeExceedsMax` | Fee setters | Total fee > 2.5% |
| `InsufficientCreationFee` | createToken* | `msg.value < creationFee` |
| `CloneFailed` | CREATE2 | Deploy returned address(0) |
| `VanityAddressRequired` | CREATE2 | Address does not end in 0x1111 |
| `InvalidAllocation` | Launch | BPS don't sum to 10000, or guardrail violated |
| `InvalidMarketCaps` | Launch | Migration USD <= start USD, or either is 0 |
| `InvalidSupply` | Launch | Outside `minSupply`/`maxSupply` |
| `InvalidUsdQuotePair` | Oracle | Pair doesn't contain USDC + WBNB |
| `UnknownToken` | Trading | Token not registered |
| `AlreadyMigrated` | Trading | Token already on DEX |
| `MigrationPending` | Trading | Buy/sell blocked; awaiting migration recovery |
| `MigrationTargetNotReached` | migrate() | `raisedBNB < migrationTarget` and no pending flag |
| `ExceedsSoldSupply` | sell() | Selling more than was bought from the curve |
| `LiquidityReserveViolation` | _doMigrate | Token balance < liqTokens |
| `InsufficientContractBalance` | _doMigrate / emergencyMigrate | BNB balance < raisedBNB |
| `InsufficientPoolBNB` | sell() | Gross BNB out > raisedBNB |
| `SlippageTooLittleBNB` / `SlippageTooFewTokens` | buy/sell | Output below caller's minimum |
| `PoolAlreadyExists` | V3 migration | V3 pool pre-initialized by attacker |
| `CreatorVaultNotSet` | V3 migration | `creatorVault == address(0)` |
| `AntibotBlocksOutOfRange` | Launch | `antibotBlocks` outside 10–199 |
| `DeadlineExpired` | buy/sell | `block.timestamp > deadline` |
| `TimelockNotQueued` / `TimelockNotExpired` | Governance | Timelock state errors |
| `ActivePool` | rescueToken | Token still in bonding phase |
| `BNBTransferFailed` / `RefundFailed` / `TransferFailed` | Transfers | Low-level call returned false |
