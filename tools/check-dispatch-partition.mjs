/* check-dispatch-partition — C1.0b·2·2, the read/mutation boundary as a
   property of the call graph rather than of a runtime comparison.
   ────────────────────────────────────────────────────────────────────────

   THE LAW

     A command that can execute inside an ordered projection and a command
     that can never execute there are implemented in DIFFERENT functions,
     and which one a command lands in is derived from `Ampd.CommandSpec`.

   Before this slice `Ampd.Control.in_lineage/4` built one closure over one
   `dispatch/3` and chose at runtime:

       run = fn -> dispatch(peer, cmd, args) end
       cond do
         cmd in @retry_once -> Projection.framed_once(lineage, run)
         cmd in @reads      -> Projection.framed(lineage, run)
         true               -> run.()          # not ordered
       end

   The behaviour was right and the proof was unavailable. `framed/2` is one
   of `tools/ordered-reachability.exs`'s root signatures, and `dispatch/3`
   was ONE compiled function holding all 38 clauses — so every mutation
   subtree was reachable from an ordered root as far as any static reader
   could tell. Adding one legitimate agent mutation opened fourteen
   unadjudicated crossings, and the only thing that had ever kept an
   unbounded host round trip out of the coordinator was a `kind:` value in a
   map in a different file.

   This gate exists so that the two halves cannot drift back together, and
   so that the dangerous edit fails HERE rather than by quietly moving a
   mutation inside the total order:

     * the declaration lives once, in `Ampd.CommandSpec`
     * each dispatcher's clause set is checked against it exactly
     * neither dispatcher may call the other
     * the generic `dispatch/3` must not come back

   Run: node tools/check-dispatch-partition.mjs                            */

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const AMPD = `${ROOT}/ampd`;

let held = 0;
let failed = 0;

function check(name, ok, detail = '') {
  if (ok) { held++; console.log(`  \x1b[32mheld\x1b[0m         ${name}`); }
  else {
    failed++;
    console.log(`  \x1b[31mFAILED\x1b[0m       ${name}`);
    if (detail) console.log(`               ${detail}`);
  }
}

console.log('[&] Super — command dispatch partition\n');

/* **Read out of the runtime, not out of the source.** `reads/0` and
   `mutations/0` are derived from the `kind:` field; re-deriving them here
   from the same table would be this gate agreeing with its own copy. */
function spec(expr) {
  /* **A gate that throws prints no FAILED line.** The first sabotage run of
     this file died here with a stack trace, because flipping a `kind:` makes
     `Ampd.CommandSpec` refuse to COMPILE — which is the right answer and the
     wrong output: `tools/sabotage-*.sh` decides a probe is a falsifier by
     grepping the runner's output for a failure it names, and an exception
     matches nothing. So the compile failure is reported as the named check
     it is. */
  try {
    return execFileSync('mix', ['run', '--no-start', '-e', `IO.write(${expr})`], {
      cwd: AMPD, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (e) {
    const why = String(e.stderr ?? e.message).trim().split('\n').slice(0, 4).join(' ');
    check('Ampd.CommandSpec compiles and can be asked for its classification', false, why);
    console.log(`\ndispatch partition: ${held} held · ${failed} failed`);
    process.exit(1);
  }
}

const list = (e) => spec(`Enum.join(${e}, " ")`).split(/\s+/).filter(Boolean).sort();
const READS = list('Ampd.CommandSpec.reads()');
const MUTATIONS = list('Ampd.CommandSpec.mutations()');
const RETRY_ONCE = list('Ampd.CommandSpec.retry_once()');

const src = readFileSync(`${ROOT}/ampd/lib/ampd/control.ex`, 'utf8');
const lines = src.split('\n');

/* The clause heads of one dispatcher, by the command atom each answers. */
function clausesOf(fn) {
  const re = new RegExp(`^  defp ${fn}\\(\\s*_?peer,\\s*:(\\w+)`);
  return [...new Set(lines.map((l) => (l.match(re) ?? [])[1]).filter(Boolean))].sort();
}

/* The source text of one dispatcher: its first clause head through the last
   line before the next top-level `defp` that is not one of its own. */
function regionOf(fn) {
  const head = new RegExp(`^  defp ${fn}\\(`);
  const start = lines.findIndex((l) => head.test(l));
  if (start < 0) return '';
  let end = start;
  for (let i = start; i < lines.length; i += 1) {
    if (/^  defp? \w/.test(lines[i]) && !head.test(lines[i])) { end = i; break; }
    end = i + 1;
  }
  return lines.slice(start, end).join('\n');
}

const readClauses = clausesOf('dispatch_read');
const mutClauses = clausesOf('dispatch_mutation');

check(
  'both dispatchers exist and neither is empty',
  readClauses.length > 0 && mutClauses.length > 0,
  `read=${readClauses.length} mutation=${mutClauses.length}`,
);

/* **The generic dispatcher must not come back.** One function holding both
   classes is the entire defect; a `dispatch/3` beside these two would be a
   third path with no class at all. */
check(
  'the generic `dispatch/3` no longer exists',
  !/^  defp dispatch\(/m.test(src),
  'a clause of the collapsed dispatcher is back — every mutation subtree it '
    + 'can reach becomes ordered-reachable again',
);

/* **`runtime_status` is answered before the peer is resolved**, so it never
   reaches a dispatcher. That is deliberate — a caller with no binding may
   still ask whether the runtime is healthy — and it is derived here rather
   than subtracted by hand, because "the set minus the one I know about" is
   how a second one gets in unnoticed. */
const preDispatch = [
  ...new Set(
    lines
      .map((l) => (l.match(/^  def command\(\s*_?peer_id,\s*:(\w+)/) ?? [])[1])
      .filter(Boolean),
  ),
].sort();

check(
  'a command answered before the peer is resolved is always a READ',
  preDispatch.every((c) => READS.includes(c)),
  `answered in command/3 but not a read: ${preDispatch.filter((c) => !READS.includes(c)).join(', ')}`,
);

const readTotal = [...new Set([...readClauses, ...preDispatch])].sort();
const eq = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

check(
  'every READ is implemented in dispatch_read, or answered before dispatch — and nothing else is',
  eq(readTotal, READS),
  `spec reads: ${READS.join(' ')}\n               implemented: ${readTotal.join(' ')}`,
);

check(
  'every MUTATION is implemented in dispatch_mutation — and nothing else is',
  eq(mutClauses, MUTATIONS),
  `spec mutations: ${MUTATIONS.join(' ')}\n               implemented: ${mutClauses.join(' ')}`,
);

check(
  'no command is implemented in both halves',
  readClauses.every((c) => !mutClauses.includes(c)),
  `in both: ${readClauses.filter((c) => mutClauses.includes(c)).join(', ')}`,
);

check(
  'every retry-once command is a read — the ordered-once path has no mutation on it',
  RETRY_ONCE.every((c) => READS.includes(c)),
  `retry_once entries that are not reads: ${RETRY_ONCE.filter((c) => !READS.includes(c)).join(', ')}`,
);

/* **The edge that must not exist.** The census follows calls; one call from
   the read half into the mutation half puts every mutation subtree back
   inside the order, and the exclusions removed by this slice would all have
   to come back. */
const readRegion = regionOf('dispatch_read');
const mutRegion = regionOf('dispatch_mutation');

check(
  'dispatch_read never calls dispatch_mutation',
  !/dispatch_mutation\(/.test(readRegion),
  'an ordered read reaches the mutation half — the partition is a call-graph '
    + 'fact or it is nothing',
);

check(
  'dispatch_mutation never calls dispatch_read',
  !/dispatch_read\(/.test(mutRegion),
  'the mutation half reaches the read half',
);

/* **And the branch that chooses.** The ordered arms must name the read
   dispatcher and the unordered arm the mutation one; swapping them would
   satisfy every set-equality above while running mutations in the
   coordinator. */
const inLineage = (src.match(/defp in_lineage\([\s\S]*?\n  end\n/) ?? [''])[0];

check(
  'the ordered arms dispatch READS and the unordered arm dispatches MUTATIONS',
  /framed_once\(lineage, fn -> dispatch_read\(/.test(inLineage)
    && /framed\(lineage, fn -> dispatch_read\(/.test(inLineage)
    && /true ->\s*\n\s*dispatch_mutation\(/.test(inLineage),
  `in_lineage/4 does not wire the two halves to the two paths:\n${inLineage}`,
);

check(
  'and nothing else in in_lineage/4 reaches a dispatcher',
  (inLineage.match(/dispatch_(read|mutation)\(/g) ?? []).length === 3,
  `dispatcher calls in in_lineage/4: ${(inLineage.match(/dispatch_(read|mutation)\(/g) ?? []).join(', ')}`,
);

console.log(
  `\n  ${READS.length} reads · ${MUTATIONS.length} mutations · `
  + `${readClauses.length} read clauses · ${mutClauses.length} mutation clauses`,
);
console.log(`dispatch partition: ${held} held · ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
