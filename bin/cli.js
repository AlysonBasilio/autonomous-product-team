#!/usr/bin/env node

'use strict';

const path = require('path');
const { run, status } = require('../lib/install');

const args = process.argv.slice(2);
const command = args.find(a => !a.startsWith('--')) ?? 'run';
const force = args.includes('--force');
const dryRun = args.includes('--dry-run');

switch (command) {
  case 'run': {
    run({ force, dryRun });
    if (dryRun) break;

    const { spawn, spawnSync } = require('child_process');
    const orchestratorDir = path.join(__dirname, '../orchestrator');
    const script = path.join(orchestratorDir, 'run.rb');

    const install = spawnSync('bundle', ['install'], {
      cwd: orchestratorDir,
      stdio: ['ignore', 'ignore', 'inherit'],
      env: process.env,
    });
    if (install.status !== 0) process.exit(install.status ?? 1);

    const proc = spawn('ruby', [script], {
      stdio: 'inherit',
      env: { ...process.env, BUNDLE_GEMFILE: path.join(orchestratorDir, 'Gemfile') },
    });
    proc.on('exit', code => process.exit(code ?? 0));
    break;
  }
  case 'status':
    status();
    break;
  default:
    console.error(`Unknown command: ${command}`);
    console.error('Usage: npx autonomous-product-team [run|status] [--force] [--dry-run]');
    process.exit(1);
}
