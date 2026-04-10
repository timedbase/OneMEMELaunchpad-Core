import { useState, useEffect, useCallback } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

interface VWState {
  owner: string
  factory: string
  isOwner: boolean
}

export default function VestingPanel() {
  const { vestingWallet, account, toast } = useWeb3()
  const [state, setState] = useState<VWState | null>(null)
  const [loading, setLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)

  // Check claimable
  const [checkToken, setCheckToken] = useState('')
  const [checkBeneficiary, setCheckBeneficiary] = useState('')
  const [checkResult, setCheckResult] = useState<string | null>(null)

  // Claim (connected wallet)
  const [claimToken, setClaimToken] = useState('')

  // Void schedule (owner)
  const [voidToken, setVoidToken] = useState('')
  const [voidBeneficiary, setVoidBeneficiary] = useState('')

  // Set factory (owner)
  const [newFactory, setNewFactory] = useState('')
  const [newOwner, setNewOwner] = useState('')

  const load = useCallback(async () => {
    if (!vestingWallet) return
    setLoading(true)
    try {
      const [owner, factory] = await Promise.all([vestingWallet.owner(), vestingWallet.factory()])
      setState({
        owner, factory,
        isOwner: account ? owner.toLowerCase() === account.toLowerCase() : false,
      })
    } catch (e) { toast(`Vesting load error: ${e}`, 'danger') }
    finally { setLoading(false) }
  }, [vestingWallet, account, toast])

  useEffect(() => { load() }, [load] )

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

  const handleCheckClaimable = async () => {
    if (!vestingWallet) return
    if (!ethers.isAddress(checkToken)) return toast('Invalid token address', 'danger')
    const ben = checkBeneficiary || account
    if (!ben || !ethers.isAddress(ben)) return toast('Invalid beneficiary', 'danger')
    try {
      const amt = await vestingWallet.claimable(checkToken, ben)
      setCheckResult(`${ethers.formatEther(amt)} tokens claimable for ${ben}`)
    } catch (e: any) { setCheckResult(`Error: ${e.message}`) }
  }

  if (!vestingWallet) return <div className="text-muted text-sm p-4">Vesting wallet not configured.</div>
  if (loading && !state) return <div className="text-muted text-sm p-4">Loading…</div>
  if (!state) return null

  return (
    <div className="space-y-4">
      {/* Status */}
      <div className="bg-surface border border-border rounded p-4 grid grid-cols-2 gap-3 text-xs">
        <div>
          <span className="text-muted">Owner</span>
          <div className="font-mono mt-1 truncate">{state.owner}</div>
        </div>
        <div>
          <span className="text-muted">Role</span>
          <div className="mt-1">
            {state.isOwner ? <Badge variant="ok">Owner</Badge> : <Badge variant="muted">User</Badge>}
          </div>
        </div>
        <div className="col-span-2">
          <span className="text-muted">Factory</span>
          <div className="font-mono mt-1 truncate">{state.factory}</div>
        </div>
        <div className="col-span-2 text-muted">Vesting duration: 365 days linear</div>
      </div>

      {/* Check Claimable */}
      <div className="bg-surface border border-border rounded p-4 space-y-3">
        <div className="font-semibold text-sm">Check Claimable</div>
        <Input label="Token Address" placeholder="0x…" value={checkToken} onChange={e => setCheckToken(e.target.value)} />
        <Input label={`Beneficiary (blank = your address)`} placeholder="0x… or leave blank"
          value={checkBeneficiary} onChange={e => setCheckBeneficiary(e.target.value)} />
        <Button onClick={handleCheckClaimable} variant="secondary" className="w-full">Check</Button>
        {checkResult && <p className="text-xs text-muted">{checkResult}</p>}
      </div>

      {/* Claim */}
      <div className="bg-surface border border-border rounded p-4 space-y-3">
        <div className="font-semibold text-sm">Claim Vested Tokens</div>
        <p className="text-xs text-muted">Claims your vested allocation for the specified token.</p>
        <Input label="Token Address" placeholder="0x…" value={claimToken} onChange={e => setClaimToken(e.target.value)} />
        <Button onClick={() => {
          if (!ethers.isAddress(claimToken)) return toast('Invalid token address', 'danger')
          exec(() => vestingWallet.claim(claimToken), 'Claim')
        }} disabled={isSubmitting} variant="ok" className="w-full">Claim</Button>
      </div>

      {/* Owner actions */}
      {state.isOwner && (
        <>
          {/* Void Schedule */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Void Schedule</div>
            <p className="text-xs text-muted">Burns remaining unclaimed tokens for a beneficiary. Irreversible.</p>
            <Input label="Token Address" placeholder="0x…" value={voidToken} onChange={e => setVoidToken(e.target.value)} />
            <Input label="Beneficiary Address" placeholder="0x…" value={voidBeneficiary} onChange={e => setVoidBeneficiary(e.target.value)} />
            <Button onClick={() => {
              if (!ethers.isAddress(voidToken)) return toast('Invalid token address', 'danger')
              if (!ethers.isAddress(voidBeneficiary)) return toast('Invalid beneficiary', 'danger')
              exec(() => vestingWallet.voidSchedule(voidToken, voidBeneficiary), 'Void schedule')
            }} disabled={isSubmitting} variant="danger" className="w-full">Void Schedule</Button>
          </div>

          {/* Set Factory */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Set Factory</div>
            <Input label="New Factory Address" placeholder="0x…" value={newFactory} onChange={e => setNewFactory(e.target.value)} />
            <Button onClick={() => {
              if (!ethers.isAddress(newFactory)) return toast('Invalid address', 'danger')
              exec(() => vestingWallet.setFactory(newFactory), 'Set factory')
            }} disabled={isSubmitting} className="w-full">Set Factory</Button>
          </div>

          {/* Transfer Ownership */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Transfer Ownership</div>
            <Input label="New Owner" placeholder="0x…" value={newOwner} onChange={e => setNewOwner(e.target.value)} />
            <Button onClick={() => {
              if (!ethers.isAddress(newOwner)) return toast('Invalid address', 'danger')
              exec(() => vestingWallet.transferOwnership(newOwner), 'Transfer ownership')
            }} disabled={isSubmitting} className="w-full">Transfer</Button>
          </div>
        </>
      )}
    </div>
  )
}
