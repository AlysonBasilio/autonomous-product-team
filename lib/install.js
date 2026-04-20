'use strict';

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const MANIFEST = [
  { src: 'roles/team-manager.md', dest: '.claude/skills/team-manager/SKILL.md', transform: rewriteTaskPaths },
  { src: 'roles/team-member.md',  dest: '.claude/skills/team-member/SKILL.md' },
  { src: 'tasks/demo-review.md',         dest: '.claude/product-team/tasks/demo-review.md' },
  { src: 'tasks/code.md',                dest: '.claude/product-team/tasks/code.md' },
  { src: 'tasks/issue-triage.md',        dest: '.claude/product-team/tasks/issue-triage.md' },
  { src: 'tasks/plan.md',                dest: '.claude/product-team/tasks/plan.md' },
  { src: 'tasks/status-correction.md',   dest: '.claude/product-team/tasks/status-correction.md' },
  { src: 'tasks/test.md',                dest: '.claude/product-team/tasks/test.md' },
];

function rewriteTaskPaths(content) {
  return content.replace(/tasks\/([\w-]+\.md)/g, '.claude/product-team/tasks/$1');
}

const SETTINGS_PATH = '.claude/settings.json';

const REQUIRED_SETTINGS = {
  env: { CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1' },
  teammateMode: 'tmux',
};

function mergeSettings(projectRoot, dryRun) {
  const settingsPath = path.join(projectRoot, SETTINGS_PATH);
  const existing = fs.existsSync(settingsPath)
    ? JSON.parse(fs.readFileSync(settingsPath, 'utf8'))
    : {};

  const merged = {
    ...existing,
    ...REQUIRED_SETTINGS,
    env: { ...existing.env, ...REQUIRED_SETTINGS.env },
  };

  const action = fs.existsSync(settingsPath) ? 'updated' : 'installed';
  if (!dryRun) {
    fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
    fs.writeFileSync(settingsPath, JSON.stringify(merged, null, 2) + '\n');
  }
  return { dest: SETTINGS_PATH, action: dryRun ? `would ${action}` : action };
}

function ask(rl, question) {
  return new Promise(resolve => rl.question(question, resolve));
}

async function run({ force = false, dryRun = false } = {}) {
  const projectRoot = process.cwd();
  const packageRoot = path.join(__dirname, '..');

  const hasPackageJson = fs.existsSync(path.join(projectRoot, 'package.json'));
  const hasGit = fs.existsSync(path.join(projectRoot, '.git'));
  if (!hasPackageJson && !hasGit) {
    console.warn('Warning: No package.json or .git found. Make sure you are running this from your project root.');
  }

  const rl = (force || dryRun)
    ? null
    : readline.createInterface({ input: process.stdin, output: process.stdout });

  let overwriteAll = false;
  const results = [];

  for (const entry of MANIFEST) {
    const srcPath = path.join(packageRoot, entry.src);
    const destPath = path.join(projectRoot, entry.dest);
    const exists = fs.existsSync(destPath);

    if (exists && !force && !overwriteAll) {
      if (dryRun) {
        results.push({ dest: entry.dest, action: 'skip (exists)' });
        continue;
      }
      const answer = await ask(rl, `  ${entry.dest} already exists. [s]kip / [o]verwrite / [O]verwrite all? `);
      const choice = answer.trim();
      if (choice === 'O') {
        overwriteAll = true;
      } else if (choice !== 'o') {
        results.push({ dest: entry.dest, action: 'skipped' });
        continue;
      }
    }

    if (dryRun) {
      results.push({ dest: entry.dest, action: exists ? 'would overwrite' : 'would install' });
      continue;
    }

    fs.mkdirSync(path.dirname(destPath), { recursive: true });
    let content = fs.readFileSync(srcPath, 'utf8');
    if (entry.transform) content = entry.transform(content);
    fs.writeFileSync(destPath, content);
    results.push({ dest: entry.dest, action: exists ? 'updated' : 'installed' });
  }

  if (rl) rl.close();

  results.push(mergeSettings(projectRoot, dryRun));

  console.log('');
  for (const { dest, action } of results) {
    console.log(`  ${action.padEnd(12)} ${dest}`);
  }

  const installed = results.filter(r => r.action === 'installed' || r.action === 'updated');
  if (!dryRun && installed.length > 0) {
    console.log(`
Next steps:
  Open Claude Code in this project, then ask:
  "Use the team-manager agent to start working on my product"
  Or run /agents inside Claude Code to see available agents.
`);
  }
}

function status() {
  const projectRoot = process.cwd();
  console.log(`\nautonomous-product-team status in ${projectRoot}\n`);
  for (const entry of MANIFEST) {
    const exists = fs.existsSync(path.join(projectRoot, entry.dest));
    console.log(`  [${exists ? '✓' : '✗'}] ${entry.dest}`);
  }

  const settingsPath = path.join(projectRoot, SETTINGS_PATH);
  let settingsOk = false;
  if (fs.existsSync(settingsPath)) {
    try {
      const s = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
      settingsOk = s?.env?.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS === '1' && s?.teammateMode === 'tmux';
    } catch {}
  }
  console.log(`  [${settingsOk ? '✓' : '✗'}] ${SETTINGS_PATH} (agent teams settings)`);
  console.log('');
}

module.exports = { run, status };
