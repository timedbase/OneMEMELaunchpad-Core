import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Badge } from '../ui/Badge'

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

interface HeaderProps {
  pageTitle: string
  onMenuToggle: () => void
}

export default function Header({ pageTitle, onMenuToggle }: HeaderProps) {
  const { account, chainId, isConnecting, isWrongNetwork, connectWallet, disconnectWallet } = useWeb3()

  return (
    <>
      <header className="flex items-center justify-between gap-4 px-5 h-14 border-b border-border bg-surface/60 backdrop-blur-sm shrink-0">
        <div className="flex items-center gap-3">
          <button
            className="md:hidden text-muted hover:text-text transition-colors cursor-pointer bg-transparent border-none p-1 -ml-1"
            onClick={onMenuToggle}
            aria-label="Toggle menu"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          </button>
          <span className="text-sm font-semibold text-text">{pageTitle}</span>
        </div>

        <div className="flex items-center gap-2">
          {chainId && !isWrongNetwork && <Badge variant="ok">BSC Mainnet</Badge>}
          {isWrongNetwork && <Badge variant="danger">Wrong Network</Badge>}
          {account ? (
            <div className="flex items-center gap-2">
              <span className="text-xs font-mono text-muted bg-bg px-2.5 py-1.5 rounded-md border border-border">
                {shortAddr(account)}
              </span>
              <Button size="sm" variant="secondary" onClick={disconnectWallet}>
                Disconnect
              </Button>
            </div>
          ) : (
            <Button size="sm" onClick={connectWallet} disabled={isConnecting}>
              {isConnecting ? 'Connecting…' : 'Connect Wallet'}
            </Button>
          )}
        </div>
      </header>

      {isWrongNetwork && (
        <div className="bg-danger/10 border-b border-danger/20 text-danger text-xs text-center py-2 px-4 font-medium shrink-0">
          Wrong network — please switch to BSC Mainnet (Chain ID 56)
        </div>
      )}
    </>
  )
}
