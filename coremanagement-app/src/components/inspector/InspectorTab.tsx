import { useState } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'
import { ERC20_ABI, BC_ABI } from '../../lib/contracts'

interface TokenInfo {
  token: string
  creator: string
  name: string
  symbol: string
  decimals: number
  totalSupply: bigint
  raisedBNB: bigint
  migrationTarget: bigint
  migrated: boolean
  antibotEnabled: boolean
  userBalance: bigint
  spotPrice: bigint
}

export default function InspectorTab() {
  const { bondingCurve, signer, account, provider, toast } = useWeb3()
  const [inspectAddr, setInspectAddr] = useState('')
  const [tokenInfo, setTokenInfo] = useState<TokenInfo | null>(null)
  const [loading, setLoading] = useState(false)

  const [buyBNB, setBuyBNB] = useState(0.1)
  const [buySlippage, setBuySlippage] = useState(2)
  const [sellTokens, setSellTokens] = useState(0)
  const [sellSlippage, setSellSlippage] = useState(2)
  const [buyQuote, setBuyQuote] = useState('')
  const [sellQuote, setSellQuote] = useState('')

  const handleInspect = async () => {
    if (!bondingCurve) {
      toast('Load factory first', 'warn')
      return
    }
    if (!ethers.isAddress(inspectAddr.trim())) {
      toast('Invalid token address', 'danger')
      return
    }

    setLoading(true)
    setTokenInfo(null)
    try {
      const addr = inspectAddr.trim()
      const [td, spotRaw] = await Promise.all([
        bondingCurve.getToken(addr),
        bondingCurve.getSpotPrice(addr).catch(() => 0n),
      ])

      const erc20 = new ethers.Contract(addr, ERC20_ABI, provider)
      const [sym, name, dec] = await Promise.all([
        erc20.symbol().catch(() => '?'),
        erc20.name().catch(() => '?'),
        erc20.decimals().catch(() => 18n),
      ])

      let userBalance = 0n
      if (account) {
        userBalance = await erc20.balanceOf(account).catch(() => 0n)
      }

      setTokenInfo({
        token: td.token,
        creator: td.creator,
        name,
        symbol: sym,
        decimals: Number(dec),
        totalSupply: td.totalSupply,
        raisedBNB: td.raisedBNB,
        migrationTarget: td.migrationTarget,
        migrated: td.migrated,
        antibotEnabled: td.antibotEnabled,
        userBalance,
        spotPrice: spotRaw,
      })
    } catch (e: any) {
      toast(`Error: ${e.message || e}`, 'danger')
    } finally {
      setLoading(false)
    }
  }

  const formatBNB = (wei: bigint) => {
    return parseFloat(ethers.formatEther(wei)).toFixed(6)
  }

  const formatTokens = (wei: bigint, decimals: number) => {
    return parseFloat(ethers.formatUnits(wei, decimals)).toFixed(4)
  }

  const shortAddress = (addr: string) => {
    return `${addr.slice(0, 6)}...${addr.slice(-4)}`
  }

  const handleGetBuyQuote = async () => {
    if (!bondingCurve) return
    if (buyBNB <= 0) {
      toast('Enter BNB amount', 'warn')
      return
    }

    try {
      const [tokensOut, feeBNB] = await bondingCurve.getAmountOut(
        inspectAddr,
        ethers.parseEther(buyBNB.toString())
      )
      const minOut = (tokensOut * BigInt(Math.floor((100 - buySlippage) * 100))) / 10000n
      setBuyQuote(
        `Get ~${formatTokens(tokensOut, tokenInfo?.decimals || 18)} tokens. Fee: ${formatBNB(feeBNB)} BNB. Min: ${formatTokens(minOut, tokenInfo?.decimals || 18)}`
      )
    } catch (e) {
      setBuyQuote('Quote error')
    }
  }

  const handleGetSellQuote = async () => {
    if (!bondingCurve || !tokenInfo) return
    if (sellTokens <= 0) {
      toast('Enter token amount', 'warn')
      return
    }

    try {
      const [bnbOut, feeBNB] = await bondingCurve.getAmountOutSell(
        inspectAddr,
        ethers.parseUnits(sellTokens.toString(), tokenInfo.decimals)
      )
      const minOut = (bnbOut * BigInt(Math.floor((100 - sellSlippage) * 100))) / 10000n
      setSellQuote(
        `Get ~${formatBNB(bnbOut)} BNB. Fee: ${formatBNB(feeBNB)} BNB. Min: ${formatBNB(minOut)} BNB`
      )
    } catch (e) {
      setSellQuote('Quote error')
    }
  }

  const handleDoBuy = async () => {
    if (!signer) {
      toast('Connect wallet', 'warn')
      return
    }
    if (buyBNB <= 0) {
      toast('Enter BNB amount', 'warn')
      return
    }

    try {
      const bnbWei = ethers.parseEther(buyBNB.toString())
      const [tokensOut] = await bondingCurve!.getAmountOut(inspectAddr, bnbWei)
      const minOut = (tokensOut * BigInt(Math.floor((100 - buySlippage) * 100))) / 10000n

      const bc = new ethers.Contract(bondingCurve!.target, BC_ABI, signer)
      const tx = await bc.buy(inspectAddr, minOut, BigInt(Math.floor(Date.now() / 1000) + 300), {
        value: bnbWei,
      })

      toast('Buying... waiting for tx', 'warn')
      await tx.wait()
      toast('Buy successful!', 'ok')
      handleInspect()
    } catch (e: any) {
      toast(`Buy failed: ${e.reason || e.message || e}`, 'danger')
    }
  }

  const handleDoSell = async () => {
    if (!signer) {
      toast('Connect wallet', 'warn')
      return
    }
    if (sellTokens <= 0) {
      toast('Enter token amount', 'warn')
      return
    }

    try {
      const tokWei = ethers.parseUnits(sellTokens.toString(), tokenInfo!.decimals)
      const [bnbOut] = await bondingCurve!.getAmountOutSell(inspectAddr, tokWei)
      const minOut = (bnbOut * BigInt(Math.floor((100 - sellSlippage) * 100))) / 10000n

      const bc = new ethers.Contract(bondingCurve!.target, BC_ABI, signer)
      const tx = await bc.sell(inspectAddr, tokWei, minOut, BigInt(Math.floor(Date.now() / 1000) + 300))

      toast('Selling... waiting for tx', 'warn')
      await tx.wait()
      toast('Sell successful!', 'ok')
      handleInspect()
    } catch (e: any) {
      toast(`Sell failed: ${e.reason || e.message || e}`, 'danger')
    }
  }

  const handleDoMigrate = async () => {
    if (!signer) {
      toast('Connect wallet', 'warn')
      return
    }

    try {
      const bc = new ethers.Contract(bondingCurve!.target, BC_ABI, signer)
      const tx = await bc.migrate(inspectAddr)

      toast('Migration tx sent...', 'warn')
      await tx.wait()
      toast('Migrated!', 'ok')
      handleInspect()
    } catch (e: any) {
      toast(`Migrate failed: ${e.reason || e.message || e}`, 'danger')
    }
  }

  if (!tokenInfo) {
    return (
      <div className="space-y-4">
        <div className="flex gap-3 items-end">
          <div className="flex-1">
            <Input
              label="Token Address"
              placeholder="0x…"
              value={inspectAddr}
              onChange={e => setInspectAddr(e.target.value)}
            />
          </div>
          <Button onClick={handleInspect} disabled={loading}>
            {loading ? 'Inspecting...' : 'Inspect'}
          </Button>
        </div>
        <div className="text-center py-20" style={{ color: 'var(--muted)' }}>
          {loading ? 'Loading token...' : 'Enter a token address above.'}
        </div>
      </div>
    )
  }

  const pct = tokenInfo.migrationTarget > 0n
    ? Math.min(100, Number((tokenInfo.raisedBNB * 10000n) / tokenInfo.migrationTarget) / 100).toFixed(2)
    : '0'

  return (
    <div className="space-y-6">
      <div className="flex gap-3 items-end">
        <div className="flex-1">
          <Input
            label="Token Address"
            placeholder="0x…"
            value={inspectAddr}
            onChange={e => setInspectAddr(e.target.value)}
          />
        </div>
        <Button onClick={handleInspect} disabled={loading}>
          {loading ? 'Inspecting...' : 'Inspect'}
        </Button>
      </div>

      {/* Header */}
      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <div className="text-lg font-bold">
            {tokenInfo.symbol} — {tokenInfo.name}
          </div>
          <div className="flex gap-2">
            {tokenInfo.migrated ? <Badge variant="ok">Migrated</Badge> : <Badge variant="accent">Active</Badge>}
            {tokenInfo.antibotEnabled && <Badge variant="warn">Antibot</Badge>}
          </div>
        </div>
        <div className="text-xs font-mono text-muted">{tokenInfo.token}</div>
      </div>

      {/* Progress Bar */}
      <div className="space-y-2">
        <div className="h-2 bg-border rounded overflow-hidden">
          <div className="h-full bg-accent" style={{ width: `${pct}%` }} />
        </div>
        <p className="text-xs text-muted">
          Raised {formatBNB(tokenInfo.raisedBNB)} BNB of {formatBNB(tokenInfo.migrationTarget)} BNB target ({pct}%)
        </p>
        <p className="text-xs text-muted">
          Spot price: <span className="text-text font-semibold">{formatBNB(tokenInfo.spotPrice)} BNB/token</span>
        </p>
      </div>

      {/* Token Config */}
      <div className="bg-surface border border-border rounded p-4">
        <div className="text-xs font-semibold text-muted uppercase mb-3">Token Config</div>
        <div className="space-y-2 text-xs">
          <div className="flex justify-between"><span className="text-muted">Creator:</span> <span className="font-mono">{shortAddress(tokenInfo.creator)}</span></div>
          <div className="flex justify-between"><span className="text-muted">Total Supply:</span> <span>{formatTokens(tokenInfo.totalSupply, tokenInfo.decimals)}</span></div>
          <div className="flex justify-between"><span className="text-muted">Your Balance:</span> <span>{formatTokens(tokenInfo.userBalance, tokenInfo.decimals)} {tokenInfo.symbol}</span></div>
        </div>
      </div>

      {/* Actions */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {/* Buy */}
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <div className="font-semibold text-sm">Buy</div>
          <div className="space-y-2">
            <Input
              label="BNB Amount"
              type="number"
              placeholder="0.1"
              min="0"
              step="0.001"
              value={buyBNB}
              onChange={e => setBuyBNB(parseFloat(e.target.value) || 0)}
            />
            <Input
              label="Slippage %"
              type="number"
              value={buySlippage}
              min="0.1"
              max="50"
              step="0.1"
              onChange={e => setBuySlippage(parseFloat(e.target.value) || 2)}
            />
          </div>
          <button
            onClick={handleGetBuyQuote}
            className="w-full bg-surface border border-border text-text rounded px-3 py-1 text-xs font-semibold hover:border-accent transition"
          >
            Get Quote
          </button>
          {buyQuote && <p className="text-xs text-muted">{buyQuote}</p>}
          <Button onClick={handleDoBuy} className="w-full">
            Buy
          </Button>
        </div>

        {/* Sell */}
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <div className="font-semibold text-sm">Sell</div>
          <div className="space-y-2">
            <Input
              label="Token Amount"
              type="number"
              placeholder="1000"
              min="0"
              value={sellTokens}
              onChange={e => setSellTokens(parseFloat(e.target.value) || 0)}
            />
            <Input
              label="Slippage %"
              type="number"
              value={sellSlippage}
              min="0.1"
              max="50"
              step="0.1"
              onChange={e => setSellSlippage(parseFloat(e.target.value) || 2)}
            />
          </div>
          <button
            onClick={handleGetSellQuote}
            className="w-full bg-surface border border-border text-text rounded px-3 py-1 text-xs font-semibold hover:border-accent transition"
          >
            Get Quote
          </button>
          {sellQuote && <p className="text-xs text-muted">{sellQuote}</p>}
          <div className="flex gap-2">
            <button
              className="flex-1 bg-surface border border-border text-text rounded px-3 py-1 text-xs font-semibold hover:border-accent transition"
              onClick={async () => {
                if (!signer || !bondingCurve) return toast('Connect wallet', 'warn')
                try {
                  const bcAddr = await bondingCurve.getAddress()
                  const token = new ethers.Contract(
                    inspectAddr,
                    ['function approve(address,uint256) returns (bool)'],
                    signer
                  )
                  const tx = await token.approve(bcAddr, ethers.MaxUint256)
                  toast('Approving…', 'warn')
                  await tx.wait()
                  toast('Approved — you can now sell', 'ok')
                } catch (e: any) {
                  toast(`Approve failed: ${e.reason || e.message}`, 'danger')
                }
              }}
            >
              Approve BC
            </button>
            <Button size="sm" onClick={handleDoSell} className="flex-1">
              Sell
            </Button>
          </div>
        </div>

        {/* Migrate */}
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <div className="font-semibold text-sm">Migrate</div>
          {tokenInfo.migrated ? (
            <Badge variant="ok">Already migrated</Badge>
          ) : tokenInfo.raisedBNB >= tokenInfo.migrationTarget ? (
            <>
              <p className="text-xs" style={{ color: 'var(--ok)' }}>Migration target met! Anyone can trigger.</p>
              <Button onClick={handleDoMigrate} className="w-full">
                Trigger Migration
              </Button>
            </>
          ) : (
            <p className="text-xs" style={{ color: 'var(--muted)' }}>Target not reached ({pct}%)</p>
          )}
        </div>
      </div>
    </div>
  )
}
