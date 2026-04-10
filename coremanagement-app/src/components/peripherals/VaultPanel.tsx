import { useState, useEffect, useCallback } from 'react'
import { type Contract } from 'ethers'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

interface Proposal {
  id: number
  to: string
  value: bigint
  data: string
  proposer: string
  confirmCount: number
  executed: boolean
  cancelled: boolean
  confirmations: boolean[]  // per-signer
}

interface VaultState {
  signers: string[]
  threshold: number
  proposalCount: number
  isSigner: boolean
}

function statusBadge(p: Proposal) {
  if (p.cancelled) return <Badge variant="muted">Cancelled</Badge>
  if (p.executed)  return <Badge variant="ok">Executed</Badge>
  return <Badge variant="warn">Pending {p.confirmCount}/2</Badge>
}

interface VaultPanelProps {
  contract: Contract | null
  label: string
}

export default function VaultPanel({ contract, label }: VaultPanelProps) {
  const { account, toast } = useWeb3()

  const [vaultState, setVaultState] = useState<VaultState | null>(null)
  const [proposals, setProposals] = useState<Proposal[]>([])
  const [loading, setLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [page, setPage] = useState(0)
  const PAGE_SIZE = 5

  // New proposal form
  const [propTo, setPropTo] = useState('')
  const [propValue, setPropValue] = useState('')
  const [propData, setPropData] = useState('')

  const load = useCallback(async () => {
    if (!contract) return
    setLoading(true)
    try {
      const [s0, s1, s2, threshold, count] = await Promise.all([
        contract.signers(0),
        contract.signers(1),
        contract.signers(2),
        contract.THRESHOLD(),
        contract.proposalCount(),
      ])
      const signers = [s0, s1, s2]
      const isSigner = account ? signers.some(s => s.toLowerCase() === account.toLowerCase()) : false
      const totalCount = Number(count)
      setVaultState({ signers, threshold: Number(threshold), proposalCount: totalCount, isSigner })

      // Load last PAGE_SIZE proposals
      if (totalCount === 0) { setProposals([]); return }
      const start = Math.max(0, totalCount - PAGE_SIZE - page * PAGE_SIZE)
      const end = totalCount - page * PAGE_SIZE

      const loaded: Proposal[] = []
      for (let i = end - 1; i >= start; i--) {
        const [p, confs] = await Promise.all([
          contract.getProposal(i),
          contract.getSignerConfirmations(i),
        ])
        loaded.push({
          id: i,
          to: p.to,
          value: p.value,
          data: p.data,
          proposer: p.proposer,
          confirmCount: Number(p.confirmCount),
          executed: p.executed,
          cancelled: p.cancelled,
          confirmations: [confs[0], confs[1], confs[2]],
        })
      }
      setProposals(loaded)
    } catch (e) { toast(`Vault load error: ${e}`, 'danger') }
    finally { setLoading(false) }
  }, [contract, account, toast, page])

  useEffect(() => { load() }, [load])

  const exec = async (fn: () => Promise<any>, label_: string) => {
    setIsSubmitting(true)
    try {
      const t = await fn()
      toast(`${label_}…`, 'warn')
      await t.wait()
      toast(`${label_} done`, 'ok')
      await load()
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  const handlePropose = () => {
    if (!contract) return
    if (!ethers.isAddress(propTo)) return toast('Invalid target address', 'danger')
    const value = propValue ? ethers.parseEther(propValue) : 0n
    const data = propData.startsWith('0x') ? propData : propData ? '0x' + propData : '0x'
    exec(() => contract.propose(propTo, value, data), 'Propose')
  }

  if (!contract) return (
    <div className="bg-surface border border-border rounded p-4 space-y-3">
      <div className="font-semibold text-sm">{label}</div>
      <p className="text-xs text-muted">
        Address not configured. Set{' '}
        <span className="font-mono">
          {label === 'Creator Vault' ? 'VITE_CREATOR_VAULT_ADDRESS' : 'VITE_MAINTENANCE_VAULT_ADDRESS'}
        </span>{' '}
        in <span className="font-mono">.env.local</span> and restart the dev server.
      </p>
    </div>
  )
  if (loading && !vaultState) return <div className="text-muted text-sm p-4">Loading…</div>
  if (!vaultState) return null

  return (
    <div className="space-y-4">
      {/* Vault Info */}
      <div className="bg-surface border border-border rounded p-4 space-y-3">
        <div className="flex items-center justify-between">
          <div className="font-semibold text-sm">{label} — 2-of-3 Multisig</div>
          {vaultState.isSigner ? <Badge variant="ok">You are a signer</Badge> : <Badge variant="muted">Observer</Badge>}
        </div>
        <div className="text-xs space-y-1">
          <div className="text-muted">Signers</div>
          {vaultState.signers.map((s, i) => (
            <div key={i} className="font-mono flex items-center gap-2">
              <span className="text-muted w-4">{i}</span>
              <span className="truncate">{s}</span>
              {account?.toLowerCase() === s.toLowerCase() && <Badge variant="ok">You</Badge>}
            </div>
          ))}
        </div>
        <div className="text-xs text-muted">
          Threshold: {vaultState.threshold} / {vaultState.signers.length} &nbsp;·&nbsp; Total proposals: {vaultState.proposalCount}
        </div>
      </div>

      {/* New Proposal */}
      {vaultState.isSigner && (
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <div className="font-semibold text-sm">New Proposal</div>
          <Input label="To (target address)" placeholder="0x…" value={propTo} onChange={e => setPropTo(e.target.value)} />
          <Input label="Value (BNB, optional)" type="number" placeholder="0" step="0.01" min="0"
            value={propValue} onChange={e => setPropValue(e.target.value)} />
          <Input label="Calldata (hex, optional)" placeholder="0x… or leave blank for BNB transfer"
            value={propData} onChange={e => setPropData(e.target.value)} />
          <p className="text-xs text-muted">You auto-confirm as proposer (1 of 2 needed).</p>
          <Button onClick={handlePropose} disabled={isSubmitting} className="w-full">Propose</Button>
        </div>
      )}

      {/* Proposals List */}
      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <div className="font-semibold text-sm">Proposals</div>
          <div className="flex gap-2">
            <Button size="sm" variant="secondary" disabled={page === 0} onClick={() => setPage(p => p - 1)}>Newer</Button>
            <Button size="sm" variant="secondary"
              disabled={(page + 1) * PAGE_SIZE >= vaultState.proposalCount}
              onClick={() => setPage(p => p + 1)}>Older</Button>
          </div>
        </div>

        {proposals.length === 0 && <div className="text-muted text-xs">No proposals yet.</div>}

        {proposals.map(p => (
          <div key={p.id} className="bg-surface border border-border rounded p-4 space-y-2">
            <div className="flex items-center justify-between">
              <span className="text-xs text-muted">#{p.id}</span>
              {statusBadge(p)}
            </div>
            <div className="text-xs space-y-1">
              <div><span className="text-muted">To: </span><span className="font-mono">{p.to}</span></div>
              {p.value > 0n && <div><span className="text-muted">Value: </span>{ethers.formatEther(p.value)} BNB</div>}
              {p.data && p.data !== '0x' && (
                <div><span className="text-muted">Data: </span><span className="font-mono break-all">{p.data.slice(0, 66)}{p.data.length > 66 ? '…' : ''}</span></div>
              )}
              <div><span className="text-muted">Proposer: </span><span className="font-mono">{p.proposer}</span></div>
              <div className="flex gap-2 pt-1">
                {vaultState.signers.map((_s, i) => (
                  <Badge key={i} variant={p.confirmations[i] ? 'ok' : 'muted'}>
                    Signer {i}: {p.confirmations[i] ? '✓' : '—'}
                  </Badge>
                ))}
              </div>
            </div>

            {!p.executed && !p.cancelled && vaultState.isSigner && (() => {
              const myIdx = vaultState.signers.findIndex(s => s.toLowerCase() === account?.toLowerCase())
              const hasConfirmed = myIdx >= 0 && p.confirmations[myIdx]
              const canExecute = p.confirmCount >= vaultState.threshold
              return (
                <div className="flex gap-2 flex-wrap pt-1">
                  {!hasConfirmed && (
                    <Button size="sm" variant="ok" disabled={isSubmitting}
                      onClick={() => exec(() => contract!.confirm(p.id), `Confirm #${p.id}`)}>
                      Confirm
                    </Button>
                  )}
                  {hasConfirmed && (
                    <Button size="sm" variant="secondary" disabled={isSubmitting}
                      onClick={() => exec(() => contract!.revoke(p.id), `Revoke #${p.id}`)}>
                      Revoke
                    </Button>
                  )}
                  {canExecute && (
                    <Button size="sm" variant="default" disabled={isSubmitting}
                      onClick={() => exec(() => contract!.execute(p.id), `Execute #${p.id}`)}>
                      Execute
                    </Button>
                  )}
                  {p.proposer.toLowerCase() === account?.toLowerCase() && (
                    <Button size="sm" variant="danger" disabled={isSubmitting}
                      onClick={() => exec(() => contract!.cancel(p.id), `Cancel #${p.id}`)}>
                      Cancel
                    </Button>
                  )}
                </div>
              )
            })()}
          </div>
        ))}
      </div>
    </div>
  )
}
