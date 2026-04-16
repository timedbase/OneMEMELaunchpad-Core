#!/usr/bin/env node
/**
 * compile.js — OneMEME Core Contracts
 *
 * Uses the solc Node API with viaIR:true (required — contracts exceed the
 * EVM's 16-slot stack limit under legacy codegen).
 *
 * Outputs: out/<Contract>.abi  and  out/<Contract>.bin
 *
 * Usage:
 *   node compile.js            — compile all contracts
 *   node compile.js --verbose  — show warnings too
 */

'use strict';

const solc = require('solc');
const fs   = require('fs');
const path = require('path');

const VERBOSE = process.argv.includes('--verbose');
const OUT_DIR = path.join(__dirname, 'out');

// ── Source files to compile ──────────────────────────────────────────────────
const CONTRACT_FILES = [
  'contracts/BondingCurve.sol',
  'contracts/LaunchpadFactory.sol',
  'contracts/VestingWallet.sol',
  'contracts/interfaces/ILaunchpadToken.sol',
  'contracts/interfaces/IPancakeRouter02.sol',
  'contracts/interfaces/IPostMigrate.sol',
  'contracts/tokens/StandardToken.sol',
  'contracts/tokens/TaxToken.sol',
  'contracts/tokens/ReflectionToken.sol',
  // ── AggregatorRouter ──────────────────────────────────────────────────────
  'AggregatorRouter/interfaces/IAdapter.sol',
  'AggregatorRouter/OneMEMEAggregator.sol',
  'AggregatorRouter/adapters/BaseAdapter.sol',
  'AggregatorRouter/adapters/GenericV2Adapter.sol',
  'AggregatorRouter/adapters/GenericV3Adapter.sol',
  'AggregatorRouter/adapters/OneMEMEAdapter.sol',
  'AggregatorRouter/adapters/FourMEMEAdapter.sol',
  'AggregatorRouter/adapters/GenericV4Adapter.sol',
  'AggregatorRouter/adapters/PancakeSwapAdapter.sol',
  'AggregatorRouter/adapters/UniswapAdapter.sol',
  'AggregatorRouter/adapters/FlapSHAdapter.sol',
];

// ── Build source map ─────────────────────────────────────────────────────────
const sources = {};
let missing = false;
for (const f of CONTRACT_FILES) {
  const abs = path.join(__dirname, f);
  if (!fs.existsSync(abs)) {
    console.error('✗ Missing:', f);
    missing = true;
  } else {
    sources[f] = { content: fs.readFileSync(abs, 'utf8') };
  }
}
if (missing) process.exit(1);

// ── Compiler input ───────────────────────────────────────────────────────────
const outputSelection = {};
for (const f of CONTRACT_FILES) {
  outputSelection[f] = { '*': ['abi', 'evm.bytecode.object'] };
}

const compilerInput = JSON.stringify({
  language: 'Solidity',
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    viaIR: true,   // ← required: prevents stack-too-deep in BondingCurve
    outputSelection,
  },
});

// ── Compile ──────────────────────────────────────────────────────────────────
console.log('Compiling with solc', solc.version(), '(viaIR: true, optimizer: 200 runs)…');
const output = JSON.parse(solc.compile(compilerInput));

// ── Report errors / warnings ─────────────────────────────────────────────────
const errors   = (output.errors || []).filter(e => e.severity === 'error');
const warnings = (output.errors || []).filter(e => e.severity === 'warning');

if (errors.length) {
  console.error('\n── Errors (' + errors.length + ') ──────────────────────────────────────');
  errors.forEach(e => console.error(e.formattedMessage || e.message));
  process.exit(1);
}

if (VERBOSE && warnings.length) {
  console.log('\n── Warnings (' + warnings.length + ') ─────────────────────────────────────');
  warnings.forEach(w => console.log(w.formattedMessage || w.message));
}

// ── Write artifacts ──────────────────────────────────────────────────────────
if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR);

let written = 0;
for (const [file, contracts] of Object.entries(output.contracts || {})) {
  for (const [contractName, artifact] of Object.entries(contracts)) {
    // Skip pure interfaces (empty bytecode is expected, but save ABI anyway)
    const isInterface = contractName.startsWith('I') && contractName[1] === contractName[1].toUpperCase();
    const bytecode = artifact.evm?.bytecode?.object || '';
    const abi      = artifact.abi || [];

    const base = path.join(OUT_DIR, contractName);
    fs.writeFileSync(base + '.abi', JSON.stringify(abi, null, 2));
    if (bytecode && !isInterface) {
      fs.writeFileSync(base + '.bin', bytecode);
    }
    written++;
    const sizeKB = bytecode ? (bytecode.length / 2 / 1024).toFixed(1) + ' KB' : '(interface)';
    console.log('  ✓', contractName.padEnd(22), sizeKB);
  }
}

console.log('\nCompilation successful —', written, 'artifact(s) written to', OUT_DIR + '/');
if (!VERBOSE && warnings.length) {
  console.log(warnings.length, 'warning(s) suppressed. Run with --verbose to show them.');
}
