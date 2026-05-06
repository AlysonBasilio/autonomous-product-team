'use strict';

const fs = require('fs');
const path = require('path');

const MANIFEST = [
  { src: 'tasks/demo-review.md',       dest: 'tasks/demo-review.md' },
  { src: 'tasks/code.md',              dest: 'tasks/code.md' },
  { src: 'tasks/issue-triage.md',      dest: 'tasks/issue-triage.md' },
  { src: 'tasks/plan.md',              dest: 'tasks/plan.md' },
  { src: 'tasks/create-issue.md',      dest: 'tasks/create-issue.md' },
  { src: 'tasks/discovery.md',         dest: 'tasks/discovery.md' },
  { src: 'tasks/status-correction.md', dest: 'tasks/status-correction.md' },
  { src: 'tasks/test.md',              dest: 'tasks/test.md' },
];

const GITIGNORE_ENTRIES = [
  'orchestrator-state.json',
];

function mergeGitignore(projectRoot, dryRun) {
  const gitignorePath = path.join(projectRoot, '.gitignore');
  const existing = fs.existsSync(gitignorePath)
    ? fs.readFileSync(gitignorePath, 'utf8')
    : '';

  const missing = GITIGNORE_ENTRIES.filter(e => !existing.includes(e));
  if (missing.length === 0) {
    return { dest: '.gitignore', action: dryRun ? 'skip (up to date)' : 'up to date' };
  }

  const block = '\n# autonomous-product-team\n' + missing.join('\n') + '\n';
  if (!dryRun) {
    fs.writeFileSync(gitignorePath, existing + block);
  }
  return { dest: '.gitignore', action: dryRun ? 'would update' : 'updated' };
}

function run({ force = false, dryRun = false } = {}) {
  const projectRoot = process.cwd();
  const packageRoot = path.join(__dirname, '..');

  const hasPackageJson = fs.existsSync(path.join(projectRoot, 'package.json'));
  const hasGit = fs.existsSync(path.join(projectRoot, '.git'));
  if (!hasPackageJson && !hasGit) {
    console.warn('Warning: No package.json or .git found. Make sure you are running this from your project root.');
  }

  const results = [];

  for (const entry of MANIFEST) {
    const srcPath = path.join(packageRoot, entry.src);
    const destPath = path.join(projectRoot, entry.dest);
    const exists = fs.existsSync(destPath);

    if (exists && (entry.skipOverwrite || !force)) {
      results.push({ dest: entry.dest, action: dryRun ? 'skip (exists)' : 'preserved' });
      continue;
    }

    if (dryRun) {
      results.push({ dest: entry.dest, action: exists ? 'would overwrite' : 'would install' });
      continue;
    }

    fs.mkdirSync(path.dirname(destPath), { recursive: true });
    const content = fs.readFileSync(srcPath, 'utf8');
    fs.writeFileSync(destPath, content);
    if (entry.mode) fs.chmodSync(destPath, entry.mode);
    results.push({ dest: entry.dest, action: exists ? 'updated' : 'installed' });
  }

  results.push(mergeGitignore(projectRoot, dryRun));

  console.log('');
  for (const { dest, action } of results) {
    console.log(`  ${action.padEnd(12)} ${dest}`);
  }
  console.log('');
}

function status() {
  const projectRoot = process.cwd();
  console.log(`\nautonomous-product-team status in ${projectRoot}\n`);
  for (const entry of MANIFEST) {
    const exists = fs.existsSync(path.join(projectRoot, entry.dest));
    console.log(`  [${exists ? '✓' : '✗'}] ${entry.dest}`);
  }

  const statePath = path.join(projectRoot, 'orchestrator-state.json');
  let configStatus = 'not configured (set via web UI)';
  if (fs.existsSync(statePath)) {
    try {
      const s = JSON.parse(fs.readFileSync(statePath, 'utf8'));
      const c = s.config;
      const required = ['project_url', 'tenant', 'api_key'];
      if (c && required.every(k => c[k])) {
        configStatus = c.project_url;
      }
    } catch {
      configStatus = 'invalid state file';
    }
  }
  const configOk = configStatus.startsWith('not configured') === false && configStatus !== 'invalid state file';
  console.log(`  [${configOk ? '✓' : '✗'}] orchestrator config (${configStatus})`);

  const gitignorePath = path.join(projectRoot, '.gitignore');
  const gitignoreOk = fs.existsSync(gitignorePath) &&
    GITIGNORE_ENTRIES.every(e => fs.readFileSync(gitignorePath, 'utf8').includes(e));
  console.log(`  [${gitignoreOk ? '✓' : '✗'}] .gitignore`);
  console.log('');
}

module.exports = { run, status };
