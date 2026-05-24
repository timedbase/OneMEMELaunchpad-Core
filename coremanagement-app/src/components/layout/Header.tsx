import { useState, useRef, useEffect } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { CHAINS, SUPPORTED_CHAIN_IDS } from '../../lib/config'
import { Button } from '../ui/Button'

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

function ChainSwitcher() {
  const { activeChain, isWrongNetwork, switchToChain } = useWeb3()
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [])

  const label = isWrongNetwork
    ? 'Wrong Network'
    : (activeChain?.shortName ?? 'Select Chain')

  return (
    <div className="relative" ref={ref}>
      <button
        onClick={() => setOpen(o => !o)}
        className={`
          flex items-center gap-1.5 px-2 py-1 rounded text-[11px] font-semibold border cursor-pointer
          transition-colors duration-150 bg-transparent
          ${isWrongNetwork
            ? 'text-danger border-danger/30 hover:bg-danger/10'
            : 'text-ok border-ok/30 hover:bg-ok/10'}
        `}
      >
        <span className={`w-1.5 h-1.5 rounded-full ${isWrongNetwork ? 'bg-danger' : 'bg-ok'}`} />
        {label}
        <svg className={`w-2.5 h-2.5 opacity-60 transition-transform ${open ? 'rotate-180' : ''}`} viewBox="0 0 10 6" fill="currentColor">
          <path d="M0 0l5 6 5-6H0z" />
        </svg>
      </button>

      {open && (
        <div className="absolute right-0 top-full mt-1 z-50 w-40 bg-surface border border-border rounded shadow-lg py-1 text-xs">
          <div className="px-3 py-1 text-[10px] uppercase tracking-widest text-muted/50 font-semibold">
            Switch Network
          </div>
          {SUPPORTED_CHAIN_IDS.map(id => {
            const chain   = CHAINS[id]
            const current = !isWrongNetwork && activeChain?.chainId === id
            return (
              <button
                key={id}
                onClick={() => { switchToChain(id); setOpen(false) }}
                className={`
                  w-full flex items-center gap-2 px-3 py-1.5 text-left cursor-pointer
                  border-none bg-transparent transition-colors duration-100
                  ${current
                    ? 'text-accent font-semibold'
                    : 'text-muted hover:text-text hover:bg-white/5'}
                `}
              >
                <span className={`w-1.5 h-1.5 rounded-full shrink-0 ${current ? 'bg-accent' : 'bg-muted/30'}`} />
                {chain.name}
                {current && <span className="ml-auto text-[9px] text-accent">active</span>}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

interface HeaderProps {
  pageTitle:    string
  onMenuToggle: () => void
}

export default function Header({ pageTitle, onMenuToggle }: HeaderProps) {
  const { account, chainId, isWrongNetwork, isConnecting, connectWallet, disconnectWallet } = useWeb3()

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

        <div className="flex items-center gap-2">
          <ChainSwitcher />

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
          Chain {chainId} not supported — use the network switcher to switch to {SUPPORTED_CHAIN_IDS.map(id => CHAINS[id].name).join(' or ')}
        </div>
      )}
    </>
  )
}
