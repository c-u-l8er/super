#!/usr/bin/env node
// Does the consent-admission suite actually hold anything up?
//
// `Ampd.Approvals.admit_consent/2` is a fail-closed predicate, and the failure
// mode a fail-closed design hides behind is a test that would pass even if the
// check were gone. So each refusal is removed in turn — by making it ADMIT,
// not by deleting the clause — and the suite is required to go red for each.
//
// Two disciplines, both learned expensively in this tree:
//
//   * **An unapplied stub is not a passing case.** If the exact substring is
//     not present exactly once, the case is UNAPPLIED and reported as such.
//     A harness that cannot tell "the mechanism was removed and nothing
//     noticed" from "the mechanism was never removed" reports the wrong
//     verdict with total confidence — the same defect it exists to find.
//   * **A compile failure is not a catch.** Red because the file no longer
//     builds proves nothing about the suite, so that outcome is BROKE and is
//     counted separately from CAUGHT.
//
// The file is restored from the bytes read at the start and the restoration is
// verified, so a crash mid-run cannot leave a sabotaged predicate behind.

import {readFileSync, writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {dirname, join} from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SOURCE = join(ROOT, 'ampd/lib/ampd/approvals.ex');
const SUITE = 'test/consent_admission_test.exs';

// Each case makes ONE refusal admit. The reason string is what the suite
// asserts on, so removing it is exactly removing the check.
const CASES = [
  ['approval-not-found (no record)', 'def admit_consent(nil, _claim), do: {:refused, "approval-not-found"}',
                                     'def admit_consent(nil, _claim), do: :ok'],
  ['claim-incomplete',               '{:refused, "claim-incomplete"}\n\n      a["id"] != claim["approval_id"] ->',
                                     ':ok\n\n      a["id"] != claim["approval_id"] ->'],
  ['approval-not-found (id mismatch)', 'a["id"] != claim["approval_id"] ->\n        {:refused, "approval-not-found"}',
                                       'a["id"] != claim["approval_id"] ->\n        :ok'],
  ['approval-not-pending',           '{:refused, "approval-not-pending"}', ':ok'],
  ['intent-changed',                 '{:refused, "intent-changed"}', ':ok'],
  ['world-moved',                    '{:refused, "world-moved"}', ':ok'],
  ['presentation-mismatch',          '{:refused, "presentation-mismatch"}', ':ok'],
  ['consent-replayed',               '{:refused, "consent-replayed"}', ':ok'],
  ['presentation-expired',           '{:refused, "presentation-expired"}', ':ok'],
  ['decision-unrecognised',          '{:refused, "decision-unrecognised"}', ':ok'],
  // The two halves of freshness, separately: a window with no lower bound
  // accepts a future stamp, and a lower bound with no window never expires.
  ['freshness · the window',         'delta >= 0 and delta <= @consent_window_seconds', 'delta >= 0'],
  ['freshness · the future guard',   'delta >= 0 and delta <= @consent_window_seconds', 'delta <= @consent_window_seconds'],
  // Not a refusal — the other property the suite asserts.
  ['presentation withholds held_ctx', '"world_generation" => a["world_generation"]\n    }',
                                      '"world_generation" => a["world_generation"],\n      "held_ctx" => a["held_ctx"]\n    }'],
];

const original = readFileSync(SOURCE, 'utf8');
const originalDigest = createHash('sha256').update(original).digest('hex');
const G = '\x1b[32m', R = '\x1b[31m', Y = '\x1b[33m', X = '\x1b[0m';

function runSuite() {
  try {
    execFileSync('mix', ['test', SUITE], {
      cwd: join(ROOT, 'ampd'), encoding: 'utf8', stdio: 'pipe',
      env: {...process.env, MIX_ENV: 'test'},
    });
    return {red: false, output: ''};
  } catch (e) {
    return {red: true, output: `${e.stdout ?? ''}${e.stderr ?? ''}`};
  }
}

// A build that failed is not a suite that caught something.
const brokeBuild = out => /\*\* \(CompileError\)|error: |unable to compile/.test(out)
                       && !/test[s]?, \d+ failure/.test(out);

let caught = 0, missed = 0, unapplied = 0, broke = 0;
console.log('\nsabotage — consent admission\n');

try {
  for (const [name, from, to] of CASES) {
    const occurrences = original.split(from).length - 1;
    if (occurrences !== 1) {
      console.log(`  ${Y}UNAPPLIED${X}  ${name}  (matched ${occurrences} times, needs exactly 1)`);
      unapplied++;
      continue;
    }
    writeFileSync(SOURCE, original.replace(from, to));
    const {red, output} = runSuite();
    if (!red) {
      console.log(`  ${R}NOT A FALSIFIER${X}  ${name}  — removed, suite stayed green`);
      missed++;
    } else if (brokeBuild(output)) {
      console.log(`  ${Y}BROKE${X}  ${name}  — red because it would not compile, which proves nothing`);
      broke++;
    } else {
      console.log(`  ${G}caught${X}  ${name}`);
      caught++;
    }
  }
} finally {
  writeFileSync(SOURCE, original);
  const restored = createHash('sha256').update(readFileSync(SOURCE, 'utf8')).digest('hex');
  if (restored !== originalDigest) {
    console.error(`\n${R}RESTORATION FAILED${X} — ${SOURCE} does not match the bytes read at start.`);
    process.exit(2);
  }
}

// The baseline matters as much as the cases: if the suite is red before any
// sabotage, every "caught" above is meaningless.
const baseline = runSuite();
if (baseline.red) {
  console.error(`\n${R}BASELINE RED${X} — the suite fails on the restored source, so nothing above counts.`);
  process.exit(2);
}

console.log(`\nsabotage: ${caught} caught · ${missed} NOT A FALSIFIER · ${unapplied} unapplied · ${broke} broke`);
console.log('baseline on restored source: green\n');
process.exit(missed + unapplied + broke === 0 ? 0 : 1);
