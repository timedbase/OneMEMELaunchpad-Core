import {
  createContext,
  useContext,
  useCallback,
  useState,
  useEffect,
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

export interface Web3ContextType {
  // Connection State
  provider: BrowserProvider | null
  signer: any | null
  account: string | null
  chainId: number | null
  isConnected: boolean
  isConnecting: boolean

  // Contracts
  factory: Contract | null
  bondingCurve: Contract | null
  vestingWallet: Contract | null
  creatorVault: Contract | null
  maintenanceVault: Contract | null
  collector: Contract | null
  oneMEMEBB: Contract | null

  // Contract Address Strings
  creatorVaultAddress: string
  maintenanceVaultAddress: string
  oneMEMEBBAddress: string
  collectorAddress: string

  // Methods
  connectWallet: () => Promise<void>
  disconnectWallet: () => void
  switchRPC: (rpc: string) => Promise<void>
  toast: (message: string, type: 'ok' | 'warn' | 'danger') => void

  // Factory Address Override
  factoryAddress: string | null
  setFactoryAddress: (addr: string | null) => void
}

const Web3Context = createContext<Web3ContextType | null>(null)

export function Web3Provider({ children }: { children: ReactNode }) {
  const [provider, setProvider] = useState<BrowserProvider | null>(null)
  const [signer, setSigner] = useState<any | null>(null)
  const [account, setAccount] = useState<string | null>(null)
  const [chainId, setChainId] = useState<number | null>(null)
  const [isConnecting, setIsConnecting] = useState(false)
  const [factoryAddress, setFactoryAddress] = useState<string | null>(config.factoryAddress || null)

  // Contract instances
  const [factory, setFactory] = useState<Contract | null>(null)
  const [bondingCurve, setBondingCurve] = useState<Contract | null>(null)
  const [vestingWallet, setVestingWallet] = useState<Contract | null>(null)
  const [creatorVault, setCreatorVault] = useState<Contract | null>(null)
  const [maintenanceVault, setMaintenanceVault] = useState<Contract | null>(null)
  const [collector, setCollector] = useState<Contract | null>(null)
  const [oneMEMEBB, setOneMEMEBB] = useState<Contract | null>(null)

  // Toast notifications
  const toast = useCallback((message: string, type: 'ok' | 'warn' | 'danger' = 'ok') => {
    console.log(`[${type.toUpperCase()}] ${message}`)
    // Could dispatch to a toast system here
  }, [])

  // Connect wallet
  const connectWallet = useCallback(async () => {
    const ethereum = (window as any).ethereum
    if (!ethereum) {
      toast('No wallet detected', 'danger')
      return
    }

    setIsConnecting(true)
    try {
      const accounts = await ethereum.request({
        method: 'eth_requestAccounts',
      })

      const newProvider = new BrowserProvider(ethereum)
      const newSigner = await newProvider.getSigner()
      const network = await newProvider.getNetwork()

      setProvider(newProvider)
      setSigner(newSigner)
      setAccount(accounts[0])
      setChainId(Number(network.chainId))

      toast('Wallet connected', 'ok')
    } catch (err: any) {
      toast(`Connection failed: ${err.message}`, 'danger')
    } finally {
      setIsConnecting(false)
    }
  }, [toast])

  // Disconnect wallet
  const disconnectWallet = useCallback(() => {
    setSigner(null)
    setAccount(null)
    setChainId(null)
    toast('Wallet disconnected', 'ok')
  }, [toast])

  // Switch RPC
  const switchRPC = useCallback(
    async (rpc: string) => {
      try {
        const newProvider = new JsonRpcProvider(rpc)
        setProvider(newProvider as any)
        toast('RPC switched', 'ok')
      } catch (err: any) {
        toast(`RPC switch failed: ${err.message}`, 'danger')
      }
    },
    [toast]
  )

  // Initialize contracts when provider changes
  useEffect(() => {
    const initContracts = async () => {
      if (!provider || !factoryAddress) return

      try {
        const p = signer || provider
        const factoryAddr = factoryAddress

        const factoryContract = new Contract(factoryAddr, FACTORY_ABI, p)
        setFactory(factoryContract)

        // Load BC address from factory
        const bcAddr = await factoryContract.migrator()
        if (bcAddr && bcAddr !== ZeroAddress) {
          const bcContract = new Contract(bcAddr, BC_ABI, p)
          setBondingCurve(bcContract)
        }

        // Load VestingWallet if set
        const vwAddr = await factoryContract.vestingWallet()
        if (vwAddr && vwAddr !== ZeroAddress) {
          const vwContract = new Contract(vwAddr, VW_ABI, p)
          setVestingWallet(vwContract)
        }

        // Load peripherals if addresses provided
        const addresses = getContractAddresses()

        if (addresses.creatorVault && addresses.creatorVault !== ZeroAddress) {
          try {
            const vaultContract = new Contract(addresses.creatorVault, VAULT_ABI, p)
            setCreatorVault(vaultContract)
          } catch (err) {
            console.warn('Failed to load CreatorVault:', err)
          }
        }

        if (addresses.maintenanceVault && addresses.maintenanceVault !== ZeroAddress) {
          try {
            const vaultContract = new Contract(addresses.maintenanceVault, VAULT_ABI, p)
            setMaintenanceVault(vaultContract)
          } catch (err) {
            console.warn('Failed to load MaintenanceVault:', err)
          }
        }

        if (addresses.collector && addresses.collector !== ZeroAddress) {
          try {
            const collectorContract = new Contract(addresses.collector, COLLECTOR_ABI, p)
            setCollector(collectorContract)
          } catch (err) {
            console.warn('Failed to load Collector:', err)
          }
        }

        if (addresses.oneMEMEBB && addresses.oneMEMEBB !== ZeroAddress) {
          try {
            const bbContract = new Contract(addresses.oneMEMEBB, ONE_MEMEBB_ABI, p)
            setOneMEMEBB(bbContract)
          } catch (err) {
            console.warn('Failed to load 1MEMEBB:', err)
          }
        }
      } catch (err: any) {
        console.error('Contract initialization error:', err)
      }
    }

    initContracts()
  }, [provider, signer, factoryAddress])

  // Listen for account changes
  useEffect(() => {
    const ethereum = (window as any).ethereum
    if (!ethereum) return

    const handleAccountsChanged = async (accounts: string[]) => {
      if (accounts.length === 0) {
        disconnectWallet()
      } else {
        await connectWallet()
      }
    }

    const handleChainChanged = () => {
      window.location.reload()
    }

    ethereum.on('accountsChanged', handleAccountsChanged)
    ethereum.on('chainChanged', handleChainChanged)

    return () => {
      ethereum.removeListener('accountsChanged', handleAccountsChanged)
      ethereum.removeListener('chainChanged', handleChainChanged)
    }
  }, [connectWallet, disconnectWallet])

  const value: Web3ContextType = {
    provider,
    signer,
    account,
    chainId,
    isConnected: !!account,
    isConnecting,
    factory,
    bondingCurve,
    vestingWallet,
    creatorVault,
    maintenanceVault,
    collector,
    oneMEMEBB,
    creatorVaultAddress: getContractAddresses().creatorVault,
    maintenanceVaultAddress: getContractAddresses().maintenanceVault,
    collectorAddress: getContractAddresses().collector,
    oneMEMEBBAddress: getContractAddresses().oneMEMEBB,
    connectWallet,
    disconnectWallet,
    switchRPC,
    toast,
    factoryAddress,
    setFactoryAddress,
  }

  return <Web3Context.Provider value={value}>{children}</Web3Context.Provider>
}

export function useWeb3() {
  const context = useContext(Web3Context)
  if (!context) {
    throw new Error('useWeb3 must be used within Web3Provider')
  }
  return context
}
