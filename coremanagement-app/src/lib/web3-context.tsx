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
import { config, getContractAddresses } from './config'
import {
  FACTORY_ABI,
  BC_ABI,
  VW_ABI,
  VAULT_ABI,
  COLLECTOR_ABI,
  ONE_MEMEBB_ABI,
} from './contracts'

const BSC_MAINNET_CHAIN_ID = 56

// Read-only provider — always available, no wallet required
const readProvider = new JsonRpcProvider(config.rpcBSCMainnet)

export interface Web3ContextType {
  provider: BrowserProvider | null
  signer: any | null
  account: string | null
  chainId: number | null
  isConnected: boolean
  isConnecting: boolean
  isWrongNetwork: boolean

  factory: Contract | null
  bondingCurve: Contract | null
  vestingWallet: Contract | null
  creatorVault: Contract | null
  maintenanceVault: Contract | null
  collector: Contract | null
  oneMEMEBB: Contract | null

  creatorVaultAddress: string
  maintenanceVaultAddress: string
  oneMEMEBBAddress: string
  collectorAddress: string

  connectWallet: () => Promise<void>
  disconnectWallet: () => void
  toast: (message: string, type?: 'ok' | 'warn' | 'danger') => void
  toasts: { id: number; message: string; type: 'ok' | 'warn' | 'danger' }[]
  dismissToast: (id: number) => void
}

const Web3Context = createContext<Web3ContextType | null>(null)

export function Web3Provider({ children }: { children: ReactNode }) {
  const [provider, setProvider] = useState<BrowserProvider | null>(null)
  const [signer, setSigner] = useState<any | null>(null)
  const [account, setAccount] = useState<string | null>(null)
  const [chainId, setChainId] = useState<number | null>(null)
  const [isConnecting, setIsConnecting] = useState(false)
  const [isWrongNetwork, setIsWrongNetwork] = useState(false)

  const [factory, setFactory] = useState<Contract | null>(null)
  const [bondingCurve, setBondingCurve] = useState<Contract | null>(null)
  const [vestingWallet, setVestingWallet] = useState<Contract | null>(null)
  const [creatorVault, setCreatorVault] = useState<Contract | null>(null)
  const [maintenanceVault, setMaintenanceVault] = useState<Contract | null>(null)
  const [collector, setCollector] = useState<Contract | null>(null)
  const [oneMEMEBB, setOneMEMEBB] = useState<Contract | null>(null)

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

  // Attempt to switch the connected wallet to BSC Mainnet
  const switchToBSCMainnet = useCallback(async () => {
    const ethereum = (window as any).ethereum
    if (!ethereum) return false
    try {
      await ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: '0x38' }],
      })
      return true
    } catch (err: any) {
      if (err.code === 4902) {
        try {
          await ethereum.request({
            method: 'wallet_addEthereumChain',
            params: [{
              chainId: '0x38',
              chainName: 'BNB Smart Chain',
              nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
              rpcUrls: ['https://bsc-dataseed.binance.org'],
              blockExplorerUrls: ['https://bscscan.com'],
            }],
          })
          return true
        } catch {
          return false
        }
      }
      return false
    }
  }, [])

  const connectWallet = useCallback(async () => {
    const ethereum = (window as any).ethereum
    if (!ethereum) {
      toast('No wallet detected', 'danger')
      return
    }

    setIsConnecting(true)
    try {
      const accounts = await ethereum.request({ method: 'eth_requestAccounts' })
      const newProvider = new BrowserProvider(ethereum)
      const network = await newProvider.getNetwork()
      const connectedChainId = Number(network.chainId)

      if (connectedChainId !== BSC_MAINNET_CHAIN_ID) {
        toast('Wrong network — switching to BSC Mainnet…', 'warn')
        const switched = await switchToBSCMainnet()
        if (!switched) {
          toast('Please switch to BSC Mainnet (chainId 56) to use this app', 'danger')
          setIsWrongNetwork(true)
          return
        }
        // Re-create provider after switch
        const switchedProvider = new BrowserProvider(ethereum)
        const switchedSigner = await switchedProvider.getSigner()
        const switchedNetwork = await switchedProvider.getNetwork()
        setProvider(switchedProvider)
        setSigner(switchedSigner)
        setAccount(accounts[0])
        setChainId(Number(switchedNetwork.chainId))
        setIsWrongNetwork(false)
        toast('Connected to BSC Mainnet', 'ok')
        return
      }

      const newSigner = await newProvider.getSigner()
      setProvider(newProvider)
      setSigner(newSigner)
      setAccount(accounts[0])
      setChainId(connectedChainId)
      setIsWrongNetwork(false)
      toast('Wallet connected', 'ok')
    } catch (err: any) {
      toast(`Connection failed: ${err.message}`, 'danger')
    } finally {
      setIsConnecting(false)
    }
  }, [toast, switchToBSCMainnet])

  const disconnectWallet = useCallback(() => {
    setSigner(null)
    setAccount(null)
    setChainId(null)
    setIsWrongNetwork(false)
    toast('Wallet disconnected', 'ok')
  }, [toast])

  // Initialize contracts whenever the signer changes (or on first mount with readProvider)
  useEffect(() => {
    const initContracts = async () => {
      const factoryAddr = config.factoryAddress
      if (!factoryAddr) return

      const p = signer ?? readProvider

      try {
        const factoryContract = new Contract(factoryAddr, FACTORY_ABI, p)
        setFactory(factoryContract)

        const bcAddr = await factoryContract.migrator()
        if (bcAddr && bcAddr !== ZeroAddress) {
          setBondingCurve(new Contract(bcAddr, BC_ABI, p))
        }

        const vwAddr = await factoryContract.vestingWallet()
        if (vwAddr && vwAddr !== ZeroAddress) {
          setVestingWallet(new Contract(vwAddr, VW_ABI, p))
        }
      } catch (err) {
        console.error('Factory init error:', err)
      }

      const addresses = getContractAddresses()

      if (addresses.creatorVault) {
        try { setCreatorVault(new Contract(addresses.creatorVault, VAULT_ABI, p)) }
        catch (err) { console.warn('CreatorVault init failed:', err) }
      }

      if (addresses.maintenanceVault) {
        try { setMaintenanceVault(new Contract(addresses.maintenanceVault, VAULT_ABI, p)) }
        catch (err) { console.warn('MaintenanceVault init failed:', err) }
      }

      if (addresses.collector) {
        try { setCollector(new Contract(addresses.collector, COLLECTOR_ABI, p)) }
        catch (err) { console.warn('Collector init failed:', err) }
      }

      if (addresses.oneMEMEBB) {
        try { setOneMEMEBB(new Contract(addresses.oneMEMEBB, ONE_MEMEBB_ABI, p)) }
        catch (err) { console.warn('1MEMEBB init failed:', err) }
      }
    }

    initContracts()
  }, [signer])

  // Listen for account/chain changes
  useEffect(() => {
    const ethereum = (window as any).ethereum
    if (!ethereum) return

    const handleAccountsChanged = async (accounts: string[]) => {
      if (accounts.length === 0) disconnectWallet()
      else await connectWallet()
    }

    const handleChainChanged = (chainIdHex: string) => {
      const id = parseInt(chainIdHex, 16)
      setChainId(id)
      setIsWrongNetwork(id !== BSC_MAINNET_CHAIN_ID)
      if (id !== BSC_MAINNET_CHAIN_ID) {
        setSigner(null)
        setAccount(null)
      } else {
        window.location.reload()
      }
    }

    ethereum.on('accountsChanged', handleAccountsChanged)
    ethereum.on('chainChanged', handleChainChanged)
    return () => {
      ethereum.removeListener('accountsChanged', handleAccountsChanged)
      ethereum.removeListener('chainChanged', handleChainChanged)
    }
  }, [connectWallet, disconnectWallet])

  const addresses = getContractAddresses()

  const value: Web3ContextType = {
    provider,
    signer,
    account,
    chainId,
    isConnected: !!account,
    isConnecting,
    isWrongNetwork,
    factory,
    bondingCurve,
    vestingWallet,
    creatorVault,
    maintenanceVault,
    collector,
    oneMEMEBB,
    creatorVaultAddress: addresses.creatorVault,
    maintenanceVaultAddress: addresses.maintenanceVault,
    collectorAddress: addresses.collector,
    oneMEMEBBAddress: addresses.oneMEMEBB,
    connectWallet,
    disconnectWallet,
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
