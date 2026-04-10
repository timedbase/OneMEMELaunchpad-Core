import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Badge } from '../ui/Badge'
import { shortenAddress } from '../../lib/utils'

export default function Header() {
  const { account, chainId, isConnecting, isWrongNetwork, connectWallet, disconnectWallet } = useWeb3()

  return (
    <>
      <header className="flex items-center justify-between flex-wrap gap-2 px-4 py-4 border-b border-border mb-5">
        <div className="text-lg font-bold tracking-tight">
          OneMEME <span className="text-accent">Core Management</span>
        </div>
        <div className="header-right flex items-center gap-2 flex-wrap">
          <Button variant="secondary" size="sm">↻ Refresh</Button>
          {chainId && !isWrongNetwork && <Badge variant="ok">BSC Mainnet</Badge>}
          {account ? (
            <>
              <Badge variant="ok">{shortenAddress(account)}</Badge>
              <Button size="sm" onClick={disconnectWallet} variant="secondary">Disconnect</Button>
            </>
          ) : (
            <Button size="sm" onClick={connectWallet} disabled={isConnecting}>
              {isConnecting ? 'Connecting…' : 'Connect Wallet'}
            </Button>
          )}
        </div>
      </header>

      {isWrongNetwork && (
        <div className="bg-danger text-white text-xs text-center py-2 px-4 font-semibold">
          Wrong network — please switch to BSC Mainnet (Chain ID 56). Click Connect Wallet to auto-switch.
        </div>
      )}
    </>
  )
}
