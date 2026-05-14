import { useState, useEffect, useCallback } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

interface OneDexState {
  owner: string
  pendingOwner: string
  feeRecipient: string
  wbnb: string
  permit2: string
  feeBps: string
  isPaused: boolean
  isOwner: boolean
  isPending: boolean
}

function shortAddr(addr: string) {
  return addr ? `${addr.slice(0, 6)}…${addr.slice(-4)}` : '—'
}

export default function OneDexTab() {
  const { oneDex, oneDexAddress, account, toast } = useWeb3()

  const [state, setState] = useState<OneDexState | null>(null)
  const [loading, setLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)

  // Target whitelist
  const [targetAddr, setTargetAddr]       = useState('')
  const [removeAddr, setRemoveAddr]       = useState('')
  const [checkAddr, setCheckAddr]         = useState('')
  const [checkResult, setCheckResult]     = useState<boolean | null>(null)
  const [checkPending, setCheckPending]   = useState(false)

  // Fee recipient
  const [newFeeRecipient, setNewFeeRecipient] = useState('')

  // Rescue
  const [rescueToken, setRescueToken]                     = useState('')
  const [rescueRecipient, setRescueRecipient]             = useState('')
  const [rescueAmount, setRescueAmount]                   = useState('')
  const [rescueNativeRecipient, setRescueNativeRecipient] = useState('')
  const [rescueNativeAmount, setRescueNativeAmount]       = useState('')

  // Ownership
  const [newOwnerAddr, setNewOwnerAddr] = useState('')

  const load = useCallback(async () => {
    if (!oneDex) return
    setLoading(true)
    try {
      const [owner, pending, feeRecip, wbnb, permit2, feeBps, isPaused] = await Promise.all([
        oneDex.owner(),
        oneDex.pendingOwner(),
        oneDex.feeRecipient(),
        oneDex.WBNB(),
        oneDex.PERMIT2(),
        oneDex.FEE_BPS(),
        oneDex.isPaused(),
      ])
      setState({
        owner,
        pendingOwner: pending,
        feeRecipient: feeRecip,
        wbnb,
        permit2,
        feeBps: feeBps.toString(),
        isPaused,
        isOwner:   account ? owner.toLowerCase() === account.toLowerCase() : false,
        isPending: !!(account && pending && pending !== ethers.ZeroAddress &&
                      account.toLowerCase() === pending.toLowerCase()),
      })
    } catch (e) {
      toast(`Load error: ${e}`, 'danger')
    } finally {
      setLoading(false)
    }
  }, [oneDex, account, toast])

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

  if (!oneDexAddress) {
    return <div className="text-muted text-sm p-4">Set VITE_ONEDEX_ADDRESS in .env to enable this tab.</div>
  }
  if (!oneDex) {
    return <div className="text-muted text-sm p-4">OneDex contract loading…</div>
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
          <span className="text-muted uppercase">Fee</span>
          <div className="mt-1 font-semibold">{Number(state.feeBps) / 100}%</div>
        </div>
        <div>
          <span className="text-muted uppercase">Status</span>
          <div className="mt-1">
            <Badge variant={state.isPaused ? 'danger' : 'ok'}>
              {state.isPaused ? 'Paused' : 'Active'}
            </Badge>
          </div>
        </div>
        <div>
          <span className="text-muted uppercase">WBNB</span>
          <div className="font-mono mt-1 truncate">{shortAddr(state.wbnb)}</div>
        </div>
        <div>
          <span className="text-muted uppercase">Permit2</span>
          <div className="font-mono mt-1 truncate">{shortAddr(state.permit2)}</div>
        </div>
        {state.pendingOwner && state.pendingOwner !== ethers.ZeroAddress && (
          <div className="col-span-2">
            <span className="text-muted uppercase">Pending Owner</span>
            <div className="font-mono mt-1 truncate">{state.pendingOwner}</div>
          </div>
        )}
      </div>

      {/* Owner-only actions */}
      {state.isOwner && (
        <>
          {/* Pause / Unpause */}
          <div>
            <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              Circuit Breaker
            </div>
            <div className="bg-surface border border-border rounded p-4 flex gap-3">
              <Button
                className="flex-1"
                variant={state.isPaused ? 'ok' : 'danger'}
                disabled={isSubmitting}
                onClick={() => state.isPaused
                  ? tx(() => oneDex.unpause(), 'Unpause')
                  : tx(() => oneDex.pause(), 'Pause')
                }
              >
                {state.isPaused ? 'Unpause' : 'Pause'}
              </Button>
            </div>
          </div>

          {/* Target whitelist */}
          <div>
            <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              Target Whitelist
            </div>

            {/* Check — always visible */}
            <div className="bg-surface border border-border rounded p-4 space-y-3 mb-4">
              <div className="font-semibold text-sm">Check Target</div>
              <div className="flex gap-2">
                <Input
                  label=""
                  placeholder="0x…"
                  value={checkAddr}
                  onChange={e => { setCheckAddr(e.target.value); setCheckResult(null) }}
                  className="flex-1"
                />
                <Button
                  disabled={checkPending}
                  onClick={async () => {
                    if (!ethers.isAddress(checkAddr)) return toast('Invalid address', 'danger')
                    setCheckPending(true)
                    try {
                      const allowed = await oneDex.allowedTargets(checkAddr)
                      setCheckResult(allowed)
                    } catch (e: any) {
                      toast(`Check failed: ${e.message}`, 'danger')
                    } finally {
                      setCheckPending(false)
                    }
                  }}
                >
                  Check
                </Button>
              </div>
              {checkResult !== null && (
                <Badge variant={checkResult ? 'ok' : 'danger'}>
                  {shortAddr(checkAddr)} is {checkResult ? 'whitelisted' : 'not whitelisted'}
                </Badge>
              )}
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div className="bg-surface border border-border rounded p-4 space-y-3">
                <div className="font-semibold text-sm">Add Target</div>
                <Input
                  label="Router / AMM Address"
                  placeholder="0x…"
                  value={targetAddr}
                  onChange={e => setTargetAddr(e.target.value)}
                />
                <Button
                  className="w-full"
                  disabled={isSubmitting}
                  onClick={() => {
                    if (!ethers.isAddress(targetAddr)) return toast('Invalid address', 'danger')
                    tx(() => oneDex.addTarget(targetAddr), `Add target ${shortAddr(targetAddr)}`)
                    setTargetAddr('')
                  }}
                >
                  Add Target
                </Button>
              </div>
              <div className="bg-surface border border-border rounded p-4 space-y-3">
                <div className="font-semibold text-sm">Remove Target</div>
                <Input
                  label="Router / AMM Address"
                  placeholder="0x…"
                  value={removeAddr}
                  onChange={e => setRemoveAddr(e.target.value)}
                />
                <Button
                  className="w-full"
                  variant="danger"
                  disabled={isSubmitting}
                  onClick={() => {
                    if (!ethers.isAddress(removeAddr)) return toast('Invalid address', 'danger')
                    tx(() => oneDex.removeTarget(removeAddr), `Remove target ${shortAddr(removeAddr)}`)
                    setRemoveAddr('')
                  }}
                >
                  Remove Target
                </Button>
              </div>
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
                  tx(() => oneDex.setFeeRecipient(newFeeRecipient), 'Set fee recipient')
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
                    tx(() => oneDex.rescueToken(rescueToken, rescueRecipient, BigInt(rescueAmount)), 'Rescue tokens')
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
                    tx(() => oneDex.rescueNative(rescueNativeRecipient, ethers.parseEther(rescueNativeAmount)), 'Rescue BNB')
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
                  tx(() => oneDex.transferOwnership(newOwnerAddr), 'Transfer ownership')
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
          <p className="text-xs text-ok">You have pending ownership of OneDex!</p>
          <Button
            className="w-full"
            disabled={isSubmitting}
            onClick={() => tx(() => oneDex.acceptOwnership(), 'Accept ownership')}
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
