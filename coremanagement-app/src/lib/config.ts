export interface ChainContracts {
  factory:          string
  bondingCurve:     string
  vestingWallet:    string
  oneMEMEBB:        string
  collector:        string
  creatorVault:     string
  maintenanceVault: string
  oneDex:           string
}

export interface ChainConfig {
  chainId:        number
  name:           string
  shortName:      string
  rpc:            string
  nativeCurrency: { name: string; symbol: string; decimals: number }
  explorer:       string
  contracts:      ChainContracts
}

export const CHAINS: Record<number, ChainConfig> = {

  // ── BNB Smart Chain ───────────────────────────────────────────────────────
  56: {
    chainId:        56,
    name:           'BNB Smart Chain',
    shortName:      'BSC',
    rpc:            'https://bsc-dataseed.binance.org',
    nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
    explorer:       'https://bscscan.com',
    contracts: {
      factory:          '',
      bondingCurve:     '',
      vestingWallet:    '',
      oneMEMEBB:        '',
      collector:        '',
      creatorVault:     '',
      maintenanceVault: '',
      oneDex:           '',
    },
  },

  // ── Ethereum Mainnet ──────────────────────────────────────────────────────
  1: {
    chainId:        1,
    name:           'Ethereum',
    shortName:      'ETH',
    rpc:            'https://eth.llamarpc.com',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    explorer:       'https://etherscan.io',
    contracts: {
      factory:          '',
      bondingCurve:     '',
      vestingWallet:    '',
      oneMEMEBB:        '',
      collector:        '',
      creatorVault:     '',
      maintenanceVault: '',
      oneDex:           '',
    },
  },

}

export const SUPPORTED_CHAIN_IDS = Object.keys(CHAINS).map(Number)

export function getChainConfig(chainId: number): ChainConfig | null {
  return CHAINS[chainId] ?? null
}

/** Default read-only chain when no wallet is connected. */
export const DEFAULT_CHAIN = CHAINS[56]
