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
  { src: 'tasks/discovery.md',            dest: '.claude/product-team/tasks/discovery.md' },
  { src: 'tasks/status-correction.md',   dest: '.claude/product-team/tasks/status-correction.md' },
  { src: 'tasks/test.md',                dest: '.claude/product-team/tasks/test.md' },
  { src: 'hooks/guard-destructive-git.sh',  dest: '.claude/hooks/guard-destructive-git.sh',  mode: 0o755 },
  { src: 'hooks/guard-worktree-discipline.sh', dest: '.claude/hooks/guard-worktree-discipline.sh', mode: 0o755 },
  { src: 'hooks/load-session-context.sh',   dest: '.claude/hooks/load-session-context.sh',   mode: 0o755 },
  { src: 'hooks/log-agent-event.sh',        dest: '.claude/hooks/log-agent-event.sh',        mode: 0o755 },
];

function rewriteTaskPaths(content) {
  return content.replace(/tasks\/([\w-]+\.md)/g, '.claude/product-team/tasks/$1');
}

const SETTINGS_PATH = '.claude/settings.json';

const REQUIRED_SETTINGS = {
  env: { CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1' },
  teammateMode: 'tmux',
  hooks: {
    TeammateIdle: [
      {
        hooks: [
          {
            type: 'command',
            command: 'echo \'{"continue": false}\'',
          },
        ],
      },
    ],
    PreToolUse: [
      {
        matcher: 'Bash',
        hooks: [
          {
            type: 'command',
            command: '.claude/hooks/guard-destructive-git.sh',
            timeout: 10,
          },
        ],
      },
      {
        matcher: 'Edit|Write|MultiEdit',
        hooks: [
          {
            type: 'command',
            command: '.claude/hooks/guard-worktree-discipline.sh',
            timeout: 10,
          },
        ],
      },
    ],
    SessionStart: [
      {
        matcher: 'startup|resume',
        hooks: [
          {
            type: 'command',
            command: '.claude/hooks/load-session-context.sh',
            timeout: 10,
          },
        ],
      },
    ],
    SubagentStart: [
      {
        matcher: '*',
        hooks: [
          {
            type: 'command',
            command: '.claude/hooks/log-agent-event.sh',
            timeout: 10,
          },
        ],
      },
    ],
    SubagentStop: [
      {
        matcher: '*',
        hooks: [
          {
            type: 'command',
            command: '.claude/hooks/log-agent-event.sh',
            timeout: 10,
          },
        ],
      },
    ],
  },
};

function mergeHooks(existingHooks, requiredHooks) {
  const merged = { ...existingHooks };
  for (const [event, requiredEntries] of Object.entries(requiredHooks)) {
    if (!merged[event]) {
      merged[event] = requiredEntries;
      continue;
    }
    // For each required entry, check if a matching entry (same matcher) exists
    for (const required of requiredEntries) {
      const existingIdx = merged[event].findIndex(e => e.matcher === required.matcher);
      if (existingIdx === -1) {
        merged[event].push(required);
      } else {
        // Merge hooks arrays, avoiding duplicates by command
        const existingEntry = merged[event][existingIdx];
        for (const hook of required.hooks) {
          const hasDuplicate = existingEntry.hooks.some(h => h.command === hook.command);
          if (!hasDuplicate) {
            existingEntry.hooks.push(hook);
          }
        }
      }
    }
  }
  return merged;
}

function mergeSettings(projectRoot, dryRun) {
  const settingsPath = path.join(projectRoot, SETTINGS_PATH);
  const existing = fs.existsSync(settingsPath)
    ? JSON.parse(fs.readFileSync(settingsPath, 'utf8'))
    : {};

  const { hooks: requiredHooks, ...requiredRest } = REQUIRED_SETTINGS;
  const merged = {
    ...existing,
    ...requiredRest,
    env: { ...existing.env, ...requiredRest.env },
  };

  if (requiredHooks) {
    merged.hooks = mergeHooks(existing.hooks || {}, requiredHooks);
  }

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
    if (entry.mode) fs.chmodSync(destPath, entry.mode);
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
  let hooksOk = false;
  if (fs.existsSync(settingsPath)) {
    try {
      const s = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
      const hasAgentTeams = s?.env?.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS === '1';
      const hasTmux = s?.teammateMode === 'tmux';
      const hasIdleHook = Array.isArray(s?.hooks?.TeammateIdle) && s.hooks.TeammateIdle.length > 0;
      settingsOk = hasAgentTeams && hasTmux && hasIdleHook;
      hooksOk = !!(s?.hooks?.PreToolUse && s?.hooks?.SessionStart);
    } catch {}
  }
  console.log(`  [${settingsOk ? '✓' : '✗'}] ${SETTINGS_PATH} (agent teams settings)`);
  console.log(`  [${hooksOk ? '✓' : '✗'}] ${SETTINGS_PATH} (hooks configuration)`);
  console.log('');
}

module.exports = { run, status };
