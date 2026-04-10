import { useState, useEffect, useCallback, type ReactNode } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

// keccak256 of each action string — matches contract constants
const TL_IDS: Record<string, string> = {
  SET_PLATFORM_FEE:   ethers.id('SET_PLATFORM_FEE'),
  SET_CHARITY_FEE:    ethers.id('SET_CHARITY_FEE'),
  SET_FEE_RECIPIENT:  ethers.id('SET_FEE_RECIPIENT'),
  SET_CHARITY_WALLET: ethers.id('SET_CHARITY_WALLET'),
  SET_ROUTER:         ethers.id('SET_ROUTER'),
}

interface AdminState {
  owner: string
  pendingOwner: string
  isOwner: boolean
  isPending: boolean
}

interface TimelockEntry {
  key: string
  expiry: number   // unix seconds, 0 = not queued
}

function formatCountdown(seconds: number): string {
  if (seconds <= 0) return 'Ready to execute'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  return `${h}h ${m}m remaining`
}

function shortAddress(addr: string) {
  return addr ? `${addr.slice(0, 6)}...${addr.slice(-4)}` : '—'
}

export default function AdminTab() {
  const { factory, account, toast } = useWeb3()
  const [adminState, setAdminState] = useState<AdminState | null>(null)
  const [loading, setLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)

  // Quick action form state
  const [newFee, setNewFee] = useState('')
  const [newVBNB, setNewVBNB] = useState('')
  const [newMigTarget, setNewMigTarget] = useState('')
  const [rescueBNBRecipient, setRescueBNBRecipient] = useState('')
  const [rescueTokenAddr, setRescueTokenAddr] = useState('')
  const [rescueTokenRecipient, setRescueTokenRecipient] = useState('')
  const [newVestingWallet, setNewVestingWallet] = useState('')

  // Manager form state
  const [checkMgrAddr, setCheckMgrAddr] = useState('')
  const [checkMgrResult, setCheckMgrResult] = useState('')
  const [mgrAddr, setMgrAddr] = useState('')

  // Ownership form state
  const [newOwnerAddr, setNewOwnerAddr] = useState('')

  // Timelock state
  const [timelocks, setTimelocks] = useState<TimelockEntry[]>([])
  const [now, setNow] = useState(Math.floor(Date.now() / 1000))

  // Timelock form inputs
  const [tlPlatformFee, setTlPlatformFee] = useState('')
  const [tlCharityFee, setTlCharityFee] = useState('')
  const [tlFeeRecipient, setTlFeeRecipient] = useState('')
  const [tlCharityWallet, setTlCharityWallet] = useState('')
  const [tlRouter, setTlRouter] = useState('')

  // Tick every 30 s so countdown updates
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 30_000)
    return () => clearInterval(id)
  }, [])

  const loadAdminData = useCallback(async () => {
    if (!factory) return
    setLoading(true)
    try {
      const [owner, pending] = await Promise.all([factory.owner(), factory.pendingOwner()])
      setAdminState({
        owner,
        pendingOwner: pending,
        isOwner: account ? owner.toLowerCase() === account.toLowerCase() : false,
        isPending: !!(account && pending && account.toLowerCase() === pending.toLowerCase()),
      })

      // Load timelock expiries
      const keys = Object.keys(TL_IDS)
      const expiries = await Promise.all(keys.map(k => factory.timelockExpiry(TL_IDS[k])))
      setTimelocks(keys.map((key, i) => ({ key, expiry: Number(expiries[i]) })))
    } catch (e) {
      toast(`Error loading admin data: ${e}`, 'danger')
    } finally {
      setLoading(false)
    }
  }, [factory, account, toast])

  useEffect(() => { loadAdminData() }, [loadAdminData])

  // ─── Quick Actions ───────────────────────────────────────────────────────────

  const handleSetCreationFee = async () => {
    if (!factory || !adminState?.isOwner) return toast('Owner access required', 'danger')
    if (!newFee) return toast('Enter fee amount', 'danger')
    setIsSubmitting(true)
    try {
      const tx = await factory.setCreationFee(ethers.parseEther(newFee))
      toast('Setting fee…', 'warn')
      await tx.wait()
      toast('Creation fee updated', 'ok')
      setNewFee('')
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  const handleSetDefaultParams = async () => {
    if (!factory || !adminState?.isOwner) return toast('Owner access required', 'danger')
    if (!newVBNB || !newMigTarget) return toast('Enter both parameters', 'danger')
    setIsSubmitting(true)
    try {
      const tx = await factory.setDefaultParams(ethers.parseEther(newVBNB), ethers.parseEther(newMigTarget))
      toast('Setting params…', 'warn')
      await tx.wait()
      toast('Default params updated', 'ok')
      setNewVBNB(''); setNewMigTarget('')
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  const handleRescueBNB = async () => {
    if (!factory || !adminState?.isOwner) return toast('Owner access required', 'danger')
    if (!ethers.isAddress(rescueBNBRecipient)) return toast('Invalid recipient address', 'danger')
    setIsSubmitting(true)
    try {
      const tx = await factory.rescueBNB(rescueBNBRecipient)
      toast('Rescuing BNB…', 'warn')
      await tx.wait()
      toast('BNB rescued', 'ok')
      setRescueBNBRecipient('')
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  const handleRescueToken = async () => {
    if (!factory || !adminState?.isOwner) return toast('Owner access required', 'danger')
    if (!ethers.isAddress(rescueTokenAddr)) return toast('Invalid token address', 'danger')
    if (!ethers.isAddress(rescueTokenRecipient)) return toast('Invalid recipient address', 'danger')
    setIsSubmitting(true)
    try {
      const tx = await factory.rescueToken(rescueTokenAddr, rescueTokenRecipient)
      toast('Rescuing token…', 'warn')
      await tx.wait()
      toast('Token rescued', 'ok')
      setRescueTokenAddr(''); setRescueTokenRecipient('')
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  const handleSetVestingWallet = async () => {
    if (!factory || !adminState?.isOwner) return toast('Owner access required', 'danger')
    if (!ethers.isAddress(newVestingWallet)) return toast('Invalid address', 'danger')
    setIsSubmitting(true)
    try {
      const tx = await factory.setVestingWallet(newVestingWallet)
      toast('Setting vesting wallet…', 'warn')
      await tx.wait()
      toast('Vesting wallet updated', 'ok')
      setNewVestingWallet('')
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  // ─── Timelock helpers ────────────────────────────────────────────────────────

  const tlState = (key: string) => {
    const entry = timelocks.find(t => t.key === key)
    const expiry = entry?.expiry ?? 0
    return { expiry, queued: expiry > 0, ready: expiry > 0 && now >= expiry }
  }

  const handlePropose = async (fn: string, args: unknown[]) => {
    if (!factory) return
    setIsSubmitting(true)
    try {
      const tx = await (factory as any)[fn](...args)
      toast('Queuing action…', 'warn')
      await tx.wait()
      toast('Action queued (48h timelock)', 'ok')
      await loadAdminData()
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  const handleExecute = async (fn: string) => {
    if (!factory) return
    setIsSubmitting(true)
    try {
      const tx = await (factory as any)[fn]()
      toast('Executing…', 'warn')
      await tx.wait()
      toast('Executed successfully', 'ok')
      await loadAdminData()
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  const handleCancel = async (actionId: string) => {
    if (!factory) return
    setIsSubmitting(true)
    try {
      const tx = await factory.cancelAction(actionId)
      toast('Cancelling…', 'warn')
      await tx.wait()
      toast('Action cancelled', 'ok')
      await loadAdminData()
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  // ─── Manager Actions ─────────────────────────────────────────────────────────

  const handleCheckManager = async () => {
    if (!factory) return toast('Factory not loaded', 'danger')
    if (!ethers.isAddress(checkMgrAddr)) return toast('Invalid address', 'danger')
    try {
      const isManager = await factory.managers(checkMgrAddr)
      setCheckMgrResult(isManager ? 'Is a manager' : 'Not a manager')
    } catch (e: any) { setCheckMgrResult(`Error: ${e.message}`) }
  }

  const handleAddManager = async () => {
    if (!factory || !adminState?.isOwner) return toast('Owner access required', 'danger')
    if (!ethers.isAddress(mgrAddr)) return toast('Invalid address', 'danger')
    setIsSubmitting(true)
    try {
      const tx = await factory.addManager(mgrAddr)
      toast('Adding manager…', 'warn')
      await tx.wait()
      toast('Manager added', 'ok')
      setMgrAddr('')
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  const handleRemoveManager = async () => {
    if (!factory || !adminState?.isOwner) return toast('Owner access required', 'danger')
    if (!ethers.isAddress(mgrAddr)) return toast('Invalid address', 'danger')
    setIsSubmitting(true)
    try {
      const tx = await factory.removeManager(mgrAddr)
      toast('Removing manager…', 'warn')
      await tx.wait()
      toast('Manager removed', 'ok')
      setMgrAddr('')
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  // ─── Ownership ───────────────────────────────────────────────────────────────

  const handleTransferOwnership = async () => {
    if (!factory || !adminState?.isOwner) return toast('Owner access required', 'danger')
    if (!ethers.isAddress(newOwnerAddr)) return toast('Invalid address', 'danger')
    setIsSubmitting(true)
    try {
      const tx = await factory.transferOwnership(newOwnerAddr)
      toast('Proposing ownership transfer…', 'warn')
      await tx.wait()
      toast('Transfer initiated — new owner must accept', 'ok')
      setNewOwnerAddr('')
      await loadAdminData()
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  const handleAcceptOwnership = async () => {
    if (!factory || !adminState?.isPending) return toast('Must have pending ownership', 'danger')
    setIsSubmitting(true)
    try {
      const tx = await factory.acceptOwnership()
      toast('Accepting ownership…', 'warn')
      await tx.wait()
      toast('Ownership accepted', 'ok')
      await loadAdminData()
    } catch (e: any) { toast(`Failed: ${e.reason || e.message}`, 'danger') }
    finally { setIsSubmitting(false) }
  }

  // ─── Render helpers ──────────────────────────────────────────────────────────

  function TimelockCard({
    label, actionKey, proposeFn, executeFn, children,
  }: {
    label: string
    actionKey: string
    proposeFn: () => void
    executeFn: () => void
    children: ReactNode
  }) {
    const { expiry, queued, ready } = tlState(actionKey)
    return (
      <div className="bg-surface border border-border rounded p-4 space-y-3">
        <div className="flex items-center justify-between">
          <div className="font-semibold text-sm">{label}</div>
          {!queued ? (
            <Badge variant="muted">Not queued</Badge>
          ) : ready ? (
            <Badge variant="ok">Ready</Badge>
          ) : (
            <Badge variant="warn">Queued</Badge>
          )}
        </div>
        {queued && (
          <p className="text-xs text-muted">
            {ready ? 'Timelock expired — ready to execute' : formatCountdown(expiry - now)}
          </p>
        )}
        {children}
        <div className="flex gap-2 flex-wrap">
          {!queued && (
            <Button onClick={proposeFn} disabled={isSubmitting} size="sm" variant="default">
              Propose
            </Button>
          )}
          {queued && ready && (
            <Button onClick={executeFn} disabled={isSubmitting} size="sm" variant="ok">
              Execute
            </Button>
          )}
          {queued && (
            <Button onClick={() => handleCancel(TL_IDS[actionKey])} disabled={isSubmitting} size="sm" variant="danger">
              Cancel
            </Button>
          )}
        </div>
      </div>
    )
  }

  if (!adminState) {
    return (
      <div className="text-center py-20 text-muted">
        {loading ? 'Loading admin data…' : 'Load a factory address first.'}
      </div>
    )
  }

  return (
    <div className="space-y-6">
      {/* Ownership Info */}
      <div className="bg-surface border border-border rounded p-4">
        <div className="grid grid-cols-2 gap-4 text-sm">
          <div>
            <span className="text-xs text-muted uppercase">Current Owner</span>
            <div className="font-mono text-xs mt-1">{shortAddress(adminState.owner)}</div>
          </div>
          <div>
            <span className="text-xs text-muted uppercase">Status</span>
            <div className="mt-1">
              {adminState.isOwner ? (
                <Badge variant="ok">You are owner</Badge>
              ) : adminState.isPending ? (
                <Badge variant="warn">Pending ownership</Badge>
              ) : (
                <Badge variant="muted">Not owner</Badge>
              )}
            </div>
          </div>
          {adminState.pendingOwner && adminState.pendingOwner !== ethers.ZeroAddress && (
            <div className="col-span-2">
              <span className="text-xs text-muted uppercase">Pending Owner</span>
              <div className="font-mono text-xs mt-1">{adminState.pendingOwner}</div>
            </div>
          )}
        </div>
      </div>

      {/* Quick Actions (no timelock) */}
      {adminState.isOwner && (
        <div>
          <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
            Quick Actions <span className="text-xs text-muted font-normal">(no timelock)</span>
          </div>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">

            {/* Set Creation Fee */}
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Set Creation Fee</div>
              <Input label="Fee (BNB)" type="number" placeholder="0.0011" step="0.0001" min="0"
                value={newFee} onChange={e => setNewFee(e.target.value)} />
              <Button onClick={handleSetCreationFee} disabled={isSubmitting} className="w-full">Set Fee</Button>
            </div>

            {/* Set Default Params */}
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Set Default Params</div>
              <Input label="Virtual BNB (BNB)" type="number" placeholder="1.0" step="0.1" min="0"
                value={newVBNB} onChange={e => setNewVBNB(e.target.value)} />
              <Input label="Migration Target (BNB)" type="number" placeholder="50" step="1" min="0"
                value={newMigTarget} onChange={e => setNewMigTarget(e.target.value)} />
              <Button onClick={handleSetDefaultParams} disabled={isSubmitting} className="w-full">Set Params</Button>
            </div>

            {/* Rescue BNB */}
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Rescue BNB</div>
              <p className="text-xs text-muted">Sweeps excess BNB from bonding curve + factory to recipient.</p>
              <Input label="Recipient" placeholder="0x…"
                value={rescueBNBRecipient} onChange={e => setRescueBNBRecipient(e.target.value)} />
              <Button onClick={handleRescueBNB} disabled={isSubmitting} className="w-full" variant="danger">
                Rescue BNB
              </Button>
            </div>

            {/* Rescue Token */}
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Rescue Token</div>
              <p className="text-xs text-muted">Rescues ERC-20 tokens from bonding curve + factory. Active pool tokens are blocked.</p>
              <Input label="Token Address" placeholder="0x…"
                value={rescueTokenAddr} onChange={e => setRescueTokenAddr(e.target.value)} />
              <Input label="Recipient" placeholder="0x…"
                value={rescueTokenRecipient} onChange={e => setRescueTokenRecipient(e.target.value)} />
              <Button onClick={handleRescueToken} disabled={isSubmitting} className="w-full" variant="danger">
                Rescue Token
              </Button>
            </div>

            {/* Set Vesting Wallet */}
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Set Vesting Wallet</div>
              <Input label="New Vesting Wallet Address" placeholder="0x…"
                value={newVestingWallet} onChange={e => setNewVestingWallet(e.target.value)} />
              <Button onClick={handleSetVestingWallet} disabled={isSubmitting} className="w-full">
                Set Vesting Wallet
              </Button>
            </div>

          </div>
        </div>
      )}

      {/* Timelocked Actions (48h delay) */}
      {adminState.isOwner && (
        <div>
          <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
            Timelocked Actions <span className="text-xs text-muted font-normal">(48h delay)</span>
          </div>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">

            <TimelockCard
              label="Set Platform Fee"
              actionKey="SET_PLATFORM_FEE"
              proposeFn={() => {
                if (!tlPlatformFee) return toast('Enter fee BPS', 'danger')
                handlePropose('proposeSetPlatformFee', [Number(tlPlatformFee)])
              }}
              executeFn={() => handleExecute('executeSetPlatformFee')}
            >
              <Input label="Fee (BPS, max 250 total with charity)" type="number" placeholder="50" min="0" max="250"
                value={tlPlatformFee} onChange={e => setTlPlatformFee(e.target.value)} />
            </TimelockCard>

            <TimelockCard
              label="Set Charity Fee"
              actionKey="SET_CHARITY_FEE"
              proposeFn={() => {
                if (!tlCharityFee) return toast('Enter fee BPS', 'danger')
                handlePropose('proposeSetCharityFee', [Number(tlCharityFee)])
              }}
              executeFn={() => handleExecute('executeSetCharityFee')}
            >
              <Input label="Fee (BPS, max 250 total with platform)" type="number" placeholder="0" min="0" max="250"
                value={tlCharityFee} onChange={e => setTlCharityFee(e.target.value)} />
            </TimelockCard>

            <TimelockCard
              label="Set Fee Recipient"
              actionKey="SET_FEE_RECIPIENT"
              proposeFn={() => {
                if (!ethers.isAddress(tlFeeRecipient)) return toast('Invalid address', 'danger')
                handlePropose('proposeSetFeeRecipient', [tlFeeRecipient])
              }}
              executeFn={() => handleExecute('executeSetFeeRecipient')}
            >
              <Input label="New Fee Recipient" placeholder="0x…"
                value={tlFeeRecipient} onChange={e => setTlFeeRecipient(e.target.value)} />
            </TimelockCard>

            <TimelockCard
              label="Set Charity Wallet"
              actionKey="SET_CHARITY_WALLET"
              proposeFn={() => {
                handlePropose('proposeSetCharityWallet', [tlCharityWallet || ethers.ZeroAddress])
              }}
              executeFn={() => handleExecute('executeSetCharityWallet')}
            >
              <Input label="Charity Wallet (empty = redirect to fee recipient)" placeholder="0x… or leave blank"
                value={tlCharityWallet} onChange={e => setTlCharityWallet(e.target.value)} />
            </TimelockCard>

            <TimelockCard
              label="Set DEX Router"
              actionKey="SET_ROUTER"
              proposeFn={() => {
                if (!ethers.isAddress(tlRouter)) return toast('Invalid address', 'danger')
                handlePropose('proposeSetRouter', [tlRouter])
              }}
              executeFn={() => handleExecute('executeSetRouter')}
            >
              <Input label="New PancakeSwap Router Address" placeholder="0x…"
                value={tlRouter} onChange={e => setTlRouter(e.target.value)} />
            </TimelockCard>

          </div>
        </div>
      )}

      {/* Manager Access */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Manager Access
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Check Manager</div>
            <Input label="Address" placeholder="0x…"
              value={checkMgrAddr} onChange={e => setCheckMgrAddr(e.target.value)} />
            <Button onClick={handleCheckManager} variant="secondary" className="w-full">Check</Button>
            {checkMgrResult && <p className="text-xs text-muted">{checkMgrResult}</p>}
          </div>
          {adminState.isOwner && (
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Add / Remove Manager</div>
              <Input label="Address" placeholder="0x…"
                value={mgrAddr} onChange={e => setMgrAddr(e.target.value)} />
              <div className="flex gap-2">
                <Button onClick={handleAddManager} disabled={isSubmitting} variant="ok" size="sm" className="flex-1">Add</Button>
                <Button onClick={handleRemoveManager} disabled={isSubmitting} variant="danger" size="sm" className="flex-1">Remove</Button>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Ownership Transfer */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Ownership Transfer
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {adminState.isOwner && (
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Transfer Ownership</div>
              <p className="text-xs text-muted">Current: {shortAddress(adminState.owner)}</p>
              <Input label="New Owner" placeholder="0x…"
                value={newOwnerAddr} onChange={e => setNewOwnerAddr(e.target.value)} />
              <Button onClick={handleTransferOwnership} disabled={isSubmitting} className="w-full">Transfer</Button>
            </div>
          )}
          {adminState.isPending && (
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Accept Ownership</div>
              <p className="text-xs text-ok">You have pending ownership!</p>
              <Button onClick={handleAcceptOwnership} disabled={isSubmitting} className="w-full">Accept Ownership</Button>
            </div>
          )}
        </div>
      </div>

      {!adminState.isOwner && !adminState.isPending && (
        <div className="bg-surface border border-border rounded p-4 text-center">
          <Badge variant="muted">Admin write features restricted to owner</Badge>
        </div>
      )}
    </div>
  )
}
