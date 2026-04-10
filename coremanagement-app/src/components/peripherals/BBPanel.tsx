import { useState, useEffect, useCallback } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

interface BBState {
  owner: string
  pendingOwner: string
  router: string
  buyToken: string
  cooldown: number
  lastBuyAt: number
  cooldownRemaining: number
  isOwner: boolean
}

function formatDuration(seconds: number): string {
  if (seconds <= 0) return 'Ready'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}

export default function BBPanel() {
  const { oneMEMEBB, account, toast } = useWeb3()
  const [state, setState] = useState<BBState | null>(null)
  const [loading, setLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)

  const [newRouter, setNewRouter] = useState('')
  const [newBuyToken, setNewBuyToken] = useState('')
  const [newCooldown, setNewCooldown] = useState('')
  const [rescueToken, setRescueToken] = useState('')
  const [rescueAmount, setRescueAmount] = useState('')
  const [withdrawAmt, setWithdrawAmt] = useState('')
  const [newOwner, setNewOwner] = useState('')

  const load = useCallback(async () => {
    if (!oneMEMEBB) return
    setLoading(true)
    try {
      const [owner, pending, router, buyToken, cooldown, lastBuyAt, remaining] = await Promise.all([
        oneMEMEBB.owner(),
        oneMEMEBB.pendingOwner(),
        oneMEMEBB.router(),
        oneMEMEBB.buyToken(),
        oneMEMEBB.cooldown(),
        oneMEMEBB.lastBuyAt(),
        oneMEMEBB.cooldownRemaining(),
      ])
      setState({
        owner, pendingOwner: pending, router, buyToken,
        cooldown: Number(cooldown),
        lastBuyAt: Number(lastBuyAt),
        cooldownRemaining: Number(remaining),
        isOwner: account ? owner.toLowerCase() === account.toLowerCase() : false,
      })
    } catch (e) { toast(`BBPanel load error: ${e}`, 'danger') }
    finally { setLoading(false) }
  }, [oneMEMEBB, account, toast])

  useEffect(() => { load() }, [load])

  const tx = async (fn: () => Promise<any>, label: string) => {
    setIsSubmitting(true)
    try {
      const t = await fn()
      toast(`${label}…`, 'warn')
      await t.wait()
      toast(`${label} done`, 'ok')
      await load()
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  if (!oneMEMEBB) return <div className="text-muted text-sm p-4">1MEMEBB address not configured.</div>
  if (loading && !state) return <div className="text-muted text-sm p-4">Loading…</div>
  if (!state) return null

  return (
    <div className="space-y-4">
      {/* Status */}
      <div className="bg-surface border border-border rounded p-4 grid grid-cols-2 gap-3 text-xs">
        <div><span className="text-muted">Owner</span><div className="font-mono mt-1 truncate">{state.owner}</div></div>
        <div>
          <span className="text-muted">Role</span>
          <div className="mt-1">
            {state.isOwner ? <Badge variant="ok">Owner</Badge> : <Badge variant="muted">Read-only</Badge>}
          </div>
        </div>
        <div><span className="text-muted">Router</span><div className="font-mono mt-1 truncate">{state.router}</div></div>
        <div><span className="text-muted">Buy Token</span><div className="font-mono mt-1 truncate">{state.buyToken || '—'}</div></div>
        <div>
          <span className="text-muted">Cooldown</span>
          <div className="mt-1">{formatDuration(state.cooldown)} configured</div>
        </div>
        <div>
          <span className="text-muted">Next Buyback</span>
          <div className="mt-1">
            {state.cooldownRemaining > 0
              ? <Badge variant="warn">{formatDuration(state.cooldownRemaining)} remaining</Badge>
              : <Badge variant="ok">Ready</Badge>}
          </div>
        </div>
      </div>

      {/* Trigger Buyback */}
      <div className="bg-surface border border-border rounded p-4 space-y-3">
        <div className="font-semibold text-sm">Trigger Buyback</div>
        <p className="text-xs text-muted">
          Buys 1MEME with contract BNB balance. Spend tiers: &lt;0.1 BNB → 100%, 0.1–2 BNB → 0.1 BNB, &gt;2 BNB → 0.25 BNB.
        </p>
        <Button
          onClick={() => tx(() => oneMEMEBB.BBnow(), 'Buyback')}
          disabled={isSubmitting || state.cooldownRemaining > 0}
          variant="ok"
          className="w-full"
        >
          {state.cooldownRemaining > 0 ? `Cooldown: ${formatDuration(state.cooldownRemaining)}` : 'BB Now'}
        </Button>
      </div>

      {state.isOwner && (
        <>
          {/* Router */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Set Router</div>
            <Input label="New Router Address" placeholder="0x…" value={newRouter} onChange={e => setNewRouter(e.target.value)} />
            <Button onClick={() => {
              if (!ethers.isAddress(newRouter)) return toast('Invalid address', 'danger')
              tx(() => oneMEMEBB.setRouter(newRouter), 'Set router')
            }} disabled={isSubmitting} className="w-full">Set Router</Button>
          </div>

          {/* Buy Token */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Set Buy Token</div>
            <p className="text-xs text-muted">One-time only — cannot be changed once set.</p>
            <Input label="Token Address" placeholder="0x…" value={newBuyToken} onChange={e => setNewBuyToken(e.target.value)} />
            <Button onClick={() => {
              if (!ethers.isAddress(newBuyToken)) return toast('Invalid address', 'danger')
              tx(() => oneMEMEBB.setBuyToken(newBuyToken), 'Set buy token')
            }} disabled={isSubmitting || !!state.buyToken} className="w-full">
              {state.buyToken ? 'Already set' : 'Set Buy Token'}
            </Button>
          </div>

          {/* Cooldown */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Set Cooldown</div>
            <p className="text-xs text-muted">Range: 30 minutes – 7 days (in seconds).</p>
            <Input label="Seconds" type="number" placeholder="129600" min="1800" max="604800"
              value={newCooldown} onChange={e => setNewCooldown(e.target.value)} />
            <Button onClick={() => {
              if (!newCooldown) return toast('Enter seconds', 'danger')
              tx(() => oneMEMEBB.setCooldown(Number(newCooldown)), 'Set cooldown')
            }} disabled={isSubmitting} className="w-full">Set Cooldown</Button>
          </div>

          {/* Rescue Token */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Rescue Token</div>
            <Input label="Token Address" placeholder="0x…" value={rescueToken} onChange={e => setRescueToken(e.target.value)} />
            <Input label="Amount (wei)" placeholder="1000000000000000000" value={rescueAmount} onChange={e => setRescueAmount(e.target.value)} />
            <Button onClick={() => {
              if (!ethers.isAddress(rescueToken) || !rescueAmount) return toast('Fill all fields', 'danger')
              tx(() => oneMEMEBB.rescueToken(rescueToken, BigInt(rescueAmount)), 'Rescue token')
            }} disabled={isSubmitting} variant="danger" className="w-full">Rescue Token</Button>
          </div>

          {/* Withdraw BNB */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Withdraw BNB</div>
            <Input label="Amount (BNB)" type="number" placeholder="0.1" step="0.01" min="0"
              value={withdrawAmt} onChange={e => setWithdrawAmt(e.target.value)} />
            <Button onClick={() => {
              if (!withdrawAmt) return toast('Enter amount', 'danger')
              tx(() => oneMEMEBB.withdrawBNB(ethers.parseEther(withdrawAmt)), 'Withdraw BNB')
            }} disabled={isSubmitting} variant="danger" className="w-full">Withdraw BNB</Button>
          </div>

          {/* Ownership */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Transfer Ownership</div>
            <Input label="New Owner" placeholder="0x…" value={newOwner} onChange={e => setNewOwner(e.target.value)} />
            <Button onClick={() => {
              if (!ethers.isAddress(newOwner)) return toast('Invalid address', 'danger')
              tx(() => oneMEMEBB.transferOwnership(newOwner), 'Transfer ownership')
            }} disabled={isSubmitting} className="w-full">Transfer</Button>
          </div>
        </>
      )}

      {state.pendingOwner && state.pendingOwner !== ethers.ZeroAddress &&
        account?.toLowerCase() === state.pendingOwner.toLowerCase() && (
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <div className="font-semibold text-sm">Accept Ownership</div>
          <p className="text-xs text-ok">You have pending ownership of 1MEMEBB!</p>
          <Button onClick={() => tx(() => oneMEMEBB.acceptOwnership(), 'Accept ownership')} disabled={isSubmitting} className="w-full">
            Accept Ownership
          </Button>
        </div>
      )}
    </div>
  )
}
