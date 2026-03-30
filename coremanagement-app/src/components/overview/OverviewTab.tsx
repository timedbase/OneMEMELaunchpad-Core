import { useState, useEffect } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { ContractSetupCard } from '../common/ContractSetupCard'
import { formatEther, ZeroAddress } from 'ethers'
import { shortenAddress } from '../../lib/utils'

interface Stats {
  label: string
  value: string
  address?: string
}

function StatCard({ label, value, address }: Stats) {
  return (
    <div className="bg-surface border border-border rounded p-3">
      <div className="text-xs text-muted mb-1">{label}</div>
      <div className="font-mono text-sm text-text flex justify-between items-center">
        <span>{value}</span>
        {address && (
          <button
            className="text-muted hover:text-accent text-xs ml-2"
            onClick={() => navigator.clipboard.writeText(address)}
            title="Copy"
          >
            ⎘
          </button>
        )}
      </div>
    </div>
  )
}

export default function OverviewTab() {
  const { factory, bondingCurve, toast } = useWeb3()
  const [factoryStats, setFactoryStats] = useState<Stats[] | null>(null)
  const [bcStats, setBcStats] = useState<Stats[] | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    const loadStats = async () => {
      if (!factory || !bondingCurve) return

      setLoading(true)
      try {
        const [
          owner,
          pending,
          fee,
          vBNB,
          migTarget,
          stdImpl,
          taxImpl,
          reflImpl,
          vestingWalletAddr,
          bcFactory,
          bcDeployer,
          router,
          feeRec,
          charity,
          platFee,
          charFee,
          total,
        ] = await Promise.all([
          factory.owner(),
          factory.pendingOwner(),
          factory.creationFee(),
          factory.defaultVirtualBNB(),
          factory.defaultMigrationTarget(),
          factory.standardImpl(),
          factory.taxImpl(),
          factory.reflectionImpl(),
          factory.vestingWallet(),
          bondingCurve.factory(),
          bondingCurve.deployer(),
          bondingCurve.pancakeRouter(),
          bondingCurve.feeRecipient(),
          bondingCurve.charityWallet(),
          bondingCurve.platformFee(),
          bondingCurve.charityFee(),
          bondingCurve.totalTokensLaunched(),
        ])

        setFactoryStats([
          { label: 'Owner', value: shortenAddress(owner), address: owner },
          ...(pending && pending !== ZeroAddress
            ? [{ label: 'Pending Owner', value: shortenAddress(pending), address: pending }]
            : []),
          { label: 'Creation Fee', value: formatEther(fee) + ' BNB' },
          { label: 'Virtual BNB', value: formatEther(vBNB) + ' BNB' },
          { label: 'Migration Target', value: formatEther(migTarget) + ' BNB' },
          { label: 'Standard Impl', value: shortenAddress(stdImpl), address: stdImpl },
          { label: 'Tax Impl', value: shortenAddress(taxImpl), address: taxImpl },
          { label: 'Reflection Impl', value: shortenAddress(reflImpl), address: reflImpl },
          {
            label: 'Vesting Wallet',
            value: vestingWalletAddr !== ZeroAddress ? shortenAddress(vestingWalletAddr) : '⚠ Not set',
            address: vestingWalletAddr !== ZeroAddress ? vestingWalletAddr : undefined,
          },
        ])

        setBcStats([
          {
            label: 'Factory',
            value: bcFactory !== ZeroAddress ? shortenAddress(bcFactory) : '⚠ Not set',
            address: bcFactory !== ZeroAddress ? bcFactory : undefined,
          },
          { label: 'Deployer', value: shortenAddress(bcDeployer), address: bcDeployer },
          { label: 'Router', value: shortenAddress(router), address: router },
          { label: 'Fee Recipient', value: shortenAddress(feeRec), address: feeRec },
          {
            label: 'Charity Wallet',
            value: charity !== ZeroAddress ? shortenAddress(charity) : '(none)',
            address: charity !== ZeroAddress ? charity : undefined,
          },
          {
            label: 'Platform Fee',
            value: (Number(platFee) / 100).toFixed(2) + '% (' + platFee.toString() + ' BPS)',
          },
          {
            label: 'Charity Fee',
            value: (Number(charFee) / 100).toFixed(2) + '% (' + charFee.toString() + ' BPS)',
          },
          { label: 'Total Launched', value: total.toString() + ' tokens' },
        ])
      } catch (err: any) {
        toast(`Error loading stats: ${err.message}`, 'danger')
      } finally {
        setLoading(false)
      }
    }

    loadStats()
  }, [factory, bondingCurve, toast])

  return (
    <div className="space-y-6">
      <ContractSetupCard />

      {!factory || !bondingCurve ? (
        <div className="bg-surface border border-border rounded-lg p-8 text-center text-muted">
          Load a factory address to begin
        </div>
      ) : (
        <>
          <div>
            <h3 className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              LaunchpadFactory
            </h3>
            {loading ? (
              <div className="text-muted text-sm">Loading...</div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                {factoryStats?.map((stat, i) => (
                  <StatCard key={i} {...stat} />
                ))}
              </div>
            )}
          </div>

          <div>
            <h3 className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
              BondingCurve
            </h3>
            {loading ? (
              <div className="text-muted text-sm">Loading...</div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                {bcStats?.map((stat, i) => (
                  <StatCard key={i} {...stat} />
                ))}
              </div>
            )}
          </div>
        </>
      )}
    </div>
  )
}
