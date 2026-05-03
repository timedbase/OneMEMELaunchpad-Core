const getEnv = (key: string, defaultValue: string = ''): string =>
  (((import.meta as any).env as Record<string, string>)[key] || defaultValue)

export const config = {
  factoryAddress:          getEnv('VITE_FACTORY_ADDRESS', ''),
  bondingCurveAddress:     getEnv('VITE_BONDING_CURVE_ADDRESS', ''),
  vestingWalletAddress:    getEnv('VITE_VESTING_WALLET_ADDRESS', ''),
  oneMEMEBBAddress:        getEnv('VITE_ONE_MEMEBB_ADDRESS', ''),
  collectorAddress:        getEnv('VITE_COLLECTOR_ADDRESS', ''),
  creatorVaultAddress:     getEnv('VITE_CREATOR_VAULT_ADDRESS', ''),
  maintenanceVaultAddress: getEnv('VITE_MAINTENANCE_VAULT_ADDRESS', ''),
  aggregatorAddress:       getEnv('VITE_AGGREGATOR_ADDRESS', ''),
  metaTxAddress:           getEnv('VITE_METATX_ADDRESS', ''),
  rpcBSCMainnet:           getEnv('VITE_RPC_BSC_MAINNET', 'https://bsc-dataseed.binance.org'),
}

export function getContractAddresses() {
  return {
    factory:          config.factoryAddress,
    bondingCurve:     config.bondingCurveAddress,
    vestingWallet:    config.vestingWalletAddress,
    oneMEMEBB:        config.oneMEMEBBAddress,
    collector:        config.collectorAddress,
    creatorVault:     config.creatorVaultAddress,
    maintenanceVault: config.maintenanceVaultAddress,
    aggregator:       config.aggregatorAddress,
    metaTx:           config.metaTxAddress,
  }
}
