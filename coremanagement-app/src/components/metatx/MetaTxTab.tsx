import { useState, useEffect, useCallback } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

interface MetaTxState {
  owner: string
  pendingOwner: string
  aggregatorAddr: string
  permit2Addr: string
  isOwner: boolean
  isPending: boolean
}

function shortAddr(addr: string) {
  return addr ? `${addr.slice(0, 6)}…${addr.slice(-4)}` : '—'
}

export default function MetaTxTab() {
  const { metaTx, metaTxAddress, account, toast } = useWeb3()

  const [state, setState] = useState<MetaTxState | null>(null)
  const [loading, setLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)

  // Nonce lookup
  const [nonceAddr, setNonceAddr]   = useState('')
  const [nonceLookup, setNonceLookup] = useState<string | null>(null)

  // Rescue ERC-20
  const [rescueToken, setRescueToken]         = useState('')
  const [rescueRecipient, setRescueRecipient] = useState('')
  const [rescueAmount, setRescueAmount]       = useState('')

  // Rescue native
  const [rescueNativeRecipient, setRescueNativeRecipient] = useState('')
  const [rescueNativeAmount, setRescueNativeAmount]       = useState('')

  // Ownership
  const [newOwnerAddr, setNewOwnerAddr] = useState('')

  const load = useCallback(async () => {
    if (!metaTx) return
    setLoading(true)
    try {
      const [owner, pending, aggAddr, p2Addr] = await Promise.all([
        metaTx.owner(),
        metaTx.pendingOwner(),
        metaTx.aggregator(),
        metaTx.permit2(),
      ])
      setState({
        owner,
        pendingOwner: pending,
        aggregatorAddr: aggAddr,
        permit2Addr: p2Addr,
        isOwner:   account ? owner.toLowerCase() === account.toLowerCase() : false,
        isPending: !!(account && pending && pending !== ethers.ZeroAddress &&
                      account.toLowerCase() === pending.toLowerCase()),
      })
    } catch (e) {
      toast(`Load error: ${e}`, 'danger')
    } finally {
      setLoading(false)
    }
  }, [metaTx, account, toast])

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

  const lookupNonce = async () => {
    if (!metaTx) return
    if (!ethers.isAddress(nonceAddr)) return toast('Invalid address', 'danger')
    try {
      const n = await metaTx.nonces(nonceAddr)
      setNonceLookup(n.toString())
    } catch (e: any) {
      toast(`Lookup failed: ${e.message}`, 'danger')
    }
  }

  if (!metaTxAddress) {
    return <div className="text-muted text-sm p-4">Set VITE_METATX_ADDRESS in .env to enable this tab.</div>
  }
  if (!metaTx) {
    return <div className="text-muted text-sm p-4">MetaTx contract loading…</div>
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
          <span className="text-muted uppercase">Aggregator</span>
          <div className="font-mono mt-1 truncate">{state.aggregatorAddr}</div>
        </div>
        <div>
          <span className="text-muted uppercase">Permit2</span>
          <div className="font-mono mt-1 truncate">
            {state.permit2Addr === ethers.ZeroAddress ? '—' : state.permit2Addr}
          </div>
        </div>
        {state.pendingOwner && state.pendingOwner !== ethers.ZeroAddress && (
          <div className="col-span-2">
            <span className="text-muted uppercase">Pending Owner</span>
            <div className="font-mono mt-1 truncate">{state.pendingOwner}</div>
          </div>
        )}
      </div>

      {/* Nonce Lookup */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Nonce Lookup
        </div>
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <p className="text-xs text-muted">
            Each user's nonce increments on every executed meta-tx. Use <span className="font-mono">invalidateNonces</span> to cancel pending orders.
          </p>
          <div className="flex gap-2 items-end">
            <div className="flex-1">
              <Input
                label="User Address"
                placeholder="0x…"
                value={nonceAddr}
                onChange={e => { setNonceAddr(e.target.value); setNonceLookup(null) }}
              />
            </div>
            <Button onClick={lookupNonce} disabled={isSubmitting}>Lookup</Button>
          </div>
          {nonceLookup !== null && (
            <div className="text-sm font-mono bg-bg border border-border rounded px-3 py-2">
              Current nonce: <span className="font-bold">{nonceLookup}</span>
            </div>
          )}
        </div>
      </div>

      {/* Owner-only actions */}
      {state.isOwner && (
        <>
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
                    tx(() => metaTx.rescueTokens(rescueToken, rescueRecipient, BigInt(rescueAmount)), 'Rescue tokens')
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
                    tx(() => metaTx.rescueNative(rescueNativeRecipient, ethers.parseEther(rescueNativeAmount)), 'Rescue BNB')
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
                  tx(() => metaTx.transferOwnership(newOwnerAddr), 'Transfer ownership')
                  setNewOwnerAddr('')
                }}
              >
                Transfer
              </Button>
            </div>
          </div>
        </>
      )}

      {/* Accept ownership */}
      {state.isPending && (
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <div className="font-semibold text-sm">Accept Ownership</div>
          <p className="text-xs text-ok">You have pending ownership of MetaTx!</p>
          <Button
            className="w-full"
            disabled={isSubmitting}
            onClick={() => tx(() => metaTx.acceptOwnership(), 'Accept ownership')}
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
