# OneMEME Core Management Dashboard

A modern React + TypeScript dashboard for managing OneMEME launchpad contracts with shadcn/ui components and Tailwind CSS.

## Features

- **Core Contracts**: LaunchpadFactory & BondingCurve management
- **Peripheral Contracts**: 1MEMEBB, Collector, CreatorVault, MaintenanceVault
- **Web3 Integration**: Ethers.js v6 for blockchain interaction
- **Multi-vault Support**: Separate CreatorVault and MaintenanceVault management
- **Modern UI**: shadcn/ui components with dark theme

## Quick Start

```bash
# Install dependencies
npm install

# Start dev server
npm run dev

# Build for production
npm run build
```

## Technology Stack

- React 18
- TypeScript
- Ethers.js v6
- Tailwind CSS
- shadcn/ui (Radix UI)
- Vite

## Project Structure

```
src/
├── components/
│   ├── layout/         - Header, navigation, shell
│   ├── overview/       - Factory & BC stats
│   ├── create/         - Token creation flows
│   ├── registry/       - Token registry viewer
│   ├── inspector/      - Contract inspector
│   ├── admin/          - Admin functions
│   ├── peripherals/    - 1MEMEBB, Collector, Vaults
│   └── ui/             - Reusable UI components
├── hooks/              - Custom React hooks
├── lib/                - Utilities & constants
├── types/              - TypeScript definitions
├── App.tsx             - Main app component
└── main.tsx            - Entry point
```

## Environment

Default RPC: BSC Testnet  
Can be customized via UI settings
