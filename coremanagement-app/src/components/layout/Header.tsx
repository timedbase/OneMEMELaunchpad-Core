import { useWeb3 } from '../../lib/web3-context'
import { CHAINS, SUPPORTED_CHAIN_IDS } from '../../lib/config'
import { Button } from '../ui/Button'
import { Badge } from '../ui/Badge'

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

interface HeaderProps {
  pageTitle:    string
  onMenuToggle: () => void
}

export default function Header({ pageTitle, onMenuToggle }: HeaderProps) {
  const {
    account, chainId, activeChain,
    isConnecting, isWrongNetwork,
    connectWallet, disconnectWallet, switchToChain,
  } = useWeb3()

  return (
    <>
      <header className="flex items-center justify-between gap-4 px-4 h-11 border-b border-border bg-surface/60 backdrop-blur-sm shrink-0">
        <div className="flex items-center gap-2">
          <button
            className="md:hidden text-muted hover:text-text transition-colors cursor-pointer bg-transparent border-none p-1 -ml-1"
            onClick={onMenuToggle}
            aria-label="Toggle menu"
          >
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          </button>
          <span className="text-xs font-semibold text-text">{pageTitle}</span>
        </div>

        <div className="flex items-center gap-1.5">
          {/* Chain badge */}
          {activeChain && !isWrongNetwork && (
            <Badge variant="ok">{activeChain.shortName}</Badge>
          )}
          {isWrongNetwork && (
            <>
              <Badge variant="danger">Wrong Network</Badge>
              {/* Quick-switch buttons for each supported chain */}
              {SUPPORTED_CHAIN_IDS.map(id => (
                <Button
                  key={id}
                  size="sm"
                  variant="secondary"
                  onClick={() => switchToChain(id)}
                >
                  Switch to {CHAINS[id].shortName}
                </Button>
              ))}
            </>
          )}

          {account ? (
            <div className="flex items-center gap-1.5">
              <span className="text-[11px] font-mono text-muted bg-bg px-2 py-1 rounded border border-border">
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

      {isWrongNetwork && chainId && (
        <div className="bg-danger/10 border-b border-danger/20 text-danger text-[11px] text-center py-1.5 px-4 font-medium shrink-0">
          Chain {chainId} not supported — switch to {SUPPORTED_CHAIN_IDS.map(id => CHAINS[id].name).join(' or ')}
        </div>
      )}
    </>
  )
}
