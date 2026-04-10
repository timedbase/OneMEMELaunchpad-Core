import { useWeb3 } from '../../lib/web3-context'
import { config } from '../../lib/config'
import { Badge } from '../ui/Badge'

function row(label: string, addr: string) {
  const ok = !!addr && addr !== '0x'
  return (
    <div key={label} className="flex items-center justify-between text-xs">
      <span className="text-muted w-36">{label}</span>
      {ok ? (
        <span className="font-mono text-text truncate max-w-xs">{addr}</span>
      ) : (
        <Badge variant="warn">Not configured</Badge>
      )}
    </div>
  )
}

export function ContractSetupCard() {
  const { factory, bondingCurve } = useWeb3()

  const allLoaded = !!factory && !!bondingCurve

  return (
    <div className="bg-surface border border-border rounded-lg p-4 mb-6 space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-text">Contract Configuration</h3>
        {allLoaded
          ? <Badge variant="ok">Loaded from env</Badge>
          : <Badge variant="warn">Check .env.local</Badge>}
      </div>
      <div className="space-y-1.5">
        {row('Factory',           config.factoryAddress)}
        {row('Bonding Curve',     config.bondingCurveAddress)}
        {row('Vesting Wallet',    config.vestingWalletAddress)}
        {row('1MEMEBB',           config.oneMEMEBBAddress)}
        {row('Collector',         config.collectorAddress)}
        {row('Creator Vault',     config.creatorVaultAddress)}
        {row('Maintenance Vault', config.maintenanceVaultAddress)}
      </div>
    </div>
  )
}
