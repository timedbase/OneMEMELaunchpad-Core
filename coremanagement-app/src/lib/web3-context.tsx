import {
  createContext,
  useContext,
  useCallback,
  useState,
  useEffect,
  useRef,
  ReactNode,
} from 'react'
import { BrowserProvider, Contract, ZeroAddress, JsonRpcProvider } from 'ethers'
import {
  CHAINS,
  SUPPORTED_CHAIN_IDS,
  DEFAULT_CHAIN,
  getChainConfig,
  ChainConfig,
} from './config'
import {
  FACTORY_ABI,
  BC_ABI,
  VW_ABI,
  VAULT_ABI,
  COLLECTOR_ABI,
  ONE_MEMEBB_ABI,
  ONEDEX_ABI,
} from './contracts'

export interface Web3ContextType {
  provider:     BrowserProvider | null
  signer:       any | null
  account:      string | null
  chainId:      number | null
  activeChain:  ChainConfig | null
  isConnected:  boolean
  isConnecting: boolean
  isWrongNetwork: boolean

  factory:          Contract | null
  bondingCurve:     Contract | null
  vestingWallet:    Contract | null
  creatorVault:     Contract | null
  maintenanceVault: Contract | null
  collector:        Contract | null
  oneMEMEBB:        Contract | null
  oneDex:           Contract | null

  creatorVaultAddress:     string
  maintenanceVaultAddress: string
  oneMEMEBBAddress:        string
  collectorAddress:        string
  oneDexAddress:           string

  connectWallet:    () => Promise<void>
  disconnectWallet: () => void
  switchToChain:    (chainId: number) => Promise<boolean>
  toast:            (message: string, type?: 'ok' | 'warn' | 'danger') => void
  toasts:           { id: number; message: string; type: 'ok' | 'warn' | 'danger' }[]
  dismissToast:     (id: number) => void
}

const Web3Context = createContext<Web3ContextType | null>(null)

export function Web3Provider({ children }: { children: ReactNode }) {
  const [provider,       setProvider]       = useState<BrowserProvider | null>(null)
  const [signer,         setSigner]         = useState<any | null>(null)
  const [account,        setAccount]        = useState<string | null>(null)
  const [chainId,        setChainId]        = useState<number | null>(null)
  const [activeChain,    setActiveChain]    = useState<ChainConfig | null>(null)
  const [isConnecting,   setIsConnecting]   = useState(false)
  const [isWrongNetwork, setIsWrongNetwork] = useState(false)

  const [factory,          setFactory]          = useState<Contract | null>(null)
  const [bondingCurve,     setBondingCurve]     = useState<Contract | null>(null)
  const [vestingWallet,    setVestingWallet]    = useState<Contract | null>(null)
  const [creatorVault,     setCreatorVault]     = useState<Contract | null>(null)
  const [maintenanceVault, setMaintenanceVault] = useState<Contract | null>(null)
  const [collector,        setCollector]        = useState<Contract | null>(null)
  const [oneMEMEBB,        setOneMEMEBB]        = useState<Contract | null>(null)
  const [oneDex,           setOneDex]           = useState<Contract | null>(null)

  const [toasts, setToasts] = useState<{ id: number; message: string; type: 'ok' | 'warn' | 'danger' }[]>([])
  const toastIdRef = useRef(0)

  const dismissToast = useCallback((id: number) => {
    setToasts(prev => prev.filter(t => t.id !== id))
  }, [])

  const toast = useCallback((message: string, type: 'ok' | 'warn' | 'danger' = 'ok') => {
    const id = ++toastIdRef.current
    setToasts(prev => [...prev, { id, message, type }])
    setTimeout(() => setToasts(prev => prev.filter(t => t.id !== id)), 4500)
  }, [])

  const switchToChain = useCallback(async (targetChainId: number): Promise<boolean> => {
    const ethereum = (window as any).ethereum
    if (!ethereum) return false
    const chain = CHAINS[targetChainId]
    if (!chain) return false
    try {
      await ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: '0x' + targetChainId.toString(16) }],
      })
      return true
    } catch (err: any) {
      if (err.code === 4902) {
        try {
          await ethereum.request({
            method: 'wallet_addEthereumChain',
            params: [{
              chainId:           '0x' + targetChainId.toString(16),
              chainName:         chain.name,
              nativeCurrency:    chain.nativeCurrency,
              rpcUrls:           [chain.rpc],
              blockExplorerUrls: [chain.explorer],
            }],
          })
          return true
        } catch { return false }
      }
      return false
    }
  }, [])

  const connectWallet = useCallback(async () => {
    const ethereum = (window as any).ethereum
    if (!ethereum) { toast('No wallet detected', 'danger'); return }

    setIsConnecting(true)
    try {
      const accounts     = await ethereum.request({ method: 'eth_requestAccounts' })
      const newProvider  = new BrowserProvider(ethereum)
      const network      = await newProvider.getNetwork()
      const connectedId  = Number(network.chainId)
      const supported    = SUPPORTED_CHAIN_IDS.includes(connectedId)

      if (!supported) {
        setIsWrongNetwork(true)
        toast(`Chain ${connectedId} not supported — switch to ${Object.values(CHAINS).map(c => c.shortName).join(' or ')}`, 'warn')
        return
      }

      const newSigner = await newProvider.getSigner()
      setProvider(newProvider)
      setSigner(newSigner)
      setAccount(accounts[0])
      setChainId(connectedId)
      setActiveChain(getChainConfig(connectedId))
      setIsWrongNetwork(false)
      toast(`Connected on ${CHAINS[connectedId].shortName}`, 'ok')
    } catch (err: any) {
      toast(`Connection failed: ${err.message}`, 'danger')
    } finally {
      setIsConnecting(false)
    }
  }, [toast])

  const disconnectWallet = useCallback(() => {
    setSigner(null)
    setAccount(null)
    setChainId(null)
    setActiveChain(null)
    setIsWrongNetwork(false)
    toast('Wallet disconnected', 'ok')
  }, [toast])

  // Re-initialize all contracts whenever signer or chainId changes
  useEffect(() => {
    const chain    = (chainId ? getChainConfig(chainId) : null) ?? DEFAULT_CHAIN
    const rpc      = chain.rpc
    const p        = signer ?? new JsonRpcProvider(rpc)
    const addrs    = chain.contracts

    // Reset all
    setFactory(null); setBondingCurve(null); setVestingWallet(null)
    setCreatorVault(null); setMaintenanceVault(null)
    setCollector(null); setOneMEMEBB(null); setOneDex(null)

    const init = async () => {
      try {
        if (addrs.factory) {
          const f = new Contract(addrs.factory, FACTORY_ABI, p)
          setFactory(f)
          const bcAddr = await f.migrator()
          if (bcAddr && bcAddr !== ZeroAddress)
            setBondingCurve(new Contract(bcAddr, BC_ABI, p))
          const vwAddr = await f.vestingWallet()
          if (vwAddr && vwAddr !== ZeroAddress)
            setVestingWallet(new Contract(vwAddr, VW_ABI, p))
        }
      } catch (err) { console.error('Factory init error:', err) }

      const tryInit = (addr: string, abi: any, set: (c: Contract) => void, label: string) => {
        if (!addr) return
        try { set(new Contract(addr, abi, p)) }
        catch (err) { console.warn(`${label} init failed:`, err) }
      }

      tryInit(addrs.creatorVault,     VAULT_ABI,       setCreatorVault,     'CreatorVault')
      tryInit(addrs.maintenanceVault, VAULT_ABI,       setMaintenanceVault, 'MaintenanceVault')
      tryInit(addrs.collector,        COLLECTOR_ABI,   setCollector,        'Collector')
      tryInit(addrs.oneMEMEBB,        ONE_MEMEBB_ABI,  setOneMEMEBB,        '1MEMEBB')
      tryInit(addrs.oneDex,           ONEDEX_ABI,      setOneDex,           'OneDex')
    }

    init()
  }, [signer, chainId])

  // Listen for wallet account/chain changes
  useEffect(() => {
    const ethereum = (window as any).ethereum
    if (!ethereum) return

    const handleAccountsChanged = async (accounts: string[]) => {
      if (accounts.length === 0) disconnectWallet()
      else await connectWallet()
    }

    const handleChainChanged = (chainIdHex: string) => {
      const id        = parseInt(chainIdHex, 16)
      const supported = SUPPORTED_CHAIN_IDS.includes(id)
      setChainId(id)
      setActiveChain(supported ? getChainConfig(id) : null)
      setIsWrongNetwork(!supported)
      if (!supported) { setSigner(null); setAccount(null) }
      else window.location.reload()
    }

    ethereum.on('accountsChanged', handleAccountsChanged)
    ethereum.on('chainChanged',    handleChainChanged)
    return () => {
      ethereum.removeListener('accountsChanged', handleAccountsChanged)
      ethereum.removeListener('chainChanged',    handleChainChanged)
    }
  }, [connectWallet, disconnectWallet])

  const chain = activeChain ?? DEFAULT_CHAIN

  const value: Web3ContextType = {
    provider,
    signer,
    account,
    chainId,
    activeChain,
    isConnected:  !!account,
    isConnecting,
    isWrongNetwork,
    factory,
    bondingCurve,
    vestingWallet,
    creatorVault,
    maintenanceVault,
    collector,
    oneMEMEBB,
    oneDex,
    creatorVaultAddress:     chain.contracts.creatorVault,
    maintenanceVaultAddress: chain.contracts.maintenanceVault,
    collectorAddress:        chain.contracts.collector,
    oneMEMEBBAddress:        chain.contracts.oneMEMEBB,
    oneDexAddress:           chain.contracts.oneDex,
    connectWallet,
    disconnectWallet,
    switchToChain,
    toast,
    toasts,
    dismissToast,
  }

  return <Web3Context.Provider value={value}>{children}</Web3Context.Provider>
}

export function useWeb3() {
  const context = useContext(Web3Context)
  if (!context) throw new Error('useWeb3 must be used within Web3Provider')
  return context
}
