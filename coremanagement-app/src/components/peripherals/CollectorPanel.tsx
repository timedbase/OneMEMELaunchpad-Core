import { useState, useEffect, useCallback } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

interface CollectorState {
  owner: string
  pendingOwner: string
  CR8: string
  KJC: string
  MTN: string
  TW: string
  HK: string
  BB: string
  disperseRemaining: number
  recipientRemaining: number
  isOwner: boolean
}

const SHARES: Record<string, string> = {
  CR8: '40%', KJC: '22%', MTN: '14%', TW: '8%', HK: '8%', BB: '~8%',
}

function formatCountdown(s: number): string {
  if (s <= 0) return 'Ready'
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}

export default function CollectorPanel() {
  const { collector, account, toast } = useWeb3()
  const [state, setState] = useState<CollectorState | null>(null)
  const [loading, setLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)

  // setRecipients form — order matches contract: CR8, KJC, MTN, TW, HK, BB
  const [rCR8, setRCR8] = useState('')
  const [rKJC, setRKJC] = useState('')
  const [rMTN, setRMTN] = useState('')
  const [rTW, setRTW] = useState('')
  const [rHK, setRHK] = useState('')
  const [rBB, setRBB] = useState('')

  const [rescueToken, setRescueToken] = useState('')
  const [rescueAmount, setRescueAmount] = useState('')
  const [newOwner, setNewOwner] = useState('')

  const load = useCallback(async () => {
    if (!collector) return
    setLoading(true)
    try {
      const [owner, pending, CR8, KJC, MTN, TW, HK, BB, dr, rr] = await Promise.all([
        collector.owner(),
        collector.pendingOwner(),
        collector.CR8(),
        collector.KJC(),
        collector.MTN(),
        collector.TW(),
        collector.HK(),
        collector.BB(),
        collector.disperseCooldownRemaining(),
        collector.recipientCooldownRemaining(),
      ])
      setState({
        owner, pendingOwner: pending,
        CR8, KJC, MTN, TW, HK, BB,
        disperseRemaining: Number(dr),
        recipientRemaining: Number(rr),
        isOwner: account ? owner.toLowerCase() === account.toLowerCase() : false,
      })
    } catch (e) { toast(`Collector load error: ${e}`, 'danger') }
    finally { setLoading(false) }
  }, [collector, account, toast])

  useEffect(() => { load() }, [load])

  const exec = async (fn: () => Promise<any>, label: string) => {
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

  if (!collector) return <div className="text-muted text-sm p-4">Collector address not configured.</div>
  if (loading && !state) return <div className="text-muted text-sm p-4">Loading…</div>
  if (!state) return null

  const recipients = [
    { key: 'CR8', addr: state.CR8 },
    { key: 'KJC', addr: state.KJC },
    { key: 'MTN', addr: state.MTN },
    { key: 'TW',  addr: state.TW  },
    { key: 'HK',  addr: state.HK  },
    { key: 'BB',  addr: state.BB  },
  ]

  return (
    <div className="space-y-4">
      {/* Status */}
      <div className="bg-surface border border-border rounded p-4 space-y-3">
        <div className="flex items-center justify-between">
          <div className="font-semibold text-sm">Revenue Collector</div>
          {state.isOwner ? <Badge variant="ok">Owner</Badge> : <Badge variant="muted">Read-only</Badge>}
        </div>
        <div className="grid grid-cols-2 gap-2 text-xs">
          <div>
            <span className="text-muted">Disperse cooldown</span>
            <div className="mt-1">
              {state.disperseRemaining > 0
                ? <Badge variant="warn">{formatCountdown(state.disperseRemaining)}</Badge>
                : <Badge variant="ok">Ready</Badge>}
            </div>
          </div>
          <div>
            <span className="text-muted">Recipient update cooldown</span>
            <div className="mt-1">
              {state.recipientRemaining > 0
                ? <Badge variant="warn">{formatCountdown(state.recipientRemaining)}</Badge>
                : <Badge variant="ok">Ready</Badge>}
            </div>
          </div>
        </div>
      </div>

      {/* Recipients */}
      <div className="bg-surface border border-border rounded p-4 space-y-2">
        <div className="font-semibold text-sm mb-2">Recipients</div>
        {recipients.map(({ key, addr }) => (
          <div key={key} className="flex items-center justify-between text-xs">
            <span className="text-muted w-10">{key}</span>
            <span className="text-muted w-12">{SHARES[key]}</span>
            <span className="font-mono truncate flex-1 ml-2">{addr}</span>
          </div>
        ))}
      </div>

      {/* Disperse */}
      <div className="bg-surface border border-border rounded p-4 space-y-3">
        <div className="font-semibold text-sm">Disperse Revenue</div>
        <p className="text-xs text-muted">Splits contract BNB to all 6 recipients. Min 0.005 BNB required.</p>
        <Button
          onClick={() => exec(() => collector.Disperse(), 'Disperse')}
          disabled={isSubmitting || state.disperseRemaining > 0}
          variant="ok"
          className="w-full"
        >
          {state.disperseRemaining > 0 ? `Cooldown: ${formatCountdown(state.disperseRemaining)}` : 'Disperse'}
        </Button>
      </div>

      {state.isOwner && (
        <>
          {/* Set Recipients */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Update Recipients</div>
            <p className="text-xs text-muted">48-hour cooldown between recipient updates.</p>
            {[
              ['CR8 (40%)', rCR8, setRCR8],
              ['KJC (22%)', rKJC, setRKJC],
              ['MTN (14%)', rMTN, setRMTN],
              ['TW (8%)',   rTW,  setRTW ],
              ['HK (8%)',   rHK,  setRHK ],
              ['BB (~8%)',  rBB,  setRBB ],
            ].map(([label, val, set]) => (
              <Input key={label as string} label={label as string} placeholder="0x…"
                value={val as string} onChange={e => (set as (v: string) => void)(e.target.value)} />
            ))}
            <Button
              onClick={() => {
                const addrs = [rCR8, rKJC, rMTN, rTW, rHK, rBB]
                if (addrs.some(a => !ethers.isAddress(a))) return toast('All 6 must be valid addresses', 'danger')
                exec(() => collector.setRecipients(rCR8, rKJC, rMTN, rTW, rHK, rBB), 'Update recipients')
              }}
              disabled={isSubmitting || state.recipientRemaining > 0}
              className="w-full"
            >
              {state.recipientRemaining > 0 ? `Cooldown: ${formatCountdown(state.recipientRemaining)}` : 'Update Recipients'}
            </Button>
          </div>

          {/* Rescue Token */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Rescue Token</div>
            <Input label="Token Address" placeholder="0x…" value={rescueToken} onChange={e => setRescueToken(e.target.value)} />
            <Input label="Amount (wei)" placeholder="1000000000000000000" value={rescueAmount} onChange={e => setRescueAmount(e.target.value)} />
            <Button onClick={() => {
              if (!ethers.isAddress(rescueToken) || !rescueAmount) return toast('Fill all fields', 'danger')
              exec(() => collector.rescueToken(rescueToken, BigInt(rescueAmount)), 'Rescue token')
            }} disabled={isSubmitting} variant="danger" className="w-full">Rescue Token</Button>
          </div>

          {/* Ownership */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Transfer Ownership</div>
            <Input label="New Owner" placeholder="0x…" value={newOwner} onChange={e => setNewOwner(e.target.value)} />
            <Button onClick={() => {
              if (!ethers.isAddress(newOwner)) return toast('Invalid address', 'danger')
              exec(() => collector.transferOwnership(newOwner), 'Transfer ownership')
            }} disabled={isSubmitting} className="w-full">Transfer</Button>
          </div>
        </>
      )}

      {state.pendingOwner && state.pendingOwner !== ethers.ZeroAddress &&
        account?.toLowerCase() === state.pendingOwner.toLowerCase() && (
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <p className="text-xs text-ok">You have pending ownership of Collector!</p>
          <Button onClick={() => exec(() => collector.acceptOwnership(), 'Accept ownership')} disabled={isSubmitting} className="w-full">
            Accept Ownership
          </Button>
        </div>
      )}
    </div>
  )
}
