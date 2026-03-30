import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Badge } from '../ui/Badge'
import { shortenAddress } from '../../lib/utils'

export default function Header() {
  const { account, chainId, isConnecting, connectWallet, disconnectWallet } = useWeb3()

  const chainName = (id: number | null) => {
    if (id === 56) return 'BSC Mainnet'
    if (id === 97) return 'BSC Testnet'
    return id ? `Chain ${id}` : 'Unknown'
  }

  return (
    <header className="flex items-center justify-between flex-wrap gap-2 px-4 py-4 border-b border-border mb-5">
      <div className="text-lg font-bold tracking-tight">
        OneMEME <span className="text-accent">Core Management</span>
      </div>
      <div className="header-right flex items-center gap-2 flex-wrap">
        <Button variant="secondary" size="sm">
          ↻ Refresh
        </Button>
        {chainId && <Badge>{chainName(chainId)}</Badge>}
        {account ? (
          <>
            <Badge variant="ok">{shortenAddress(account)}</Badge>
            <Button size="sm" onClick={disconnectWallet} variant="secondary">
              Disconnect
            </Button>
          </>
        ) : (
          <Button size="sm" onClick={connectWallet} disabled={isConnecting}>
            {isConnecting ? 'Connecting...' : 'Connect Wallet'}
          </Button>
        )}
      </div>
    </header>
  )
}
