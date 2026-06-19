# Spark — Token Launcher

Spark lets anyone deploy a meme token and seed permanent V3 liquidity in a single transaction on any registered DEX. Liquidity is locked forever in SparkLocker; only accrued swap fees can be claimed.

---

## Contracts

| File | Contract | Role |
|------|----------|------|
| `SparkToken.sol` | `SparkToken` | ERC-20 + EIP-2612 implementation used as the EIP-1167 clone template |
| `SparkLauncher.sol` | `SparkLauncher` | Orchestrates every launch — clones token, creates pool, seeds liquidity |
| `SparkLocker.sol` | `SparkLocker` | Permanent LP-NFT vault; distributes swap fees to creator, platform, and charity |

---

## Architecture

```
Creator
  │
  │  launch(name, symbol, metaURI, feeWallet, factory, quoteToken, extraBuy)
  │  + ETH (≥ fee)  OR  ERC-20 approval
  ▼
SparkLauncher
  ├─ validates factory  →  looks up DexConfig (positionManager, router)
  ├─ clone(SparkToken impl)  →  SparkToken (1 B supply minted to launcher)
  ├─ WETH.deposit(msg.value)               [native quote]
  │  OR transferFrom(creator, fee+extraBuy) [ERC-20 quote]
  ├─ V3Factory.createPool(quoteToken, sparkToken, 1%)
  ├─ pool.initialize(sqrtPriceX96)
  ├─ positionManager.mint(fullRange)  →  LP NFT  →  SparkLocker
  ├─ SparkLocker.registerPosition(token, tokenId, feeWallet, token0, token1, pool, positionManager)
  ├─ swapRouter.exactInputSingle(quoteDust → sparkToken → creator)
  └─ transfer(remainingSparkTokens → creator)

SparkLocker  (holds LP NFTs forever)
  └─ claimFees(token)  →  70% feeWallet  +  25% platformWallet  +  5% charityWallet
```

---

## Launch Flow

1. **Validate** — launcher checks the factory is in the DEX registry and the quote token is registered.

2. **Fee collection**
   - `WETH` (native): send `ETH >= launchFee`. The launcher wraps the full `msg.value` to WETH. Any ETH above the fee becomes `extraBuy`.
   - ERC-20: send 0 ETH, approve `launchFee + extraBuy` beforehand; launcher pulls via `transferFrom`.

3. **Token deployment** — an EIP-1167 minimal-proxy clone of `SparkToken` is deployed and `initSpark` is called. `metaURI` is written, **1 000 000 000** tokens are minted to the launcher, and no owner is ever assigned — the token is permanently ownerless.

4. **Pool creation** — a V3 pool (`quoteToken / SparkToken`, **1 % fee tier**) is created on the chosen DEX and initialised at the price implied by the seeded amounts. Reverts with `PoolAlreadyExists` if that pair already has a 1 % pool on the same factory.

5. **Liquidity seeding** — a full-range position (`tick −887 200 → +887 200`) is minted:
   - **99.99 %** of supply (999 900 000 tokens)
   - **100 %** of the launch fee in the chosen quote token

   The LP NFT goes directly to `SparkLocker` and is never transferable out.

6. **Locker registration** — `SparkLocker.registerPosition` records the NFT id, fee wallet, pool address, and position manager for this launch.

7. **Instant buy** — any remaining quote-token balance (rounding dust + any `extraBuy`) is swapped through the new pool via `exactInputSingle`. Purchased tokens go straight to the creator atomically with the launch.

8. **Creator allocation** — the remaining ~0.01 % of supply (100 000 tokens + pool-mint dust) is sent to the creator.

---

## DEX Registry

SparkLauncher maintains a whitelist of V3-compatible DEXes. Each entry maps a factory address to its position manager and swap router.

The caller passes the factory address of their chosen DEX to `launch()`. The launcher validates it against the registry and uses the stored position manager and router for all DEX interactions.

```
dexes[factory] = DexConfig { positionManager, router, enabled }
```

Owner functions:

| Function | Description |
|----------|-------------|
| `addDex(factory, positionMgr, router)` | Register or update a DEX |
| `disableDex(factory)` | Block new launches on this factory; existing positions unaffected |

---

## Quote Tokens

Quote tokens are DEX-agnostic — the same token (e.g. USDC) can be used on any registered DEX.

| Function | Description |
|----------|-------------|
| `addQuoteToken(token, fee, decimals)` | Register or update a quote token |
| `disableQuoteToken(token)` | Block new launches using this token |

| Quote token | Default fee | Payment method |
|-------------|-------------|----------------|
| WETH | 0.0005 ETH | ETH sent with tx (wrapped automatically) |
| USDC | 1 USDC (1 000 000 raw) | `transferFrom` |
| USDT | 1 USDT (1 000 000 raw) | `transferFrom` |
| Any ERC-20 | Set by owner | `transferFrom` |

`isNative` is always `true` when the token address equals WETH, regardless of what `addQuoteToken` sets.

---

## Fee Wallet & Claiming

- Set by the creator at launch; defaults to `msg.sender` if `address(0)` is passed.
- **Only the fee wallet OR the platform owner** may call `claimFees(token)`.
- The platform owner may also call `claimAllFees()` or `claimFeesRange(from, to)` to sweep positions in bulk.

### Fee split

Default values — updatable by the locker owner via `setFeeBps(creator, platform, charity)`. The three values must sum to exactly 10 000.

| Recipient | Default share | Interaction |
|-----------|--------------|-------------|
| Creator fee wallet | 70 % (7 000 bps) | Initiates `claimFees` |
| Platform wallet | 25 % (2 500 bps) | Passive recipient |
| Charity wallet | 5 % (500 bps) | Passive recipient |

Fees are distributed atomically. Platform receives the remainder after creator and charity to absorb rounding dust.

### Pending fee view

```solidity
pendingCreatorFees(address token)
    returns (address token0, address token1, uint256 amount0, uint256 amount1)
```

Returns the creator's share of currently uncollected fees, computed using the full Uniswap V3 fee-growth formula without modifying state. Values reflect `creatorBps %` of the total pending fees for each pool token.

---

## SparkToken

Each launched token is an EIP-1167 clone of the `SparkToken` implementation contract.

- Standard ERC-20, 18 decimals, 1 B fixed supply — no mint, no burn, no tax
- EIP-2612 `permit` for gasless approvals and DEX aggregator support
- `metaURI()` — set once at `initSpark`, immutable thereafter
- No owner ever assigned — permanently ownerless once `initSpark` returns
- Implementation constructor sets `_initialized = true` to block direct use

---

## Constructor Arguments

### SparkLocker

```solidity
constructor(
    address platformWallet_,  // Receives 25 % of claimed swap fees (default)
    address charityWallet_    // Receives  5 % of claimed swap fees (default); passive only
)
```

### SparkLauncher

```solidity
constructor(
    address weth_,               // WETH contract
    address tokenImpl_,          // SparkToken implementation (deployed separately)
    address locker_,             // SparkLocker (set its launcher to this address after deploy)
    address initialFactory_,     // Factory of the first supported V3 DEX
    address initialPositionMgr_, // Position manager of the first supported V3 DEX
    address initialRouter_       // Swap router of the first supported V3 DEX
)
```

---

## Deployment Order

1. Deploy `SparkToken` implementation (no constructor args)
2. Deploy `SparkLocker(platformWallet, charityWallet)`
3. Deploy `SparkLauncher(weth, tokenImpl, locker, factory, positionMgr, router)`
4. Call `SparkLocker.setLauncher(sparkLauncher)`
5. Call `SparkLauncher.addDex(...)` for each additional DEX

---

## Function Reference

### SparkLauncher (owner)

| Function | Description |
|----------|-------------|
| `addDex(factory, positionMgr, router)` | Register or update a V3-compatible DEX |
| `disableDex(factory)` | Prevent new launches on this factory |
| `addQuoteToken(token, fee, decimals)` | Register or update an accepted quote token |
| `disableQuoteToken(token)` | Prevent new launches using this quote token |
| `transferOwnership(newOwner)` | Transfer launcher admin |

### SparkLauncher (public)

| Function | Description |
|----------|-------------|
| `launch(name, symbol, metaURI, feeWallet, factory, quoteToken, extraBuy) payable` | Deploy token, seed pool, lock LP — returns `(token, pool, tokenId)` |

### SparkLocker (owner)

| Function | Description |
|----------|-------------|
| `setLauncher(launcher)` | Set the address authorised to call `registerPosition` |
| `setPlatformWallet(wallet)` | Update platform fee recipient |
| `setCharityWallet(wallet)` | Update charity fee recipient |
| `setFeeBps(creator, platform, charity)` | Update fee split; must sum to 10 000 |
| `claimAllFees()` | Sweep all positions; skips failures |
| `claimFeesRange(from, to)` | Paginated sweep of `allTokens[from..to)` |
| `transferOwnership(newOwner)` | Transfer locker admin |

### SparkLocker (fee wallet or owner)

| Function | Description |
|----------|-------------|
| `claimFees(token)` | Collect and distribute fees for one token |

### SparkLocker (view)

| Function | Returns | Description |
|----------|---------|-------------|
| `pendingCreatorFees(token)` | `(token0, token1, amount0, amount1)` | Creator's share of uncollected fees |
| `tokenCount()` | `uint256` | Number of registered positions |
| `positions(token)` | `Position` | Full position record for a launched token |
| `allTokens(i)` | `address` | Launched token at index `i` |

### SparkToken (public)

Standard ERC-20 (`transfer`, `transferFrom`, `approve`, `allowance`, `balanceOf`, `totalSupply`, `name`, `symbol`, `decimals`) plus:

| Function | Description |
|----------|-------------|
| `metaURI()` | Returns the token's metadata URI (immutable after init) |
| `permit(owner, spender, value, deadline, v, r, s)` | EIP-2612 gasless approval |
| `DOMAIN_SEPARATOR()` | EIP-712 domain separator (chain-fork safe) |

---

## Key Constants (SparkLauncher)

| Constant | Value |
|----------|-------|
| `TOTAL_SUPPLY` | 1 000 000 000 × 10¹⁸ |
| `POOL_TOKENS` | 999 900 000 × 10¹⁸ (99.99 %) |
| `FEE_TIER` | 10 000 (1 % V3 tier, tick spacing 200) |
| `TICK_LOWER` | −887 200 |
| `TICK_UPPER` | +887 200 |

---

## sqrtPriceX96 Derivation

Pool initialisation price is computed on-chain without overflowing `uint256`:

```
scaled           = (amount1 << 96) / amount0    →  price × 2^96
sqrt(scaled)     = sqrt(price) × 2^48
sqrt(scaled) << 48 = sqrt(price) × 2^96         ✓  (= sqrtPriceX96)
```

Max intermediate: `POOL_TOKENS × 2^96 ≈ 7.92 × 10⁵⁵ ≪ 2^256`. Safe for all valid quote token amounts (minimum fee is 1 raw unit, enforced by `ZeroAmount`).

---

## Pending Fee Formula

`pendingCreatorFees` uses the standard Uniswap V3 fee-growth derivation:

```
feeGrowthBelow  = tick.feeGrowthOutside  (if currentTick ≥ tickLower)
                  global − tick.feeGrowthOutside  (otherwise)

feeGrowthAbove  = tick.feeGrowthOutside  (if currentTick < tickUpper)
                  global − tick.feeGrowthOutside  (otherwise)

feeGrowthInside = feeGrowthGlobal − feeGrowthBelow − feeGrowthAbove

pending         = liquidity × (feeGrowthInside − feeGrowthInsideLast) / 2¹²⁸
                  + tokensOwed
```

All arithmetic is `unchecked` (wrapping) per the Uniswap V3 spec.
