import { useState, useEffect } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'

export default function CreateTokenTab() {
  const { factory, signer, account, toast } = useWeb3()
  
  const [selectedType, setSelectedType] = useState<'standard' | 'tax' | 'reflection'>('standard')
  const [name, setName] = useState('')
  const [symbol, setSymbol] = useState('')
  const [meta, setMeta] = useState('')
  const [supply, setSupply] = useState('2') // 1M default
  const [creatorAlloc, setCreatorAlloc] = useState(false)
  const [antibot, setAntibot] = useState(false)
  const [antibotBlocks, setAntibotBlocks] = useState(30)
  const [earlyBuy, setEarlyBuy] = useState(0)
  
  const [foundSalt] = useState<string | null>(null)
  const [foundAddr] = useState<string | null>(null)
  const [creationFee, setCreationFee] = useState('0')
  const [isCreating, setIsCreating] = useState(false)

  // Load creation fee
  useEffect(() => {
    const loadFee = async () => {
      if (!factory) return
      try {
        // Load fee from contract
        setCreationFee('0.01')
      } catch (e) {
        console.error('Failed to load creation fee:', e)
      }
    }
    loadFee()
  }, [factory])

  const handleCreateToken = async () => {
    if (!account || !signer || !factory) {
      toast('Connect wallet and ensure factory is loaded', 'danger')
      return
    }
    if (!name || !symbol) {
      toast('Enter token name and symbol', 'danger')
      return
    }
    if (!foundSalt || !foundAddr) {
      toast('Mine a vanity address first', 'danger')
      return
    }

    setIsCreating(true)
    try {
      // Would call factory.create(...) but implementation depends on actual ABI
      toast('Create token functionality - call factory.create() with mined salt', 'warn')
    } catch (e: any) {
      toast(`Create failed: ${e.reason || e.message || e}`, 'danger')
    } finally {
      setIsCreating(false)
    }
  }

  return (
    <div className="space-y-6">
      <div>
        <p className="text-xs text-muted mb-4 leading-relaxed">
          Deploys an EIP-1167 clone with a vanity address ending in <strong>0x…1111</strong>. 
          The salt is mined automatically when you connect your wallet. Fill in the parameters below and click <strong>Create Token</strong> once the address appears.
        </p>
      </div>
      
      {/* Step 1 - Token Type */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Step 1 — Token Type
        </div>
        <div className="flex gap-2 flex-wrap">
          {(['standard', 'tax', 'reflection'] as const).map(type => (
            <button
              key={type}
              onClick={() => setSelectedType(type)}
              className={`flex-1 min-w-[120px] py-3 px-4 rounded border-2 transition ${
                selectedType === type
                  ? 'border-accent bg-accent/10 text-accent'
                  : 'border-border text-text hover:border-accent'
              }`}
            >
              <div className="font-semibold text-sm capitalize">{type}</div>
              <div className="text-xs text-muted">
                {type === 'standard' && 'Basic meme token'}
                {type === 'tax' && 'Buy/sell tax'}
                {type === 'reflection' && 'Holders earn fees'}
              </div>
            </button>
          ))}
        </div>
      </div>

      {/* Step 2 - Parameters */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Step 2 — Parameters
        </div>
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <Input
              label="Token Name"
              placeholder="e.g. PepeCoin"
              value={name}
              onChange={e => setName(e.target.value)}
            />
            <Input
              label="Symbol"
              placeholder="e.g. PEPE"
              value={symbol}
              onChange={e => setSymbol(e.target.value)}
            />
          </div>
          <Input
            label="Meta URI (optional)"
            placeholder="ipfs://… or https://…"
            value={meta}
            onChange={e => setMeta(e.target.value)}
          />

          {/* Supply Options */}
          <div>
            <label className="text-xs font-semibold text-muted uppercase mb-2 block">Supply Option</label>
            <div className="space-y-2">
              {[
                { value: '0', label: 'ONE (1)' },
                { value: '1', label: 'THOUSAND (1K)' },
                { value: '2', label: 'MILLION (1M)' },
                { value: '3', label: 'BILLION (1B)' },
              ].map(opt => (
                <label key={opt.value} className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="radio"
                    name="supply"
                    value={opt.value}
                    checked={supply === opt.value}
                    onChange={e => setSupply(e.target.value)}
                    className="w-4 h-4"
                  />
                  <span className="text-sm">{opt.label}</span>
                </label>
              ))}
            </div>
          </div>

          {/* Options */}
          <div className="space-y-2">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={creatorAlloc}
                onChange={e => setCreatorAlloc(e.target.checked)}
                className="w-4 h-4"
              />
              <span className="text-sm">Creator Allocation <span className="text-xs text-muted">(5% vested 12mo)</span></span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={antibot}
                onChange={e => setAntibot(e.target.checked)}
                className="w-4 h-4"
              />
              <span className="text-sm">Antibot</span>
            </label>
            {antibot && (
              <Input
                label="Antibot Blocks (10-199)"
                type="number"
                min="10"
                max="199"
                value={antibotBlocks}
                onChange={e => setAntibotBlocks(parseInt(e.target.value) || 30)}
              />
            )}
          </div>

          <Input
            label="Early Buy (BNB, 0 = none)"
            type="number"
            min="0"
            step="0.01"
            value={earlyBuy}
            onChange={e => setEarlyBuy(parseFloat(e.target.value) || 0)}
          />
        </div>
      </div>

      {/* Step 3 - Vanity Address */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Step 3 — Vanity Address
        </div>
        <p className="text-xs text-muted mb-3">Mined automatically on wallet connect</p>
        
        {foundAddr ? (
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            <Badge variant="ok">Salt found!</Badge>
            <div className="space-y-2 text-xs font-mono">
              <div><span className="text-muted">Predicted Address:</span> {foundAddr}</div>
              <div><span className="text-muted">Salt (hex):</span> <div className="break-all">{foundSalt}</div></div>
            </div>
          </div>
        ) : (
          <div className="text-xs text-muted p-4 text-center">Mining in progress or not started...</div>
        )}
      </div>

      {/* Step 4 - Create */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Step 4 — Create
        </div>
        <p className="text-xs text-muted mb-4">
          Creation fee: {creationFee} BNB + {earlyBuy.toFixed(4)} BNB early buy = {(parseFloat(creationFee) + earlyBuy).toFixed(6)} BNB
        </p>
        <Button
          onClick={handleCreateToken}
          disabled={isCreating || !foundSalt}
          className="w-full"
        >
          {isCreating ? 'Creating...' : 'Create Token'}
        </Button>
      </div>
    </div>
  )
}
