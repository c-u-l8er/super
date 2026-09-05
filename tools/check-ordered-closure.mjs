#!/usr/bin/env node
/**
 * check-ordered-closure — the ordered boundary is CLOSED, or it names what
 * is open and why.
 *
 * `check-ordered-boundary.mjs` counts `GenServer.call(__MODULE__, …)` per
 * module. That is a ratchet: it cannot grow without someone noticing, and it
 * is worth keeping. It is not a completeness claim, and the script says so
 * itself — it counts client helpers no transaction reaches and misses every
 * call made to another module by name.
 *
 * This gate asks the other question:
 *
 *     which cross-process calls are transitively reachable while executing
 *     an AuthorityCoordinator ordered transaction or ordered observation,
 *     and is every one of them either routed through Ampd.Participant with
 *     an explicit class or excluded for a stated reason?
 *
 * The census is DERIVED, from compiled BEAM abstract code, by
 * `tools/ordered-reachability.exs` — which this gate runs, so it cannot go
 * stale against the source. The adjudication is authored, in
 * `tools/ordered-boundary-exclusions.json`.
 *
 * Three ways to fail, and the third is the one that matters:
 *
 *   1  a reachable crossing that is neither converted nor excluded
 *   2  a place the census cannot see that nobody has adjudicated
 *   3  an exclusion that no longer matches anything — a stale reason
 *      outliving the crossing it excused is how a gate goes green over a
 *      boundary that changed underneath it
 */
import { readFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

// **Derived, never hardcoded.** This was the absolute path of one checkout,
// so running the gate from a detached worktree silently measured the
// CANONICAL tree instead — a green verdict about source the run never saw.
// R0b.R needed an isolated parent and would have gated against the wrong one.
const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '')
const CENSUS = join(ROOT, 'tools/ordered-reachability.json')
const RULES = join(ROOT, 'tools/ordered-boundary-exclusions.json')

let fail = 0
const ok = (m) => console.log(`  \x1b[32mheld\x1b[0m  ${m}`)
const no = (m, why) => { console.log(`  \x1b[31mFAIL\x1b[0m  ${m} — ${why}`); fail++ }

// Regenerate rather than read: a census committed alongside source it no
// longer describes is worse than no census.
try {
  execFileSync('elixir', ['tools/ordered-reachability.exs'], { cwd: ROOT, stdio: 'pipe' })
} catch (e) {
  console.error('REFUSING — could not derive the census:', e.stderr?.toString() || e.message)
  process.exit(2)
}

if (!existsSync(CENSUS) || !existsSync(RULES)) {
  console.error('REFUSING — census or exclusions missing')
  process.exit(2)
}

const census = JSON.parse(readFileSync(CENSUS, 'utf8'))
const rules = JSON.parse(readFileSync(RULES, 'utf8'))

console.log(`\n  ordered closure · ${census.crossings.length} crossing(s) reachable inside the total order`)
console.log(`                     ${census.roots.count} root(s), ${census.functions_reached} function(s), ${census.opaque.length} opaque site(s)\n`)

// ---------------------------------------------------------------- 1 · crossings
const usedX = new Set()
for (const c of census.crossings) {
  if (c.kind === 'converted') { ok(`${c.in} → ${c.participant} routes through Ampd.Participant`); continue }
  const reason = rules.crossings[c.id]
  if (reason) { usedX.add(c.id); ok(`${c.in} → ${c.participant} (${c.primitive}) excluded: ${reason.slice(0, 96)}…`) }
  else no(`${c.in} → ${c.participant} (${c.primitive})`, 'reachable inside the order, not converted, and not excluded')
}

// ---------------------------------------------------------------- 2 · opacity
//
// A census that silently drops what it cannot resolve reports a completeness
// it does not have. Every dynamic dispatch inside the order is named.
const usedO = new Set()
for (const o of census.opaque) {
  const key = `${o.in} ${o.why}`
  const reason = rules.opaque[key]
  if (reason) { usedO.add(key); ok(`${key} adjudicated: ${reason.slice(0, 84)}…`) }
  else no(key, 'the census cannot follow this dispatch and nothing says where it lands')
}

// ------------------------------------------- 2b · the behaviour dispatches
//
// Two of the opaque sites are adjudicated by NAMING the modules they can land
// on — `Ampd.Bootstrap.close_all!/0` and `reload_registries!/0`, both
// `registry_for(name).<op>()`. That adjudication is prose, and prose is what
// this gate exists not to trust. So read the dispatch table and require every
// module in it to declare a classification: a registry added to `registry_for/1`
// without a funnel would otherwise be reached from inside the order through a
// call the census cannot resolve, under an adjudication that was true when it
// was written.
const boot = readFileSync(join(ROOT, 'ampd/lib/ampd/bootstrap.ex'), 'utf8')
const dispatched = [...boot.matchAll(/defp registry_for\("[a-z_]+"\), do: (Ampd\.[A-Za-z.]+)/g)]
  .map((m) => m[1])

if (dispatched.length === 0) no('the registry dispatch table is readable', 'registry_for/1 matched nothing')

const snake = (m) =>
  m.replace(/^Ampd\./, '').split('.')
    .map((p) => p.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase()).join('/')

for (const mod of dispatched) {
  const f = join(ROOT, 'ampd/lib/ampd', `${snake(mod)}.ex`)
  if (!existsSync(f)) { no(`${mod} resolves to a source file`, `no ${f}`); continue }
  const code = readFileSync(f, 'utf8')
  // `Ampd.Peer` and `Ampd.Loci` spell the attribute differently — they were
  // converted a round earlier and their names are load-bearing elsewhere.
  if (/@participant_mutations|@client_mutations|@mutations /.test(code))
    ok(`${mod} is in registry_for/1 and declares a classification`)
  else
    no(`${mod} declares a classification`, 'reached from the order through a dispatch the census cannot resolve, and unconverted')
}

// ---------------------------------------------------------------- 3 · staleness
for (const id of Object.keys(rules.crossings))
  if (!usedX.has(id)) no(`exclusion "${id}"`, 'matches no crossing — the reason outlived the crossing it excused')
for (const key of Object.keys(rules.opaque))
  if (!usedO.has(key)) no(`opaque adjudication "${key}"`, 'matches no opaque site any more')

// ---------------------------------------------------------------- 4 · roots
//
// An imprecise root is a closure the census could not read, so it admits the
// whole enclosing function instead. That is conservative and it must not
// become the normal case.
const imprecise = census.roots.imprecise
if (imprecise.length <= 2) ok(`${imprecise.length} imprecise root(s): ${imprecise.join(', ') || 'none'}`)
else no('imprecise roots', `${imprecise.length} closures the census could not read: ${imprecise.join(', ')}`)

console.log(
  `\n  ${fail === 0 ? '\x1b[32mCLOSED\x1b[0m' : `\x1b[31m${fail} OPEN\x1b[0m`}  ` +
    `${census.totals.converted} converted · ${census.totals.beam} excluded · ${census.opaque.length} adjudicated\n`
)
process.exit(fail === 0 ? 0 : 1)
