// Environment configuration
const getEnv = (key: string, defaultValue: string = ''): string => {
  return (((import.meta as any).env as Record<string, string>)[key] || defaultValue)
}

export const config = {
  // Contract Addresses
  factoryAddress: getEnv('VITE_FACTORY_ADDRESS', ''),
  bondingCurveAddress: getEnv('VITE_BONDING_CURVE_ADDRESS', ''),
  vestingWalletAddress: getEnv('VITE_VESTING_WALLET_ADDRESS', ''),

  // Peripheral Contracts
  oneMEMEBBAddress: getEnv('VITE_ONE_MEMEBB_ADDRESS', ''),
  collectorAddress: getEnv('VITE_COLLECTOR_ADDRESS', ''),
  creatorVaultAddress: getEnv('VITE_CREATOR_VAULT_ADDRESS', ''),
  maintenanceVaultAddress: getEnv('VITE_MAINTENANCE_VAULT_ADDRESS', ''),

  // RPC Endpoints
  rpcBSCMainnet: getEnv('VITE_RPC_BSC_MAINNET', 'https://bsc-dataseed.binance.org'),
  rpcBSCTestnet: getEnv('VITE_RPC_BSC_TESTNET', 'https://data-seed-prebsc-1-s1.binance.org:8545'),

  // Default Network
  defaultNetwork: (getEnv('VITE_DEFAULT_NETWORK', 'testnet') as 'mainnet' | 'testnet'),
}

export function getContractAddresses() {
  return {
    factory: config.factoryAddress,
    bondingCurve: config.bondingCurveAddress,
    vestingWallet: config.vestingWalletAddress,
    oneMEMEBB: config.oneMEMEBBAddress,
    collector: config.collectorAddress,
    creatorVault: config.creatorVaultAddress,
    maintenanceVault: config.maintenanceVaultAddress,
  }
}

export function getRpcUrl(network: 'mainnet' | 'testnet' = config.defaultNetwork): string {
  return network === 'mainnet' ? config.rpcBSCMainnet : config.rpcBSCTestnet
}
