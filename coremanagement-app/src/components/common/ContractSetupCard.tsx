import { useState } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { config, getRpcUrl } from '../../lib/config'

export function ContractSetupCard() {
  const { setFactoryAddress, toast, switchRPC } = useWeb3()
  const [factoryInput, setFactoryInput] = useState('')
  const [rpcUrl, setRpcUrl] = useState(getRpcUrl())
  const [customRpc, setCustomRpc] = useState('')
  const [networkType, setNetworkType] = useState<'mainnet' | 'testnet'>(config.defaultNetwork)

  const handleLoadFactory = async () => {
    if (!factoryInput.trim()) {
      toast('Please enter a factory address', 'warn')
      return
    }

    // Basic validation
    if (!/^0x[a-fA-F0-9]{40}$/i.test(factoryInput)) {
      toast('Invalid Ethers address format', 'danger')
      return
    }

    try {
      setFactoryAddress(factoryInput.trim())
      if (customRpc) await switchRPC(customRpc)
      else await switchRPC(rpcUrl)

      toast('Factory loaded successfully', 'ok')
    } catch (err: any) {
      toast(`Error: ${err.message}`, 'danger')
    }
  }

  const handleRpcSwitch = (type: 'mainnet' | 'testnet') => {
    setNetworkType(type)
    const url = type === 'mainnet' ? config.rpcBSCMainnet : config.rpcBSCTestnet
    setRpcUrl(url)
    switchRPC(url)
  }

  return (
    <div className="bg-surface border border-border rounded-lg p-4 mb-6">
      <h3 className="text-sm font-semibold text-text mb-4">Setup</h3>

      <div className="space-y-4">
        {/* RPC Selection */}
        <div>
          <label className="text-xs text-muted font-medium mb-2 block">Network</label>
          <div className="flex gap-2">
            <Button
              variant={networkType === 'testnet' ? 'default' : 'secondary'}
              size="sm"
              onClick={() => handleRpcSwitch('testnet')}
            >
              BSC Testnet
            </Button>
            <Button
              variant={networkType === 'mainnet' ? 'default' : 'secondary'}
              size="sm"
              onClick={() => handleRpcSwitch('mainnet')}
            >
              BSC Mainnet
            </Button>
          </div>
        </div>

        {/* Custom RPC */}
        <div>
          <Input
            label="Custom RPC (optional)"
            placeholder="https://..."
            value={customRpc}
            onChange={(e) => setCustomRpc(e.target.value)}
          />
        </div>

        {/* Factory Address */}
        <div>
          <Input
            label="LaunchpadFactory Address"
            placeholder="0x..."
            className="mono"
            value={factoryInput}
            onChange={(e) => setFactoryInput(e.target.value)}
          />
        </div>

        <Button onClick={handleLoadFactory} className="w-full">
          Load Factory
        </Button>
      </div>
    </div>
  )
}
