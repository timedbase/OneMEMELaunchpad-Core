import { useCallback, useState } from 'react'
import type { BrowserProvider } from 'ethers'
import { Contract } from 'ethers'

export function useWeb3() {
  const [signer, setSigner] = useState<any>(null)
  const [provider, setProvider] = useState<BrowserProvider | null>(null)
  const [account, setAccount] = useState<string | null>(null)
  const [isConnecting, setIsConnecting] = useState(false)

  const connectWallet = useCallback(async () => {
    const ethereum = (window as any).ethereum
    if (!ethereum) {
      throw new Error('MetaMask not installed')
    }
    
    setIsConnecting(true)
    try {
      // Implementation will go here
      console.log('Connecting wallet...')
    } finally {
      setIsConnecting(false)
    }
  }, [])

  const disconnectWallet = useCallback(() => {
    setSigner(null)
    setProvider(null)
    setAccount(null)
  }, [])

  return { signer, provider, account, isConnecting, connectWallet, disconnectWallet }
}

export function useContractRead(address: string, abi: any, provider: BrowserProvider | null) {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const read = useCallback(async (functionName: string, ...args: any[]) => {
    if (!provider || !address) return null
    
    setLoading(true)
    setError(null)
    try {
      const contract = new Contract(address, abi, provider)
      return await contract[functionName](...args)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error')
      return null
    } finally {
      setLoading(false)
    }
  }, [address, abi, provider])

  return { read, loading, error }
}
