#!/usr/bin/env node

'use strict';

const path = require('path');
const { run, status } = require('../lib/install');

const args = process.argv.slice(2);
const command = args.find(a => !a.startsWith('--')) ?? 'run';
const force = args.includes('--force');
const dryRun = args.includes('--dry-run');
const interactive = args.includes('--interactive');

function ensureBundler() {
  const { spawnSync } = require('child_process');

  // `shell: true` so `bundle.bat` is resolved on Windows; on POSIX it still
  // runs through the user's shell which resolves `bundle` from PATH normally.
  const check = spawnSync('bundle', ['--version'], { stdio: 'ignore', shell: true });
  if (check.status === 0) return true;

  console.error('bundler not found on PATH; attempting to install with `gem install bundler`...');
  const install = spawnSync('gem', ['install', 'bundler', '--no-document', '--user-install'], {
    stdio: 'inherit',
    env: process.env,
    shell: true,
  });

  if (install.status === 0) {
    // `gem install --user-install` writes to ~/.gem/ruby/X.Y.Z/bin which is
    // often not on PATH by default. Discover it via `gem env` and prepend it
    // so the recheck can find the newly-installed `bundle` executable.
    const gemEnv = spawnSync('gem', ['env', 'user_gemhome'], { encoding: 'utf8', shell: true });
    if (gemEnv.status === 0) {
      const userGemHome = gemEnv.stdout.trim();
      const userBinDir = path.join(userGemHome, 'bin');
      process.env.PATH = userBinDir + path.delimiter + process.env.PATH;
    }

    const recheck = spawnSync('bundle', ['--version'], { stdio: 'ignore', shell: true });
    if (recheck.status === 0) return true;
    console.error(
      'bundler was installed but `bundle` is still not on PATH. ' +
      'You may need to add Ruby\'s gem user-install bin directory to your PATH ' +
      '(see `gem env` -> "USER INSTALLATION DIRECTORY").'
    );
    return false;
  }

  console.error(
    'Failed to install bundler automatically. ' +
    'Please install Ruby (>= 3.0) with bundler available, e.g. `gem install bundler`, then retry.'
  );
  return false;
}

switch (command) {
  case 'run': {
    run({ force, dryRun });
    if (dryRun) break;

    const { spawn, spawnSync } = require('child_process');
    const orchestratorDir = path.join(__dirname, '../orchestrator');
    const script = path.join(orchestratorDir, 'run.rb');

    if (!ensureBundler()) {
      process.exit(1);
    }

    const install = spawnSync('bundle', ['install'], {
      cwd: orchestratorDir,
      stdio: ['ignore', 'inherit', 'inherit'],
      env: process.env,
      shell: true,
    });
    if (install.status !== 0) {
      console.error(
        '\n`bundle install` failed in ' + orchestratorDir + '.\n' +
        'Make sure you have Ruby (>= 3.0) and bundler installed (`gem install bundler`),\n' +
        'then retry. If the problem persists, try `cd ' + orchestratorDir + ' && bundle install`\n' +
        'directly to see the full error.'
      );
      process.exit(install.status ?? 1);
    }

    const proc = spawn('ruby', [script], {
      stdio: 'inherit',
      env: {
        ...process.env,
        BUNDLE_GEMFILE: path.join(orchestratorDir, 'Gemfile'),
        ORCHESTRATOR_INTERACTIVE: interactive ? '1' : '',
      },
    });
    proc.on('exit', code => process.exit(code ?? 0));
    break;
  }
  case 'status':
    status();
    break;
  default:
    console.error(`Unknown command: ${command}`);
    console.error('Usage: npx autonomous-product-team [run|status] [--force] [--dry-run] [--interactive]');
    process.exit(1);
}
