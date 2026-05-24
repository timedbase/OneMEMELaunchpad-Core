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
      factory:          '0xA78df27496825B29CbdCD3778e6bc375a646Ae04',
      bondingCurve:     '0xbB843b111639B9F19E575e3804b7c006eE1F80a9',
      vestingWallet:    '0x1fFBE03316743187fCEC8eA41fd76f8Ada74658C',
      oneMEMEBB:        '0x6c489d9a998090D305139097BD110Be742722bB4',
      collector:        '0x0D9393D07194E17004F92265613d706277bC48C8',
      creatorVault:     '',
      maintenanceVault: '',
      oneDex:           '0xbE9dFD8E5e26baAF2bC44914dEB83051a61096c2',
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
      factory:          '0x534c9466aDb7d592235455C580cB4F836339c375',
      bondingCurve:     '0xA78df27496825B29CbdCD3778e6bc375a646Ae04',
      vestingWallet:    '0xe9F35abA5B0926258bE6EBbc17546B02704fB91C',
      oneMEMEBB:        '',
      collector:        '0x1fFBE03316743187fCEC8eA41fd76f8Ada74658C',
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
