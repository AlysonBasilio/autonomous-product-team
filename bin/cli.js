#!/usr/bin/env node

'use strict';

const { run, status } = require('../lib/install');

const args = process.argv.slice(2);
const command = args.find(a => !a.startsWith('--')) ?? 'init';
const force = args.includes('--force');
const dryRun = args.includes('--dry-run');

switch (command) {
  case 'init':
    run({ force, dryRun });
    break;
  case 'update':
    run({ force: true, dryRun });
    break;
  case 'status':
    status();
    break;
  default:
    console.error(`Unknown command: ${command}`);
    console.error('Usage: npx autonomous-product-team [init|update|status] [--force] [--dry-run]');
    process.exit(1);
}
