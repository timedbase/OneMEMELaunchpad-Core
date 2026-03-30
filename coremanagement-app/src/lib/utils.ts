// Utility functions for Web3 interaction
export function shortenAddress(address: string, chars = 4): string {
  return `${address.substring(0, chars + 2)}...${address.substring(address.length - chars)}`
}

export function formatBalance(balance: bigint, decimals: number): string {
  const bn = balance.toString().padStart(decimals + 1, '0')
  const intPart = bn.slice(0, -decimals) || '0'
  const fracPart = bn.slice(-decimals)
  return `${intPart}.${fracPart}`
}

export function parseBalance(amount: string, decimals: number): bigint {
  const parts = amount.split('.')
  const intPart = parts[0]
  const fracPart = (parts[1] || '').padEnd(decimals, '0').substring(0, decimals)
  return BigInt(intPart + fracPart)
}

export function isValidAddress(address: string): boolean {
  return /^0x[a-fA-F0-9]{40}$/.test(address)
}

export function copyToClipboard(text: string): Promise<void> {
  return navigator.clipboard.writeText(text)
}
