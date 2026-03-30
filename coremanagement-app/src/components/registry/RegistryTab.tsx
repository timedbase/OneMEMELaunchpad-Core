import { useState } from 'react'
import { useWeb3 } from '../../lib/web3-context'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { Badge } from '../ui/Badge'
import { ethers } from 'ethers'

interface TokenData {
  token: string
  creator: string
  raisedBNB: bigint
  migrationTarget: bigint
  migrated: boolean
  index: number
}

export default function RegistryTab() {
  const { bondingCurve, toast } = useWeb3()
  const [creatorSearch, setCreatorSearch] = useState('')
  const [tokens, setTokens] = useState<TokenData[]>([])
  const [loading, setLoading] = useState(false)
  const [title, setTitle] = useState('')

  const handleSearchByCreator = async () => {
    if (!bondingCurve) {
      toast('Load factory first', 'warn')
      return
    }
    if (!ethers.isAddress(creatorSearch.trim())) {
      toast('Invalid address', 'danger')
      return
    }

    setLoading(true)
    try {
      const addrs = await bondingCurve.getTokensByCreator(creatorSearch.trim())
      const tokenDatas: TokenData[] = []
      
      for (let i = 0; i < addrs.length; i++) {
        try {
          const td = await bondingCurve.getToken(addrs[i])
          tokenDatas.push({
            token: td.token,
            creator: td.creator,
            raisedBNB: td.raisedBNB,
            migrationTarget: td.migrationTarget,
            migrated: td.migrated,
            index: i,
          })
        } catch (e) {
          console.error('Failed to fetch token:', e)
        }
      }

      setTokens(tokenDatas)
      setTitle(`Tokens by creator ${creatorSearch.slice(0, 6)}...${creatorSearch.slice(-4)}`)
    } catch (e: any) {
      toast(`Error: ${e.message || e}`, 'danger')
    } finally {
      setLoading(false)
    }
  }

  const handleLoadAllTokens = async () => {
    if (!bondingCurve) {
      toast('Load factory first', 'warn')
      return
    }

    setLoading(true)
    try {
      const total = await bondingCurve.totalTokensLaunched()
      const count = Number(total)
      const start = Math.max(0, count - 100)
      
      const tokenDatas: TokenData[] = []
      for (let i = start; i < count; i++) {
        try {
          const addr = await bondingCurve.allTokens(i)
          const td = await bondingCurve.getToken(addr)
          tokenDatas.push({
            token: td.token,
            creator: td.creator,
            raisedBNB: td.raisedBNB,
            migrationTarget: td.migrationTarget,
            migrated: td.migrated,
            index: i,
          })
        } catch (e) {
          console.error('Failed to fetch token at index', i, e)
        }
      }

      setTokens(tokenDatas)
      setTitle(`All tokens (showing last ${tokenDatas.length} of ${count})`)
    } catch (e: any) {
      toast(`Error: ${e.message || e}`, 'danger')
    } finally {
      setLoading(false)
    }
  }

  const formatBNB = (wei: bigint) => {
    return parseFloat(ethers.formatEther(wei)).toFixed(4)
  }

  const shortAddress = (addr: string) => {
    return `${addr.slice(0, 6)}...${addr.slice(-4)}`
  }

  return (
    <div className="space-y-6">
      <div className="flex gap-3 flex-wrap items-end">
        <div className="flex-1 min-w-[200px]">
          <Input
            label="Search by Creator"
            placeholder="0x…"
            value={creatorSearch}
            onChange={e => setCreatorSearch(e.target.value)}
          />
        </div>
        <Button onClick={handleSearchByCreator} disabled={loading}>
          Search
        </Button>
        <Button variant="secondary" onClick={handleLoadAllTokens} disabled={loading}>
          Show All (last 100)
        </Button>
      </div>

      {tokens.length === 0 ? (
        <div className="text-center py-20 text-muted">
          {loading ? 'Loading tokens...' : 'Load a factory and search or show all tokens.'}
        </div>
      ) : (
        <div>
          <p className="text-xs text-muted mb-3">{title}</p>
          <div className="space-y-2">
            {tokens.map(token => {
              const pct = token.migrationTarget > 0n
                ? Math.min(100, Number((token.raisedBNB * 10000n) / token.migrationTarget) / 100)
                : 0
              
              return (
                <div
                  key={token.token}
                  className="bg-surface border border-border rounded p-3 flex items-center justify-between gap-3 text-sm"
                >
                  <div className="flex items-center gap-3 flex-1">
                    <span className="text-xs text-muted font-mono">#{token.index}</span>
                    <span className="font-mono text-xs">{shortAddress(token.token)}</span>
                  </div>
                  
                  <div className="flex-1">
                    {token.migrated ? (
                      <Badge variant="ok">✓ Migrated</Badge>
                    ) : (
                      <div className="flex items-center gap-2">
                        <div className="w-20 h-1 bg-border rounded overflow-hidden">
                          <div
                            className="h-full bg-accent"
                            style={{ width: `${pct}%` }}
                          />
                        </div>
                        <span className="text-xs text-muted">{pct.toFixed(0)}%</span>
                      </div>
                    )}
                  </div>

                  <span className="text-xs text-muted">
                    {formatBNB(token.raisedBNB)} / {formatBNB(token.migrationTarget)} BNB
                  </span>
                </div>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}
