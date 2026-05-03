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

// Resolve an adapter ID input: raw bytes32 hex passes through; anything else is keccak256-hashed
function resolveAdapterId(raw: string): string {
  const trimmed = raw.trim()
  if (/^0x[0-9a-fA-F]{64}$/.test(trimmed)) return trimmed
  return ethers.id(trimmed)
}

const PERMIT_TYPES = [
  { value: '0', label: 'None (pre-approved allowance)' },
  { value: '1', label: 'EIP-2612 (native permit)' },
  { value: '2', label: 'Permit2' },
]

export default function MetaTxTab() {
  const { metaTx, metaTxAddress, account, toast } = useWeb3()

  const [state, setState] = useState<MetaTxState | null>(null)
  const [loading, setLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)

  // ── Nonce lookup ──────────────────────────────────────────────
  const [nonceAddr, setNonceAddr]       = useState('')
  const [nonceLookup, setNonceLookup]   = useState<string | null>(null)

  // ── Execute MetaTx ────────────────────────────────────────────
  const [exUser, setExUser]             = useState('')
  const [exNonce, setExNonce]           = useState('')
  const [exDeadline, setExDeadline]     = useState('')
  const [exAdapterId, setExAdapterId]   = useState('')
  const [exTokenIn, setExTokenIn]       = useState('')
  const [exGrossIn, setExGrossIn]       = useState('')
  const [exTokenOut, setExTokenOut]     = useState('')
  const [exMinOut, setExMinOut]         = useState('')
  const [exRecipient, setExRecipient]   = useState('')
  const [exSwapDl, setExSwapDl]         = useState('')
  const [exAdapterData, setExAdapterData] = useState('0x')
  const [exRelayerFee, setExRelayerFee] = useState('0')
  const [exSig, setExSig]               = useState('')
  const [exPermitType, setExPermitType] = useState('0')
  const [exPermitData, setExPermitData] = useState('0x')
  const [exDigest, setExDigest]         = useState<string | null>(null)

  // ── Owner: rescue ─────────────────────────────────────────────
  const [rescueToken, setRescueToken]               = useState('')
  const [rescueRecipient, setRescueRecipient]       = useState('')
  const [rescueAmount, setRescueAmount]             = useState('')
  const [rescueNativeRecipient, setRescueNativeRecipient] = useState('')
  const [rescueNativeAmount, setRescueNativeAmount] = useState('')

  // ── Owner: ownership ─────────────────────────────────────────
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

  const computeDigest = async () => {
    if (!metaTx) return
    try {
      const order = buildOrder()
      const digest = await metaTx.orderDigest(order)
      setExDigest(digest)
    } catch (e: any) {
      toast(`Digest error: ${e.message}`, 'danger')
    }
  }

  const buildOrder = () => ({
    user:         exUser,
    nonce:        BigInt(exNonce || '0'),
    deadline:     BigInt(exDeadline || '0'),
    adapterId:    resolveAdapterId(exAdapterId),
    tokenIn:      exTokenIn,
    grossAmountIn: BigInt(exGrossIn || '0'),
    tokenOut:     exTokenOut,
    minUserOut:   BigInt(exMinOut || '0'),
    recipient:    exRecipient,
    swapDeadline: BigInt(exSwapDl || '0'),
    adapterData:  exAdapterData || '0x',
    relayerFee:   BigInt(exRelayerFee || '0'),
  })

  const executeMetaTx = () => {
    if (!metaTx) return
    if (!ethers.isAddress(exUser))      return toast('Invalid user address', 'danger')
    if (!ethers.isAddress(exTokenIn))   return toast('Invalid tokenIn', 'danger')
    if (!ethers.isAddress(exTokenOut))  return toast('Invalid tokenOut', 'danger')
    if (!ethers.isAddress(exRecipient)) return toast('Invalid recipient', 'danger')
    if (!exAdapterId.trim())            return toast('Enter adapter ID', 'danger')
    if (!exSig.startsWith('0x') || exSig.length !== 132) return toast('Signature must be 0x + 130 hex chars (65 bytes)', 'danger')

    const order = buildOrder()
    const permit = { permitType: Number(exPermitType), data: exPermitData || '0x' }

    tx(() => metaTx.executeMetaTx(order, exSig, permit), 'Execute MetaTx')
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

      {/* ── Status ── */}
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

      {/* ── Execute MetaTx ── */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Execute Meta-Tx Order
        </div>
        <div className="bg-surface border border-border rounded p-4 space-y-4">
          <p className="text-xs text-muted">
            Relay a user-signed order on-chain. Any connected wallet can act as relayer —
            no ownership required. The relayer pays gas and receives <span className="font-mono">relayerFee</span> BNB from swap output.
          </p>

          {/* Order fields */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            <Input
              label="User (signer)"
              placeholder="0x…"
              value={exUser}
              onChange={e => setExUser(e.target.value)}
            />
            <div className="flex gap-2 items-end">
              <div className="flex-1">
                <Input
                  label="Nonce"
                  placeholder="0"
                  value={exNonce}
                  onChange={e => setExNonce(e.target.value)}
                />
              </div>
              <Button
                size="sm"
                variant="secondary"
                disabled={!exUser || !ethers.isAddress(exUser)}
                onClick={async () => {
                  if (!metaTx || !ethers.isAddress(exUser)) return
                  try {
                    const n = await metaTx.nonces(exUser)
                    setExNonce(n.toString())
                  } catch {}
                }}
              >
                Fetch
              </Button>
            </div>
            <Input
              label="Order Deadline (unix)"
              placeholder="1700000000"
              value={exDeadline}
              onChange={e => setExDeadline(e.target.value)}
            />
            <Input
              label="Swap Deadline (unix)"
              placeholder="1700000000"
              value={exSwapDl}
              onChange={e => setExSwapDl(e.target.value)}
            />
            <Input
              label="Adapter ID (string or bytes32 hex)"
              placeholder="PANCAKE_V2 or 0xabc…"
              value={exAdapterId}
              onChange={e => { setExAdapterId(e.target.value); setExDigest(null) }}
            />
            <Input
              label="Relayer Fee (wei BNB)"
              placeholder="0"
              value={exRelayerFee}
              onChange={e => setExRelayerFee(e.target.value)}
            />
            <Input
              label="Token In"
              placeholder="0x…"
              value={exTokenIn}
              onChange={e => setExTokenIn(e.target.value)}
            />
            <Input
              label="Gross Amount In (wei)"
              placeholder="1000000000000000000"
              value={exGrossIn}
              onChange={e => setExGrossIn(e.target.value)}
            />
            <Input
              label="Token Out (0x0 = BNB)"
              placeholder="0x… or 0x000…0"
              value={exTokenOut}
              onChange={e => setExTokenOut(e.target.value)}
            />
            <Input
              label="Min User Out (wei)"
              placeholder="0"
              value={exMinOut}
              onChange={e => setExMinOut(e.target.value)}
            />
            <div className="md:col-span-2">
              <Input
                label="Recipient"
                placeholder="0x…"
                value={exRecipient}
                onChange={e => setExRecipient(e.target.value)}
              />
            </div>
            <div className="md:col-span-2">
              <Input
                label="Adapter Data (hex)"
                placeholder="0x"
                value={exAdapterData}
                onChange={e => setExAdapterData(e.target.value)}
              />
            </div>
          </div>

          {/* Signature */}
          <div className="pt-1 border-t border-border space-y-3">
            <div className="text-xs font-semibold text-text">Signature</div>
            <Input
              label="EIP-712 signature (0x + 130 hex chars)"
              placeholder="0x…"
              value={exSig}
              onChange={e => setExSig(e.target.value)}
            />
            <div className="flex gap-2 items-center flex-wrap">
              <Button size="sm" variant="secondary" onClick={computeDigest} disabled={isSubmitting}>
                Compute Digest
              </Button>
              {exDigest && (
                <span className="text-xs font-mono text-muted break-all">{exDigest}</span>
              )}
            </div>
          </div>

          {/* Permit */}
          <div className="pt-1 border-t border-border space-y-3">
            <div className="text-xs font-semibold text-text">Permit / Approval</div>
            <div className="flex flex-wrap gap-2">
              {PERMIT_TYPES.map(p => (
                <button
                  key={p.value}
                  onClick={() => setExPermitType(p.value)}
                  className={`px-3 py-1.5 rounded-lg text-xs font-medium border cursor-pointer transition-all ${
                    exPermitType === p.value
                      ? 'bg-accent/15 text-accent border-accent/30'
                      : 'bg-transparent text-muted border-border hover:text-text'
                  }`}
                >
                  {p.label}
                </button>
              ))}
            </div>
            {exPermitType !== '0' && (
              <Input
                label={
                  exPermitType === '1'
                    ? 'EIP-2612 permit data — abi.encode(uint256 deadline, uint8 v, bytes32 r, bytes32 s)'
                    : 'Permit2 data — abi.encode(uint256 nonce, uint256 deadline, bytes signature)'
                }
                placeholder="0x…"
                value={exPermitData}
                onChange={e => setExPermitData(e.target.value)}
              />
            )}
          </div>

          <Button className="w-full" disabled={isSubmitting} onClick={executeMetaTx}>
            Execute Meta-Tx
          </Button>
        </div>
      </div>

      {/* ── Nonce Lookup ── */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Nonce Lookup
        </div>
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <p className="text-xs text-muted">
            Each user's nonce increments on every executed order.
            Use <span className="font-mono">invalidateNonces</span> to batch-cancel pending orders.
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

      {/* ── Owner-only ── */}
      {state.isOwner && (
        <>
          <div>
            <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              Rescue
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div className="bg-surface border border-border rounded p-4 space-y-3">
                <div className="font-semibold text-sm">Rescue ERC-20 Tokens</div>
                <Input label="Token Address" placeholder="0x…" value={rescueToken} onChange={e => setRescueToken(e.target.value)} />
                <Input label="Recipient" placeholder="0x…" value={rescueRecipient} onChange={e => setRescueRecipient(e.target.value)} />
                <Input label="Amount (wei)" placeholder="1000000000000000000" value={rescueAmount} onChange={e => setRescueAmount(e.target.value)} />
                <Button className="w-full" variant="danger" disabled={isSubmitting} onClick={() => {
                  if (!ethers.isAddress(rescueToken))     return toast('Invalid token address', 'danger')
                  if (!ethers.isAddress(rescueRecipient)) return toast('Invalid recipient', 'danger')
                  if (!rescueAmount)                      return toast('Enter amount in wei', 'danger')
                  tx(() => metaTx.rescueTokens(rescueToken, rescueRecipient, BigInt(rescueAmount)), 'Rescue tokens')
                  setRescueToken(''); setRescueRecipient(''); setRescueAmount('')
                }}>Rescue Tokens</Button>
              </div>

              <div className="bg-surface border border-border rounded p-4 space-y-3">
                <div className="font-semibold text-sm">Rescue Native BNB</div>
                <Input label="Recipient" placeholder="0x…" value={rescueNativeRecipient} onChange={e => setRescueNativeRecipient(e.target.value)} />
                <Input label="Amount (BNB)" type="number" placeholder="0.1" step="0.01" min="0" value={rescueNativeAmount} onChange={e => setRescueNativeAmount(e.target.value)} />
                <Button className="w-full" variant="danger" disabled={isSubmitting} onClick={() => {
                  if (!ethers.isAddress(rescueNativeRecipient)) return toast('Invalid recipient', 'danger')
                  if (!rescueNativeAmount)                       return toast('Enter amount', 'danger')
                  tx(() => metaTx.rescueNative(rescueNativeRecipient, ethers.parseEther(rescueNativeAmount)), 'Rescue BNB')
                  setRescueNativeRecipient(''); setRescueNativeAmount('')
                }}>Rescue BNB</Button>
              </div>
            </div>
          </div>

          <div>
            <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              Ownership Transfer
            </div>
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Transfer Ownership</div>
              <p className="text-xs text-muted">Current: {shortAddr(state.owner)}</p>
              <Input label="New Owner" placeholder="0x…" value={newOwnerAddr} onChange={e => setNewOwnerAddr(e.target.value)} />
              <Button className="w-full" disabled={isSubmitting} onClick={() => {
                if (!ethers.isAddress(newOwnerAddr)) return toast('Invalid address', 'danger')
                tx(() => metaTx.transferOwnership(newOwnerAddr), 'Transfer ownership')
                setNewOwnerAddr('')
              }}>Transfer</Button>
            </div>
          </div>
        </>
      )}

      {state.isPending && (
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <div className="font-semibold text-sm">Accept Ownership</div>
          <p className="text-xs text-ok">You have pending ownership of MetaTx!</p>
          <Button className="w-full" disabled={isSubmitting} onClick={() => tx(() => metaTx.acceptOwnership(), 'Accept ownership')}>
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
