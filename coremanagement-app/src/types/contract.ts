// Type definitions for contracts
export interface FactoryStats {
  owner: string
  creationFee: bigint
  tokenCount: number
}

export interface BondingCurveStats {
  totalSupply: bigint
  raisedBNB: bigint
  migrated: boolean
}

export interface VaultProposal {
  id: number
  proposer: string
  target: string
  value: bigint
  data: string
  confirmCount: number
  executed: boolean
  cancelled: boolean
}

export interface CollectorState {
  bnbBalance: bigint
  lastDisperse: number
  recipients: {
    CR8: string
    MTN: string
    BB: string
    TW: string
    HK: string
    KJC: string
  }
}

export interface OneMEMEBBState {
  bnbBalance: bigint
  lastBuyback: number
  cooldown: number
  token: string
}
