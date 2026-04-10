import { useState, useEffect, useCallback, useRef } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

type TokenType = 'standard' | 'tax' | 'reflection'

// Compute CREATE2 address matching the factory's _cloneCreate2 logic:
//   salt     = keccak256(abi.encode(sender, userSalt))
//   initcode = EIP-1167 minimal proxy for `impl`
//   address  = keccak256(0xff ++ factory ++ salt ++ keccak256(initcode))[12:]
function computeCreate2(factoryAddr: string, sender: string, userSalt: string, implAddr: string): string {
  const proxy =
    '0x3d602d80600a3d3981f3363d3d373d3d3d363d73' +
    implAddr.slice(2).toLowerCase() +
    '5af43d82803e903d91602b57fd5bf3'
  const initcodeHash = ethers.keccak256(ethers.getBytes(proxy))
  const salt = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(['address', 'bytes32'], [sender, userSalt])
  )
  return ethers.getCreate2Address(factoryAddr, salt, initcodeHash)
}

export default function CreateTokenTab() {
  const { factory, signer, account, toast } = useWeb3()

  const [selectedType, setSelectedType] = useState<TokenType>('standard')
  const [name, setName] = useState('')
  const [symbol, setSymbol] = useState('')
  const [meta, setMeta] = useState('')
  const [supply, setSupply] = useState('2') // MILLION default
  const [creatorAlloc, setCreatorAlloc] = useState(false)
  const [antibot, setAntibot] = useState(false)
  const [antibotBlocks, setAntibotBlocks] = useState(30)
  const [earlyBuy, setEarlyBuy] = useState('')

  // Factory data
  const [creationFee, setCreationFee] = useState<bigint>(0n)
  const [implAddrs, setImplAddrs] = useState<Record<TokenType, string>>({ standard: '', tax: '', reflection: '' })
  const [factoryAddr, setFactoryAddr] = useState('')

  // Salt miner
  const [isMining, setIsMining] = useState(false)
  const [miningAttempts, setMiningAttempts] = useState(0)
  const [foundSalt, setFoundSalt] = useState<string | null>(null)
  const [foundAddr, setFoundAddr] = useState<string | null>(null)
  const minerActiveRef = useRef(false)
  const minerTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const [isCreating, setIsCreating] = useState(false)

  // Load factory data
  useEffect(() => {
    if (!factory) return
    const load = async () => {
      try {
        const [fee, std, tax, rfl, fAddr] = await Promise.all([
          factory.creationFee(),
          factory.standardImpl(),
          factory.taxImpl(),
          factory.reflectionImpl(),
          factory.getAddress(),
        ])
        setCreationFee(fee)
        setImplAddrs({ standard: std, tax: tax, reflection: rfl })
        setFactoryAddr(fAddr)
      } catch (e) {
        console.error('Failed to load factory data:', e)
      }
    }
    load()
  }, [factory])

  // Stop miner when type or account changes
  useEffect(() => {
    stopMiner()
    setFoundSalt(null)
    setFoundAddr(null)
    setMiningAttempts(0)
  }, [selectedType, account])

  const stopMiner = () => {
    minerActiveRef.current = false
    if (minerTimerRef.current) {
      clearTimeout(minerTimerRef.current)
      minerTimerRef.current = null
    }
    setIsMining(false)
  }

  // Cleanup on unmount
  useEffect(() => () => stopMiner(), [])

  const startMining = useCallback(() => {
    if (!account || !factoryAddr) return toast('Connect wallet first', 'danger')
    const implAddr = implAddrs[selectedType]
    if (!implAddr) return toast('Factory not loaded', 'danger')

    stopMiner()
    setFoundSalt(null)
    setFoundAddr(null)
    setMiningAttempts(0)
    setIsMining(true)
    minerActiveRef.current = true

    let attempts = 0
    const batch = () => {
      if (!minerActiveRef.current) return
      const BATCH = 2000
      for (let i = 0; i < BATCH; i++) {
        const userSalt = ethers.hexlify(ethers.randomBytes(32))
        const addr = computeCreate2(factoryAddr, account, userSalt, implAddr)
        attempts++
        if (addr.toLowerCase().endsWith('1111')) {
          setFoundSalt(userSalt)
          setFoundAddr(addr)
          setMiningAttempts(attempts)
          minerActiveRef.current = false
          setIsMining(false)
          toast(`Vanity address found after ${attempts.toLocaleString()} attempts`, 'ok')
          return
        }
      }
      setMiningAttempts(attempts)
      minerTimerRef.current = setTimeout(batch, 0)
    }
    minerTimerRef.current = setTimeout(batch, 0)
  }, [account, factoryAddr, implAddrs, selectedType, toast])

  const handleCreate = async () => {
    if (!account || !signer || !factory) return toast('Connect wallet', 'danger')
    if (!name.trim() || !symbol.trim()) return toast('Enter token name and symbol', 'danger')
    if (!foundSalt) return toast('Mine a vanity address first', 'danger')

    setIsCreating(true)
    try {
      const supplyOption = Number(supply)
      const earlyBuyWei = earlyBuy ? ethers.parseEther(earlyBuy) : 0n
      const totalValue = creationFee + earlyBuyWei
      const factorySigned = factory.connect(signer) as any

      const baseParams = {
        name: name.trim(),
        symbol: symbol.trim().toUpperCase(),
        supplyOption,
        enableCreatorAlloc: creatorAlloc,
        enableAntibot: antibot,
        antibotBlocks: antibot ? antibotBlocks : 0,
        metaURI: meta.trim(),
        salt: foundSalt,
      }
      const ttRflParams = {
        name: name.trim(),
        symbol: symbol.trim().toUpperCase(),
        metaURI: meta.trim(),
        supplyOption,
        enableCreatorAlloc: creatorAlloc,
        enableAntibot: antibot,
        antibotBlocks: antibot ? antibotBlocks : 0,
        salt: foundSalt,
      }

      let tx: any
      if (selectedType === 'standard') {
        tx = await factorySigned.createToken(baseParams, { value: totalValue })
      } else if (selectedType === 'tax') {
        tx = await factorySigned.createTT(ttRflParams, { value: totalValue })
      } else {
        tx = await factorySigned.createRFL(ttRflParams, { value: totalValue })
      }

      toast('Creating token — waiting for confirmation…', 'warn')
      const receipt = await tx.wait()
      toast(`Token created! Tx: ${receipt.hash.slice(0, 10)}…`, 'ok')

      // Reset for next token
      setName(''); setSymbol(''); setMeta('')
      setFoundSalt(null); setFoundAddr(null); setMiningAttempts(0)
    } catch (e: any) {
      toast(`Create failed: ${e.reason || e.message || e}`, 'danger')
    } finally {
      setIsCreating(false)
    }
  }

  const feeDisplay = ethers.formatEther(creationFee)
  const earlyBuyWei = earlyBuy ? ethers.parseEther(earlyBuy) : 0n
  const totalDisplay = ethers.formatEther(creationFee + earlyBuyWei)

  return (
    <div className="space-y-6">
      <p className="text-xs text-muted leading-relaxed">
        Deploys an EIP-1167 clone with a vanity address ending in <strong>0x…1111</strong>.
        Mine the salt, fill the parameters, then click Create.
      </p>

      {/* Step 1 — Token Type */}
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
                selectedType === type ? 'border-accent bg-accent/10 text-accent' : 'border-border text-text hover:border-accent'
              }`}
            >
              <div className="font-semibold text-sm capitalize">{type}</div>
              <div className="text-xs text-muted">
                {type === 'standard' && 'Basic ERC-20'}
                {type === 'tax' && 'Buy/sell taxes'}
                {type === 'reflection' && 'Holder reflections'}
              </div>
            </button>
          ))}
        </div>
      </div>

      {/* Step 2 — Parameters */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Step 2 — Parameters
        </div>
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <Input label="Token Name" placeholder="e.g. PepeCoin" value={name} onChange={e => setName(e.target.value)} />
            <Input label="Symbol" placeholder="e.g. PEPE" value={symbol} onChange={e => setSymbol(e.target.value)} />
          </div>
          <Input label="Meta URI (optional)" placeholder="ipfs://… or https://…" value={meta} onChange={e => setMeta(e.target.value)} />

          <div>
            <label className="text-xs font-semibold text-muted uppercase mb-2 block">Supply</label>
            <div className="grid grid-cols-2 gap-2">
              {[
                { value: '0', label: '1 (ONE)' },
                { value: '1', label: '1,000 (THOUSAND)' },
                { value: '2', label: '1,000,000 (MILLION)' },
                { value: '3', label: '1,000,000,000 (BILLION)' },
              ].map(opt => (
                <label key={opt.value} className="flex items-center gap-2 cursor-pointer text-sm">
                  <input type="radio" name="supply" value={opt.value} checked={supply === opt.value}
                    onChange={e => setSupply(e.target.value)} className="w-4 h-4" />
                  {opt.label}
                </label>
              ))}
            </div>
          </div>

          <div className="space-y-2">
            <label className="flex items-center gap-2 cursor-pointer text-sm">
              <input type="checkbox" checked={creatorAlloc} onChange={e => setCreatorAlloc(e.target.checked)} className="w-4 h-4" />
              Creator Allocation <span className="text-xs text-muted">(5% vested 12 months)</span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer text-sm">
              <input type="checkbox" checked={antibot} onChange={e => setAntibot(e.target.checked)} className="w-4 h-4" />
              Antibot
            </label>
            {antibot && (
              <Input label="Antibot Blocks (10–199)" type="number" min="10" max="199"
                value={antibotBlocks} onChange={e => setAntibotBlocks(parseInt(e.target.value) || 30)} />
            )}
          </div>

          <Input label="Early Buy (BNB, leave blank for none)" type="number" min="0" step="0.01"
            placeholder="0" value={earlyBuy} onChange={e => setEarlyBuy(e.target.value)} />
        </div>
      </div>

      {/* Step 3 — Vanity Address */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Step 3 — Mine Vanity Address
        </div>

        {foundAddr ? (
          <div className="bg-surface border border-border rounded p-4 space-y-2">
            <div className="flex items-center justify-between">
              <Badge variant="ok">Address found</Badge>
              <span className="text-xs text-muted">{miningAttempts.toLocaleString()} attempts</span>
            </div>
            <div className="text-xs font-mono space-y-1">
              <div><span className="text-muted">Address: </span>{foundAddr}</div>
              <div className="truncate"><span className="text-muted">Salt: </span>{foundSalt}</div>
            </div>
            <Button size="sm" variant="secondary" onClick={startMining} disabled={!account || !factoryAddr}>
              Re-mine
            </Button>
          </div>
        ) : (
          <div className="bg-surface border border-border rounded p-4 space-y-3">
            {isMining ? (
              <>
                <div className="flex items-center justify-between">
                  <span className="text-xs text-muted animate-pulse">Mining…</span>
                  <span className="text-xs text-muted">{miningAttempts.toLocaleString()} attempts</span>
                </div>
                <Button size="sm" variant="danger" onClick={stopMiner} className="w-full">Stop</Button>
              </>
            ) : (
              <Button onClick={startMining} disabled={!account || !factoryAddr} className="w-full">
                {!account ? 'Connect wallet to mine' : !factoryAddr ? 'Factory not loaded' : 'Mine Vanity Address'}
              </Button>
            )}
          </div>
        )}
      </div>

      {/* Step 4 — Create */}
      <div>
        <div className="text-sm font-bold text-text mb-3 pb-2 border-b border-border">
          Step 4 — Create
        </div>
        <div className="bg-surface border border-border rounded p-4 space-y-3">
          <div className="text-xs text-muted space-y-1">
            <div className="flex justify-between"><span>Creation fee:</span><span>{feeDisplay} BNB</span></div>
            {earlyBuyWei > 0n && <div className="flex justify-between"><span>Early buy:</span><span>{earlyBuy} BNB</span></div>}
            <div className="flex justify-between font-semibold text-text border-t border-border pt-1 mt-1">
              <span>Total:</span><span>{totalDisplay} BNB</span>
            </div>
          </div>
          <Button onClick={handleCreate} disabled={isCreating || !foundSalt || !account} className="w-full">
            {isCreating ? 'Creating…' : !account ? 'Connect wallet' : !foundSalt ? 'Mine address first' : 'Create Token'}
          </Button>
        </div>
      </div>
    </div>
  )
}
