# OneMEME Core Management Dashboard - Development Guide

## ✅ Project Setup Complete

The React + TypeScript + shadcn/ui dashboard has been successfully initialized in the `coremanagement-app/` directory.

**Dev Server Status**: Running on `http://localhost:5173/`

## Quick Access

- **Dev Server**: `npm run dev` (running on port 5173)
- **Build**: `npm run build`
- **Preview**: `npm run preview`

## Project Overview
React + TypeScript + shadcn/ui dashboard for managing OneMEME launchpad contracts:
- LaunchpadFactory & BondingCurve (core contracts)
- Peripherals: 1MEMEBB, Collector, CreatorVault, MaintenanceVault
- Web3/Ethers.js integration for blockchain interaction

## Project Structure
```
coremanagement-app/
├── src/
│   ├── components/
│   │   ├── layout/
│   │   │   ├── Header.tsx
│   │   │   ├── TabNavigation.tsx
│   │   │   └── Shell.tsx
│   │   ├── overview/
│   │   │   ├── FactoryStats.tsx
│   │   │   └── BondingCurveStats.tsx
│   │   ├── create/
│   │   │   ├── TokenTypeSelector.tsx
│   │   │   ├── TokenParameters.tsx
│   │   │   ├── VanityAddress.tsx
│   │   │   └── CreateTokenTab.tsx
│   │   ├── registry/
│   │   │   └── RegistryTab.tsx
│   │   ├── inspector/
│   │   │   └── InspectorTab.tsx
│   │   ├── admin/
│   │   │   └── AdminTab.tsx
│   │   └── peripherals/
│   │       ├── ContractAddressSetup.tsx
│   │       ├── OneMEMEBBSection.tsx
│   │       ├── CollectorSection.tsx
│   │       ├── VaultSection.tsx
│   │       └── PeripheralsTab.tsx
│   ├── hooks/
│   │   ├── useWeb3.ts
│   │   ├── useFactory.ts
│   │   ├── useBondingCurve.ts
│   │   └── usePeripherals.ts
│   ├── lib/
│   │   ├── contracts.ts
│   │   ├── constants.ts
│   │   └── utils.ts
│   ├── types/
│   │   ├── contract.ts
│   │   └── ui.ts
│   ├── App.tsx
│   └── main.tsx
├── public/
├── package.json
├── tsconfig.json
└── vite.config.ts

## Key Dependencies
- React 18+
- TypeScript
- Ethers.js v6
- shadcn/ui & Radix UI
- Tailwind CSS
- Vite

## Development Workflow
1. Environment: BSC Testnet (default) or Custom RPC
2. Contracts: Factory, BC, VestingWallet, Peripherals (1MEMEBB, Collector, Vaults)
3. Web3 Integration: Connect wallet → Load factory → Interact with contracts
4. Component-based architecture with reusable hooks for contract logic

## Build & Run
- Dev: `npm run dev`
- Build: `npm run build`
- Preview: `npm run preview`

## Notes
- Replace original HTML-based dashboard with React app
- Maintain feature parity with existing dashboard
- Add proper error handling & loading states
- Support both Creator & Maintenance vault types
