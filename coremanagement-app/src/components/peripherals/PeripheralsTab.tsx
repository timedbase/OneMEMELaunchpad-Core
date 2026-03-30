import { useWeb3 } from '../../lib/web3-context'
import { Badge } from '../ui/Badge'

export default function PeripheralsTab() {
  const {
    factory,
    collector,
    creatorVault,
    maintenanceVault,
    oneMEMEBB,
    creatorVaultAddress,
    maintenanceVaultAddress,
    collectorAddress,
    oneMEMEBBAddress,
  } = useWeb3()

  const shortAddress = (addr: string) => (addr ? `${addr.slice(0, 6)}...${addr.slice(-4)}` : '—')

  interface ContractInfo {
    name: string
    address: string
    isLoaded: boolean
    description: string
  }

  const contracts: ContractInfo[] = [
    {
      name: 'Factory',
      address: factory?.target as string,
      isLoaded: !!factory,
      description: 'Launchpad Factory - main deployment contract',
    },
    {
      name: '1MEMEBB',
      address: oneMEMEBBAddress,
      isLoaded: !!oneMEMEBB,
      description: 'Buyback contract - triggers token buybacks',
    },
    {
      name: 'Collector',
      address: collectorAddress,
      isLoaded: !!collector,
      description: 'Revenue collector - distributes platform revenue',
    },
    {
      name: 'Creator Vault',
      address: creatorVaultAddress,
      isLoaded: !!creatorVault,
      description: 'Creator allocation vault - 2-of-3 multisig',
    },
    {
      name: 'Maintenance Vault',
      address: maintenanceVaultAddress,
      isLoaded: !!maintenanceVault,
      description: 'Maintenance fund vault - 2-of-3 multisig',
    },
  ]

  return (
    <div className="space-y-6">
      {/* Peripherals Summary */}
      <div>
        <div className="text-sm font-bold text-text mb-4 pb-2 border-b border-border">
          Loaded from Environment
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          {contracts.map(contract => (
            <div
              key={contract.name}
              className="bg-surface border border-border rounded-lg p-3 space-y-2"
            >
              <div className="flex items-center justify-between">
                <div className="font-semibold text-sm">{contract.name}</div>
                {contract.isLoaded ? (
                  <Badge variant="ok">✓ Loaded</Badge>
                ) : contract.address ? (
                  <Badge variant="warn">⚠ No ABI</Badge>
                ) : (
                  <Badge variant="muted">— Not set</Badge>
                )}
              </div>
              <p className="text-xs text-muted">{contract.description}</p>
              {contract.address && contract.address !== '0x0000000000000000000000000000000000000000' ? (
                <div className="font-mono text-xs text-text bg-bg p-2 rounded break-all">
                  {shortAddress(contract.address)}
                </div>
              ) : (
                <div className="text-xs text-muted p-2">No address configured</div>
              )}
            </div>
          ))}
        </div>
      </div>

      {/* Status Summary */}
      <div className="bg-surface border border-border rounded-lg p-4">
        <div className="text-sm font-bold text-text mb-3">Status</div>
        <div className="space-y-2 text-xs">
          <div className="flex justify-between">
            <span className="text-muted">Contracts Loaded:</span>
            <span className="font-semibold">{contracts.filter(c => c.isLoaded).length} / {contracts.length}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted">With Addresses:</span>
            <span className="font-semibold">{contracts.filter(c => c.address && c.address !== '0x0000000000000000000000000000000000000000').length} / {contracts.length}</span>
          </div>
          <div className="mt-3 p-2 bg-bg rounded text-muted text-xs">
            ℹ All contract addresses are loaded from environment variables (.env file). To configure different addresses, update your .env.local file.
          </div>
        </div>
      </div>
    </div>
  )
}
