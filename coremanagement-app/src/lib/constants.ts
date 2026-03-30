// Global constants
export const RPC_ENDPOINTS = {
  BSC_MAINNET: 'https://bsc-dataseed.binance.org',
  BSC_TESTNET: 'https://data-seed-prebsc-1-s1.binance.org:8545',
} as const

export const NETWORK_NAMES = {
  [RPC_ENDPOINTS.BSC_MAINNET]: 'BSC Mainnet',
  [RPC_ENDPOINTS.BSC_TESTNET]: 'BSC Testnet',
} as const

export const VAULT_TYPES = {
  CREATOR: 'Creator',
  MAINTENANCE: 'Maintenance',
} as const
