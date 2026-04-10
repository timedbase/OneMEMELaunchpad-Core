import { useState } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Badge } from '../ui/Badge'
import BBPanel from './BBPanel'
import CollectorPanel from './CollectorPanel'
import VaultPanel from './VaultPanel'
import VestingPanel from './VestingPanel'

type SubTab = 'bb' | 'collector' | 'creator-vault' | 'maintenance-vault' | 'vesting'

const TABS: { id: SubTab; label: string }[] = [
  { id: 'bb',               label: '1MEMEBB'          },
  { id: 'collector',        label: 'Collector'         },
  { id: 'creator-vault',    label: 'Creator Vault'     },
  { id: 'maintenance-vault',label: 'Maintenance Vault' },
  { id: 'vesting',          label: 'Vesting'           },
]

export default function PeripheralsTab() {
  const {
    oneMEMEBB,
    collector,
    creatorVault,
    maintenanceVault,
    vestingWallet,
    oneMEMEBBAddress,
    collectorAddress,
    creatorVaultAddress,
    maintenanceVaultAddress,
  } = useWeb3()

  const [active, setActive] = useState<SubTab>('bb')

  function statusFor(id: SubTab) {
    if (id === 'bb')                return !!oneMEMEBB
    if (id === 'collector')         return !!collector
    if (id === 'creator-vault')     return !!creatorVault
    if (id === 'maintenance-vault') return !!maintenanceVault
    if (id === 'vesting')           return !!vestingWallet
    return false
  }

  function addressFor(id: SubTab) {
    if (id === 'bb')                return oneMEMEBBAddress
    if (id === 'collector')         return collectorAddress
    if (id === 'creator-vault')     return creatorVaultAddress
    if (id === 'maintenance-vault') return maintenanceVaultAddress
    return ''
  }

  const loaded = TABS.filter(t => statusFor(t.id)).length

  return (
    <div className="space-y-4">
      {/* Status bar */}
      <div className="bg-surface border border-border rounded p-3 flex items-center justify-between text-xs">
        <span className="text-muted">{loaded} / {TABS.length} peripherals loaded</span>
        <div className="flex gap-2">
          {TABS.map(t => (
            <Badge key={t.id} variant={statusFor(t.id) ? 'ok' : 'muted'}>
              {t.label}
            </Badge>
          ))}
        </div>
      </div>

      {/* Sub-tab navigation */}
      <div className="flex gap-1 border-b border-border pb-2 flex-wrap">
        {TABS.map(t => {
          const isLoaded = statusFor(t.id)
          const addr = addressFor(t.id)
          return (
            <button
              key={t.id}
              onClick={() => setActive(t.id)}
              className={[
                'px-3 py-1.5 text-xs font-medium rounded-t transition-colors',
                active === t.id
                  ? 'bg-accent text-bg'
                  : 'text-muted hover:text-text',
              ].join(' ')}
            >
              {t.label}
              {!isLoaded && addr && <span className="ml-1 text-warn">⚠</span>}
              {!addr && <span className="ml-1 opacity-40">–</span>}
            </button>
          )
        })}
      </div>

      {/* Panel content */}
      <div>
        {active === 'bb'                && <BBPanel />}
        {active === 'collector'         && <CollectorPanel />}
        {active === 'creator-vault'     && <VaultPanel contract={creatorVault} label="Creator Vault" />}
        {active === 'maintenance-vault' && <VaultPanel contract={maintenanceVault} label="Maintenance Vault" />}
        {active === 'vesting'           && <VestingPanel />}
      </div>
    </div>
  )
}
