import { useState, useEffect, useCallback } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

interface AggregatorState {
  owner: string
  pendingOwner: string
  feeRecipient: string
  isOwner: boolean
  isPending: boolean
}

interface AdapterEntry {
  index: number
  id: string       // bytes32 hex
  addr: string
  enabled: boolean
  adapterName: string
}

function shortAddr(addr: string) {
  return addr ? `${addr.slice(0, 6)}…${addr.slice(-4)}` : '—'
}

export default function AggregatorTab() {
  const { aggregator, aggregatorAddress, account, toast } = useWeb3()

  const [state, setState] = useState<AggregatorState | null>(null)
  const [adapters, setAdapters] = useState<AdapterEntry[]>([])
  const [loading, setLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)

  // Register form
  const [regIdStr, setRegIdStr]       = useState('')
  const [regAddr, setRegAddr]         = useState('')
  const [regEnabled, setRegEnabled]   = useState(true)

  // Upgrade form
  const [upIdStr, setUpIdStr]         = useState('')
  const [upNewAddr, setUpNewAddr]     = useState('')

  // Fee recipient
  const [newFeeRecipient, setNewFeeRecipient] = useState('')

  // Rescue
  const [rescueToken, setRescueToken]         = useState('')
  const [rescueRecipient, setRescueRecipient] = useState('')
  const [rescueAmount, setRescueAmount]       = useState('')
  const [rescueNativeRecipient, setRescueNativeRecipient] = useState('')
  const [rescueNativeAmount, setRescueNativeAmount]       = useState('')

  // Ownership
  const [newOwnerAddr, setNewOwnerAddr] = useState('')

  const load = useCallback(async () => {
    if (!aggregator) return
    setLoading(true)
    try {
      const [owner, pending, feeRecip, count] = await Promise.all([
        aggregator.owner(),
        aggregator.pendingOwner(),
        aggregator.feeRecipient(),
        aggregator.adapterCount(),
      ])

      setState({
        owner,
        pendingOwner: pending,
        feeRecipient: feeRecip,
        isOwner:   account ? owner.toLowerCase() === account.toLowerCase() : false,
        isPending: !!(account && pending && pending !== ethers.ZeroAddress &&
                      account.toLowerCase() === pending.toLowerCase()),
      })

      const n = Number(count)
      const rows = await Promise.all(
        Array.from({ length: n }, (_, i) => aggregator.adapterAt(i))
      )
      setAdapters(rows.map((r: any, i: number) => ({
        index:       i,
        id:          r.id,
        addr:        r.addr,
        enabled:     r.enabled,
        adapterName: r.adapterName,
      })))
    } catch (e) {
      toast(`Load error: ${e}`, 'danger')
    } finally {
      setLoading(false)
    }
  }, [aggregator, account, toast])

  useEffect(() => { load() }, [load])

  const tx = async (fn: () => Promise<any>, label: string) => {
    setIsSubmitting(true)
    try {
      const t = await fn()
      toast(`${label}…`, 'warn')
      await t.wait()
      toast(`${label} done`, 'ok')
      await load()
    } catch (e: any) {
      toast(`Failed: ${e.reason || e.message}`, 'danger')
    } finally {
      setIsSubmitting(false)
    }
  }

  if (!aggregatorAddress) {
    return <div className="text-muted text-sm p-4">Set VITE_AGGREGATOR_ADDRESS in .env to enable this tab.</div>
  }
  if (!aggregator) {
    return <div className="text-muted text-sm p-4">Aggregator contract loading…</div>
  }
  if (loading && !state) {
    return <div className="text-muted text-sm p-4">Loading…</div>
  }
  if (!state) return null

  return (
    <div className="space-y-6">

      {/* Status */}
      <div className="bg-surface border border-border rounded p-4 grid grid-cols-2 gap-3 text-xs">
        <div>
          <span className="text-muted uppercase">Owner</span>
          <div className="font-mono mt-1 truncate">{state.owner}</div>
        </div>
        <div>
          <span className="text-muted uppercase">Role</span>
          <div className="mt-1">
            {state.isOwner ? (
              <Badge variant="ok">You are owner</Badge>
            ) : state.isPending ? (
              <Badge variant="warn">Pending ownership</Badge>
            ) : (
              <Badge variant="muted">Read-only</Badge>
            )}
          </div>
        </div>
        <div>
          <span className="text-muted uppercase">Fee Recipient</span>
          <div className="font-mono mt-1 truncate">{state.feeRecipient}</div>
        </div>
        <div>
          <span className="text-muted uppercase">Adapters</span>
          <div className="mt-1 font-semibold">{adapters.length}</div>
        </div>
        {state.pendingOwner && state.pendingOwner !== ethers.ZeroAddress && (
          <div className="col-span-2">
            <span className="text-muted uppercase">Pending Owner</span>
            <div className="font-mono mt-1 truncate">{state.pendingOwner}</div>
          </div>
        )}
      </div>

      {/* Adapter Registry */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Adapter Registry
        </div>

        {adapters.length === 0 ? (
          <div className="text-muted text-sm p-4 bg-surface border border-border rounded">
            No adapters registered.
          </div>
        ) : (
          <div className="space-y-2">
            {adapters.map(a => (
              <div
                key={a.id}
                className="bg-surface border border-border rounded p-3 flex flex-wrap items-center gap-3 text-xs"
              >
                <div className="flex-1 min-w-0 space-y-0.5">
                  <div className="font-semibold text-sm">{a.adapterName}</div>
                  <div className="font-mono text-muted truncate">{a.addr}</div>
                  <div className="font-mono text-muted opacity-60 truncate">ID: {a.id.slice(0, 18)}…</div>
                </div>
                <Badge variant={a.enabled ? 'ok' : 'muted'}>
                  {a.enabled ? 'Enabled' : 'Disabled'}
                </Badge>
                {state.isOwner && (
                  <div className="flex gap-1.5">
                    {a.enabled ? (
                      <Button
                        size="sm"
                        variant="danger"
                        disabled={isSubmitting}
                        onClick={() => tx(() => aggregator.disableAdapter(a.id), `Disable ${a.adapterName}`)}
                      >
                        Disable
                      </Button>
                    ) : (
                      <Button
                        size="sm"
                        variant="ok"
                        disabled={isSubmitting}
                        onClick={() => tx(() => aggregator.enableAdapter(a.id), `Enable ${a.adapterName}`)}
                      >
                        Enable
                      </Button>
                    )}
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Owner-only actions */}
      {state.isOwner && (
        <>
          {/* Register Adapter */}
          <div>
            <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              Register Adapter
            </div>
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <p className="text-xs text-muted">
                ID string is hashed with keccak256 — use the same string the offchain system will hash
                (e.g. <span className="font-mono">PANCAKE_V2</span>).
              </p>
              <Input
                label="ID String (e.g. PANCAKE_V2)"
                placeholder="PANCAKE_V2"
                value={regIdStr}
                onChange={e => setRegIdStr(e.target.value)}
              />
              <Input
                label="Adapter Contract Address"
                placeholder="0x…"
                value={regAddr}
                onChange={e => setRegAddr(e.target.value)}
              />
              <label className="flex items-center gap-2 text-xs cursor-pointer">
                <input
                  type="checkbox"
                  checked={regEnabled}
                  onChange={e => setRegEnabled(e.target.checked)}
                  className="w-3.5 h-3.5"
                />
                Enable immediately
              </label>
              <Button
                className="w-full"
                disabled={isSubmitting}
                onClick={() => {
                  if (!regIdStr.trim()) return toast('Enter an ID string', 'danger')
                  if (!ethers.isAddress(regAddr)) return toast('Invalid adapter address', 'danger')
                  const id = ethers.id(regIdStr.trim())
                  tx(() => aggregator.registerAdapter(id, regAddr, regEnabled), `Register ${regIdStr}`)
                  setRegIdStr(''); setRegAddr('')
                }}
              >
                Register Adapter
              </Button>
            </div>
          </div>

          {/* Upgrade Adapter */}
          <div>
            <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              Upgrade Adapter
            </div>
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <p className="text-xs text-muted">
                Replaces the implementation for an existing adapter ID without changing the registry key.
              </p>
              <Input
                label="ID String (must match registered ID)"
                placeholder="PANCAKE_V2"
                value={upIdStr}
                onChange={e => setUpIdStr(e.target.value)}
              />
              <Input
                label="New Adapter Address"
                placeholder="0x…"
                value={upNewAddr}
                onChange={e => setUpNewAddr(e.target.value)}
              />
              <Button
                className="w-full"
                disabled={isSubmitting}
                onClick={() => {
                  if (!upIdStr.trim()) return toast('Enter an ID string', 'danger')
                  if (!ethers.isAddress(upNewAddr)) return toast('Invalid address', 'danger')
                  const id = ethers.id(upIdStr.trim())
                  tx(() => aggregator.upgradeAdapter(id, upNewAddr), `Upgrade ${upIdStr}`)
                  setUpIdStr(''); setUpNewAddr('')
                }}
              >
                Upgrade Adapter
              </Button>
            </div>
          </div>

          {/* Config */}
          <div>
            <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              Config
            </div>
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Set Fee Recipient</div>
              <p className="text-xs text-muted">Current: {shortAddr(state.feeRecipient)}</p>
              <Input
                label="New Fee Recipient"
                placeholder="0x…"
                value={newFeeRecipient}
                onChange={e => setNewFeeRecipient(e.target.value)}
              />
              <Button
                className="w-full"
                disabled={isSubmitting}
                onClick={() => {
                  if (!ethers.isAddress(newFeeRecipient)) return toast('Invalid address', 'danger')
                  tx(() => aggregator.setFeeRecipient(newFeeRecipient), 'Set fee recipient')
                  setNewFeeRecipient('')
                }}
              >
                Set Fee Recipient
              </Button>
            </div>
          </div>

          {/* Rescue */}
          <div>
            <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              Rescue
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">

              <div className="bg-surface border border-border rounded p-4 space-y-3">
                <div className="font-semibold text-sm">Rescue ERC-20 Tokens</div>
                <Input
                  label="Token Address"
                  placeholder="0x…"
                  value={rescueToken}
                  onChange={e => setRescueToken(e.target.value)}
                />
                <Input
                  label="Recipient"
                  placeholder="0x…"
                  value={rescueRecipient}
                  onChange={e => setRescueRecipient(e.target.value)}
                />
                <Input
                  label="Amount (wei)"
                  placeholder="1000000000000000000"
                  value={rescueAmount}
                  onChange={e => setRescueAmount(e.target.value)}
                />
                <Button
                  className="w-full"
                  variant="danger"
                  disabled={isSubmitting}
                  onClick={() => {
                    if (!ethers.isAddress(rescueToken))     return toast('Invalid token address', 'danger')
                    if (!ethers.isAddress(rescueRecipient)) return toast('Invalid recipient', 'danger')
                    if (!rescueAmount)                      return toast('Enter amount in wei', 'danger')
                    tx(() => aggregator.rescueTokens(rescueToken, rescueRecipient, BigInt(rescueAmount)), 'Rescue tokens')
                    setRescueToken(''); setRescueRecipient(''); setRescueAmount('')
                  }}
                >
                  Rescue Tokens
                </Button>
              </div>

              <div className="bg-surface border border-border rounded p-4 space-y-3">
                <div className="font-semibold text-sm">Rescue Native BNB</div>
                <Input
                  label="Recipient"
                  placeholder="0x…"
                  value={rescueNativeRecipient}
                  onChange={e => setRescueNativeRecipient(e.target.value)}
                />
                <Input
                  label="Amount (BNB)"
                  type="number"
                  placeholder="0.1"
                  step="0.01"
                  min="0"
                  value={rescueNativeAmount}
                  onChange={e => setRescueNativeAmount(e.target.value)}
                />
                <Button
                  className="w-full"
                  variant="danger"
                  disabled={isSubmitting}
                  onClick={() => {
                    if (!ethers.isAddress(rescueNativeRecipient)) return toast('Invalid recipient', 'danger')
                    if (!rescueNativeAmount)                       return toast('Enter amount', 'danger')
                    tx(() => aggregator.rescueNative(rescueNativeRecipient, ethers.parseEther(rescueNativeAmount)), 'Rescue BNB')
                    setRescueNativeRecipient(''); setRescueNativeAmount('')
                  }}
                >
                  Rescue BNB
                </Button>
              </div>

            </div>
          </div>

          {/* Ownership */}
          <div>
            <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              Ownership Transfer
            </div>
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Transfer Ownership</div>
              <p className="text-xs text-muted">Current: {shortAddr(state.owner)}</p>
              <Input
                label="New Owner"
                placeholder="0x…"
                value={newOwnerAddr}
                onChange={e => setNewOwnerAddr(e.target.value)}
              />
              <Button
                className="w-full"
                disabled={isSubmitting}
                onClick={() => {
                  if (!ethers.isAddress(newOwnerAddr)) return toast('Invalid address', 'danger')
                  tx(() => aggregator.transferOwnership(newOwnerAddr), 'Transfer ownership')
                  setNewOwnerAddr('')
                }}
              >
                Transfer
              </Button>
            </div>
          </div>
        </>
      )}

      {/* Accept ownership (visible to pending owner regardless of isOwner) */}
      {state.isPending && (
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <div className="font-semibold text-sm">Accept Ownership</div>
          <p className="text-xs text-ok">You have pending ownership of the Aggregator!</p>
          <Button
            className="w-full"
            disabled={isSubmitting}
            onClick={() => tx(() => aggregator.acceptOwnership(), 'Accept ownership')}
          >
            Accept Ownership
          </Button>
        </div>
      )}

      {!state.isOwner && !state.isPending && (
        <div className="bg-surface border border-border rounded p-4 text-center">
          <Badge variant="muted">Admin write features restricted to owner</Badge>
        </div>
      )}

    </div>
  )
}
