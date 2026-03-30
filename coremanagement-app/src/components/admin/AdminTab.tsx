import { useState, useEffect } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

interface AdminState {
  owner: string
  pendingOwner: string
  isOwner: boolean
  isPending: boolean
}

export default function AdminTab() {
  const { factory, account, toast } = useWeb3()
  const [adminState, setAdminState] = useState<AdminState | null>(null)
  const [loading, setLoading] = useState(false)

  // Forms
  const [newFee, setNewFee] = useState('')
  const [newVBNB, setNewVBNB] = useState('')
  const [newMigTarget, setNewMigTarget] = useState('')
  const [rescueRecipient, setRescueRecipient] = useState('')
  const [checkMgrAddr, setCheckMgrAddr] = useState('')
  const [mgrAddr, setMgrAddr] = useState('')
  const [newOwnerAddr, setNewOwnerAddr] = useState('')

  const [checkMgrResult, setCheckMgrResult] = useState('')
  const [isSubmitting, setIsSubmitting] = useState(false)

  const loadAdminData = async () => {
    if (!factory) return
    setLoading(true)
    try {
      const [owner, pending] = await Promise.all([factory.owner(), factory.pendingOwner()])
      setAdminState({
        owner,
        pendingOwner: pending,
        isOwner: account ? owner.toLowerCase() === account.toLowerCase() : false,
        isPending: account && pending && account.toLowerCase() === pending.toLowerCase(),
      })
    } catch (e) {
      toast(`Error loading admin data: ${e}`, 'danger')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    loadAdminData()
  }, [factory, account])

  const shortAddress = (addr: string) => `${addr.slice(0, 6)}...${addr.slice(-4)}`

  const handleSetCreationFee = async () => {
    if (!factory || !adminState?.isOwner) {
      toast('Owner access required', 'danger')
      return
    }
    if (!newFee) {
      toast('Enter fee amount', 'danger')
      return
    }

    setIsSubmitting(true)
    try {
      const feeWei = ethers.parseEther(newFee)
      const tx = await factory.setCreationFee(feeWei)
      toast('Setting fee...', 'warn')
      await tx.wait()
      toast('Creation fee updated!', 'ok')
      setNewFee('')
      loadAdminData()
    } catch (e: any) {
      toast(`Failed: ${e.reason || e.message || e}`, 'danger')
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleSetDefaultParams = async () => {
    if (!factory || !adminState?.isOwner) {
      toast('Owner access required', 'danger')
      return
    }
    if (!newVBNB || !newMigTarget) {
      toast('Enter both parameters', 'danger')
      return
    }

    setIsSubmitting(true)
    try {
      const vbnbWei = ethers.parseEther(newVBNB)
      const mtWei = ethers.parseEther(newMigTarget)
      const tx = await factory.setDefaultParams(vbnbWei, mtWei)
      toast('Setting params...', 'warn')
      await tx.wait()
      toast('Default params updated!', 'ok')
      setNewVBNB('')
      setNewMigTarget('')
      loadAdminData()
    } catch (e: any) {
      toast(`Failed: ${e.reason || e.message || e}`, 'danger')
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleRescueBNB = async () => {
    if (!factory || !adminState?.isOwner) {
      toast('Owner access required', 'danger')
      return
    }
    if (!ethers.isAddress(rescueRecipient)) {
      toast('Invalid recipient address', 'danger')
      return
    }

    setIsSubmitting(true)
    try {
      const tx = await factory.rescueBNB(rescueRecipient)
      toast('Rescuing BNB...', 'warn')
      await tx.wait()
      toast('BNB rescued!', 'ok')
      setRescueRecipient('')
      loadAdminData()
    } catch (e: any) {
      toast(`Failed: ${e.reason || e.message || e}`, 'danger')
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleCheckManager = async () => {
    if (!factory) {
      toast('Factory not loaded', 'danger')
      return
    }
    if (!ethers.isAddress(checkMgrAddr)) {
      toast('Invalid address', 'danger')
      return
    }

    try {
      const isManager = await factory.isManager(checkMgrAddr)
      setCheckMgrResult(isManager ? 'Is a manager' : 'Not a manager')
    } catch (e: any) {
      setCheckMgrResult(`Error: ${e.message || e}`)
    }
  }

  const handleAddManager = async () => {
    if (!factory || !adminState?.isOwner) {
      toast('Owner access required', 'danger')
      return
    }
    if (!ethers.isAddress(mgrAddr)) {
      toast('Invalid address', 'danger')
      return
    }

    setIsSubmitting(true)
    try {
      const tx = await factory.addManager(mgrAddr)
      toast('Adding manager...', 'warn')
      await tx.wait()
      toast('Manager added!', 'ok')
      setMgrAddr('')
      loadAdminData()
    } catch (e: any) {
      toast(`Failed: ${e.reason || e.message || e}`, 'danger')
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleRemoveManager = async () => {
    if (!factory || !adminState?.isOwner) {
      toast('Owner access required', 'danger')
      return
    }
    if (!ethers.isAddress(mgrAddr)) {
      toast('Invalid address', 'danger')
      return
    }

    setIsSubmitting(true)
    try {
      const tx = await factory.removeManager(mgrAddr)
      toast('Removing manager...', 'warn')
      await tx.wait()
      toast('Manager removed!', 'ok')
      setMgrAddr('')
      loadAdminData()
    } catch (e: any) {
      toast(`Failed: ${e.reason || e.message || e}`, 'danger')
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleTransferOwnership = async () => {
    if (!factory || !adminState?.isOwner) {
      toast('Owner access required', 'danger')
      return
    }
    if (!ethers.isAddress(newOwnerAddr)) {
      toast('Invalid address', 'danger')
      return
    }

    setIsSubmitting(true)
    try {
      const tx = await factory.transferOwnership(newOwnerAddr)
      toast('Transferring ownership...', 'warn')
      await tx.wait()
      toast('Ownership transfer initiated (pending acceptance)', 'ok')
      setNewOwnerAddr('')
      loadAdminData()
    } catch (e: any) {
      toast(`Failed: ${e.reason || e.message || e}`, 'danger')
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleAcceptOwnership = async () => {
    if (!factory || !adminState?.isPending) {
      toast('Must have pending ownership', 'danger')
      return
    }

    setIsSubmitting(true)
    try {
      const tx = await factory.acceptOwnership()
      toast('Accepting ownership...', 'warn')
      await tx.wait()
      toast('Ownership accepted!', 'ok')
      loadAdminData()
    } catch (e: any) {
      toast(`Failed: ${e.reason || e.message || e}`, 'danger')
    } finally {
      setIsSubmitting(false)
    }
  }

  if (!adminState) {
    return (
      <div className="text-center py-20 text-muted">
        {loading ? 'Loading admin data...' : 'Load a factory address first.'}
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
        </div>
      </div>

      {/* Quick Actions */}
      {adminState.isOwner && (
        <div>
          <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
            Quick Actions <span className="text-xs text-muted font-normal">(no timelock)</span>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {/* Set Creation Fee */}
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Set Creation Fee</div>
              <div className="space-y-2">
                <Input
                  label="Fee (BNB)"
                  type="number"
                  placeholder="0.01"
                  step="0.001"
                  min="0"
                  value={newFee}
                  onChange={e => setNewFee(e.target.value)}
                />
              </div>
              <Button onClick={handleSetCreationFee} disabled={isSubmitting} className="w-full" variant="default">
                Set Fee
              </Button>
            </div>

            {/* Set Default Params */}
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Set Default Params</div>
              <div className="space-y-2">
                <Input
                  label="Virtual BNB (BNB)"
                  type="number"
                  placeholder="1.0"
                  step="0.1"
                  min="0"
                  value={newVBNB}
                  onChange={e => setNewVBNB(e.target.value)}
                />
                <Input
                  label="Migration Target (BNB)"
                  type="number"
                  placeholder="50"
                  step="1"
                  min="0"
                  value={newMigTarget}
                  onChange={e => setNewMigTarget(e.target.value)}
                />
              </div>
              <Button onClick={handleSetDefaultParams} disabled={isSubmitting} className="w-full" variant="default">
                Set Params
              </Button>
            </div>

            {/* Rescue BNB */}
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Rescue BNB</div>
              <div className="space-y-2">
                <Input
                  label="Recipient"
                  placeholder="0x…"
                  value={rescueRecipient}
                  onChange={e => setRescueRecipient(e.target.value)}
                />
              </div>
              <Button
                onClick={handleRescueBNB}
                disabled={isSubmitting}
                className="w-full"
                variant="danger"
              >
                Rescue BNB
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* Manager Access */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Manager Access
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {/* Check Manager */}
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <div className="font-semibold text-sm">Check Manager</div>
            <div className="space-y-2">
              <Input
                label="Address"
                placeholder="0x…"
                value={checkMgrAddr}
                onChange={e => setCheckMgrAddr(e.target.value)}
              />
            </div>
            <Button onClick={handleCheckManager} variant="secondary" className="w-full">
              Check
            </Button>
            {checkMgrResult && <p className="text-xs text-muted">{checkMgrResult}</p>}
          </div>

          {/* Add / Remove Manager */}
          {adminState.isOwner && (
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Add / Remove Manager</div>
              <div className="space-y-2">
                <Input
                  label="Address"
                  placeholder="0x…"
                  value={mgrAddr}
                  onChange={e => setMgrAddr(e.target.value)}
                />
              </div>
              <div className="flex gap-2">
                <Button
                  onClick={handleAddManager}
                  disabled={isSubmitting}
                  variant="ok"
                  size="sm"
                  className="flex-1"
                >
                  Add
                </Button>
                <Button
                  onClick={handleRemoveManager}
                  disabled={isSubmitting}
                  variant="danger"
                  size="sm"
                  className="flex-1"
                >
                  Remove
                </Button>
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
              <div className="space-y-2">
                <Input
                  label="New Owner"
                  placeholder="0x…"
                  value={newOwnerAddr}
                  onChange={e => setNewOwnerAddr(e.target.value)}
                />
              </div>
              <Button onClick={handleTransferOwnership} disabled={isSubmitting} className="w-full">
                Transfer
              </Button>
            </div>
          )}

          {adminState.isPending && (
            <div className="bg-surface border border-border rounded p-4 space-y-3">
              <div className="font-semibold text-sm">Accept Ownership</div>
              <p className="text-xs text-ok">You have pending ownership!</p>
              <Button onClick={handleAcceptOwnership} disabled={isSubmitting} className="w-full">
                Accept Ownership
              </Button>
            </div>
          )}
        </div>
      </div>

      {!adminState.isOwner && !adminState.isPending && (
        <div className="bg-surface border border-warn border-opacity-30 rounded p-4 text-center">
          <Badge variant="muted">Admin features restricted to owner</Badge>
        </div>
      )}
    </div>
  )
}
