import { useWeb3 } from '../../lib/web3-context'
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
  const { factory, bondingCurve, activeChain } = useWeb3()

  const allLoaded = !!factory && !!bondingCurve
  const c = activeChain?.contracts

  return (
    <div className="bg-surface border border-border rounded-lg p-4 mb-6 space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-text">Contract Configuration</h3>
        <div className="flex items-center gap-1.5">
          {activeChain && <Badge variant="ok">{activeChain.shortName}</Badge>}
          {allLoaded
            ? <Badge variant="ok">Loaded</Badge>
            : <Badge variant="warn">Not configured</Badge>}
        </div>
      </div>
      <div className="space-y-1.5">
        {row('Factory',           c?.factory          ?? '')}
        {row('Bonding Curve',     c?.bondingCurve     ?? '')}
        {row('Vesting Wallet',    c?.vestingWallet    ?? '')}
        {row('1MEMEBB',           c?.oneMEMEBB        ?? '')}
        {row('Collector',         c?.collector        ?? '')}
        {row('Creator Vault',     c?.creatorVault     ?? '')}
        {row('Maintenance Vault', c?.maintenanceVault ?? '')}
        {row('1Dex',              c?.oneDex           ?? '')}
      </div>
    </div>
  )
}
