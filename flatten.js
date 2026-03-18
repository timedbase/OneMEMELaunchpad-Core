#!/usr/bin/env node
/**
 * flatten.js — OneMEME Core Contracts
 *
 * Produces self-contained single-file versions of each deployable contract
 * in out/flat/.  Each output file has all imports inlined and is ready for
 * single-file verification on BSCScan / block explorers.
 *
 * Usage:
 *   node flatten.js
 */

'use strict';

const fs   = require('fs');
const path = require('path');

const ROOT    = __dirname;
const OUT_DIR = path.join(ROOT, 'out', 'flat');

const TARGETS = [
  'contracts/tokens/StandardToken.sol',
  'contracts/tokens/TaxToken.sol',
  'contracts/tokens/ReflectionToken.sol',
  'contracts/BondingCurve.sol',
  'contracts/LaunchpadFactory.sol',
];

// ── Recursive flattener ───────────────────────────────────────────────────────

function flatten(entryFile) {
  const visited = new Set();   // absolute paths already inlined
  const chunks  = [];          // collected source chunks (no pragma/SPDX)
  let   license = null;
  let   pragma  = null;

  function processFile(absFile) {
    if (visited.has(absFile)) return;
    visited.add(absFile);

    const src  = fs.readFileSync(absFile, 'utf8');
    const dir  = path.dirname(absFile);
    const lines = src.split('\n');
    const kept  = [];

    for (const line of lines) {
      const trimmed = line.trim();

      // Capture SPDX — keep only the first one encountered
      if (trimmed.startsWith('// SPDX-License-Identifier:')) {
        if (!license) license = line;
        continue;
      }

      // Capture pragma — keep only the first one encountered
      if (trimmed.startsWith('pragma ')) {
        if (!pragma) pragma = line;
        continue;
      }

      // Resolve and inline imports
      const importMatch = trimmed.match(/^import\s+["'](.+?)["']\s*;/);
      if (importMatch) {
        const importPath = importMatch[1];
        const absImport  = path.resolve(dir, importPath);
        processFile(absImport);
        continue;
      }

      kept.push(line);
    }

    // Strip leading/trailing blank lines from the chunk
    while (kept.length && kept[0].trim() === '')  kept.shift();
    while (kept.length && kept[kept.length - 1].trim() === '') kept.pop();

    if (kept.length) {
      chunks.push('// ── ' + path.relative(ROOT, absFile) + ' ──');
      chunks.push(...kept);
      chunks.push('');
    }
  }

  processFile(path.resolve(ROOT, entryFile));

  const output = [
    (license || '// SPDX-License-Identifier: MIT'),
    (pragma  || 'pragma solidity ^0.8.32;'),
    '',
    ...chunks,
  ].join('\n');

  return output;
}

// ── Main ─────────────────────────────────────────────────────────────────────

if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });

for (const target of TARGETS) {
  const name    = path.basename(target);
  const outFile = path.join(OUT_DIR, name);
  const flat    = flatten(target);
  fs.writeFileSync(outFile, flat);
  const lines = flat.split('\n').length;
  console.log('✓', name.padEnd(26), lines, 'lines →', path.relative(ROOT, outFile));
}

console.log('\nFlattened files written to out/flat/');
console.log('Use these for single-file verification on BSCScan.');
