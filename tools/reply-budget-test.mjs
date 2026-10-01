// T26 · L5 (the page states the host's budget) and L6 (S1 is warned, never changed). superlane/t26/TASK.md.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {REPLY_BUDGET_S, replyBudget, waitingText, MAX_EFFORT_WARNING, effortWarning} from '../cockpit/ui/reply-budget.js';

/* The host's table, read from its source: every arm of `reply_budget`'s match. `Some(_)` is the unknown-level floor. */
function hostTable() {
  const rust = readFileSync(new URL('../cockpit/src/claude_connection.rs', import.meta.url), 'utf8');
  const body = rust.match(/fn reply_budget\(effort: Option<&str>\) -> u64 \{([\s\S]*?)\n\}/);
  assert.ok(body, 'reply_budget is in claude_connection.rs');
  const table = {};
  for (const [, arm, seconds] of body[1].matchAll(/^\s*(None|Some\([^)]*\))\s*=>\s*(\d+),/gm)) {
    if (arm === 'None') table[''] = Number(seconds);
    else if (arm === 'Some(_)') table['?'] = Number(seconds);
    else for (const [, level] of arm.matchAll(/"([a-z]+)"/g)) table[level] = Number(seconds);
  }
  return table;
}

test('T26 L5 · the page states exactly the budget the host enforces, for every level', () => {
  const host = hostTable();
  const {'?': floor, ...levels} = host;
  assert.deepEqual(levels, {...REPLY_BUDGET_S}, 'the page table is the host table');
  assert.equal(replyBudget('enormous'), floor, 'an unknown level gets the host floor');
  assert.equal(replyBudget(null), host['']);
  assert.equal(replyBudget(undefined), host['']);
});

test('T26 L5 · the predeclared table: no level under 30 minutes, the default as high, never decreasing', () => {
  assert.deepEqual({...REPLY_BUDGET_S}, {'': 1800, low: 1800, medium: 1800, high: 1800, xhigh: 2700, max: 3600});
  const order = ['', 'low', 'medium', 'high', 'xhigh', 'max'].map(replyBudget);
  assert.ok(order.every((s, i) => i === 0 || order[i - 1] <= s), String(order));
});

test('T26 L5 · the waiting line names the minutes of the level that was sent', () => {
  assert.equal(waitingText('claude', 'high'), 'Waiting for claude… Replies can take up to 30 minutes.');
  assert.equal(waitingText('claude', ''), 'Waiting for claude… Replies can take up to 30 minutes.');
  assert.equal(waitingText('claude', 'xhigh'), 'Waiting for claude… Replies can take up to 45 minutes.');
  assert.equal(waitingText('claude', 'max'), 'Waiting for claude… Replies can take up to 60 minutes.');
  assert.equal(waitingText('codex', 'high'), 'Waiting for Codex… Large file replies can take up to five minutes.');
  assert.equal(waitingText('ollama', ''), 'Waiting for ollama… Replies can take up to two minutes.');
});

test('T26 L6 · max is warned with what was measured; no other level is, and nothing is changed', () => {
  assert.equal(effortWarning('max'), MAX_EFFORT_WARNING);
  assert.match(MAX_EFFORT_WARNING, /128,000 tokens/);
  assert.match(MAX_EFFORT_WARNING, /sent as chosen/);
  for (const level of ['', null, undefined, 'low', 'medium', 'high', 'xhigh']) assert.equal(effortWarning(level), null, String(level));
});
