#!/usr/bin/env node
/**
 * check-ordered-boundary — the ratchet on the total order's process boundary.
 *
 * C1.0b·2 converted two participants and left the rest. That is a deliberate
 * scope decision and it is worth exactly nothing unless the remainder is
 * COUNTED, because an unconverted boundary that nobody counts is a boundary
 * that grows.
 *
 * So this gate answers three questions:
 *
 *   1  do the converted modules still have zero bare `GenServer.call`s
 *   2  has the unconverted remainder grown, anywhere
 *   3  is the coordinator's catch still narrow
 *
 * The third is the one that matters most and is the easiest to lose. A bare
 * `catch :exit` around the transaction closure would make every falsifier in
 * `test/ordered_participant_test.exs` pass while turning an applied mutation
 * into an ordinary refusal — which is the defect, not the repair.
 *
 * The baseline lives in `tools/ordered-boundary.json`. Lowering a number is
 * fine and is the point; raising one fails.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, relative } from 'node:path'

const ROOT = '/home/travis/ProjectAmp2/super'
const LIB = join(ROOT, 'ampd/lib')
const BASE = join(ROOT, 'tools/ordered-boundary.json')
const WRITE = process.argv.includes('--write')

const sh = (cmd, args) =>
  execFileSync(cmd, args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 })

let fail = 0
const ok = (m) => console.log(`  \x1b[32mheld\x1b[0m  ${m}`)
const no = (m, why) => { console.log(`  \x1b[31mFAIL\x1b[0m  ${m} — ${why}`); fail++ }

const files = sh('bash', ['-c', `find ${LIB} -name '*.ex' | sort`]).trim().split('\n')

// Doc heredocs describe the boundary at length; a sweep that counted prose
// would report the module that explains the rule as the module that breaks it.
const codeOnly = (s) => {
  const out = []
  let inDoc = false
  for (const line of s.split('\n')) {
    if (inDoc) { if (line.includes('"""')) inDoc = false; out.push(''); continue }
    if (line.includes('"""')) { inDoc = true; out.push(''); continue }
    out.push(line.replace(/#.*$/, ''))
  }
  return out.join('\n')
}

const found = {}
for (const f of files) {
  const code = codeOnly(readFileSync(f, 'utf8'))
  const bare = (code.match(/GenServer\.call\(__MODULE__/g) || []).length
  if (bare) found[relative(join(ROOT, 'ampd'), f)] = bare
}

// A per-module count of `GenServer.call(__MODULE__, …)` is a mechanical proxy
// for the unconverted surface, not the boundary itself: it includes client
// helpers that are never reached from inside a transaction, and excludes
// calls made to another module by name. It is the right shape for a RATCHET —
// it cannot grow without someone noticing — and the wrong shape for a claim
// about exactly which crossings remain. That claim is the census.
console.log(`\n  ordered boundary · ${Object.keys(found).length} module(s) still calling themselves bare\n`)

if (WRITE) {
  writeFileSync(BASE, JSON.stringify({ bare: found }, null, 2) + '\n')
  console.log(`  wrote baseline ${relative(ROOT, BASE)}`)
  process.exit(0)
}

if (!existsSync(BASE)) {
  console.error('REFUSING — no baseline. Run with --write once, and commit it.')
  process.exit(1)
}
const base = JSON.parse(readFileSync(BASE, 'utf8')).bare

// 1 · the converted modules stay converted
for (const m of ['lib/ampd/peer.ex', 'lib/ampd/loci.ex']) {
  if (found[m]) no(`${m} is converted`, `${found[m]} bare GenServer.call(__MODULE__) reappeared`)
  else ok(`${m} routes every client call through Ampd.Participant`)
}

// 2 · nothing grew, and nothing new appeared
for (const [m, n] of Object.entries(found)) {
  const was = base[m]
  if (was === undefined) no(`${m} is accounted for`, `${n} bare call(s) in a module the baseline does not list`)
  else if (n > was) no(`${m} did not grow`, `${n} bare call(s), baseline ${was}`)
  else if (n < was) ok(`${m} shrank to ${n} (baseline ${was}) — lower the baseline`)
  else ok(`${m} unchanged at ${n}`)
}
for (const m of Object.keys(base)) {
  if (found[m] === undefined) ok(`${m} is fully converted (baseline ${base[m]})`)
}

// 3 · the coordinator's catch is narrow, and the boundary is the only sender
const coord = codeOnly(readFileSync(join(LIB, 'ampd/authority_coordinator.ex'), 'utf8'))
if (/rescue\s+e in Ampd\.Participant\.Failure/.test(coord))
  ok('the coordinator catches Ampd.Participant.Failure by struct')
else no('the coordinator catches by struct', 'no `rescue e in Ampd.Participant.Failure` clause')

if (/catch\s*\n\s*:exit/.test(coord) || /rescue\s*\n?\s*_\s*->/.test(coord))
  no('the coordinator catch is narrow', 'a bare `catch :exit` or `rescue _` would convert an applied mutation into a refusal')
else ok('the coordinator has no bare exit or wildcard rescue')

const senders = files.filter((f) => /send_request/.test(codeOnly(readFileSync(f, 'utf8'))))
  .map((f) => relative(join(ROOT, 'ampd'), f))
if (senders.length === 1 && senders[0] === 'lib/ampd/participant.ex')
  ok('Ampd.Participant is the only module that sends a request')
else no('one sender', `send_request appears in ${senders.join(', ') || 'nothing'}`)

// 4 · the witness rule, proved STRUCTURALLY rather than by text proximity
//
// The first version of this check asked whether the word `witness` appeared
// within 200 characters of `after_timeout`, and reported FAIL against correct
// source because the following clause — `after_death`, which legitimately
// takes one — is inside that window. A gate that measures adjacency is
// measuring the wrong thing.
//
// The real property is that the function deciding a timeout's class CANNOT
// consult a witness, because it is never given one: `after_timeout/1` takes
// the class and nothing else, while `after_death/2` takes the witness. That
// is arity, which is not a matter of proximity or opinion.
const part = codeOnly(readFileSync(join(LIB, 'ampd/participant.ex'), 'utf8'))
const timeoutClauses = [...part.matchAll(/defp after_timeout\(([^)]*)\)/g)].map((m) => m[1])
const deathClauses = [...part.matchAll(/defp after_death\(([^)]*)\)/g)].map((m) => m[1])
if (timeoutClauses.length === 0) {
  no('the witness rule', 'no after_timeout clauses found at all')
} else if (timeoutClauses.some((a) => a.includes(','))) {
  no('the witness rule', 'after_timeout takes a second argument — it could be handed a witness')
} else if (!deathClauses.some((a) => a.includes(','))) {
  no('the witness rule', 'after_death takes no witness — the death path narrows nothing')
} else {
  ok(`a witness cannot be consulted after a timeout (after_timeout/${timeoutClauses[0].split(',').length}, after_death/2)`)
}

// 5 · every message a converted module SENDS is classified
//
// **Client-side, and the first version got this wrong.** It derived the tag
// set from `handle_call` clauses and reported five of `Ampd.Loci`'s ordered
// ops as dead entries — because that module handles them through a single
// guarded clause that dispatches to `handle_ordered/2`, so they appear in no
// `handle_call` head at all. A census that reads the wrong side reports
// correct source as broken.
//
// The classification governs what the CLIENT sends, so the client is what to
// enumerate. A tag sent but named by no list is silently a read — which gives
// an indeterminate write a retryable "basis unavailable" and invites the
// second execution the class exists to forbid.
const CONVERTED = {
  'lib/ampd/peer.ex': { mod: 'Ampd.Peer', attr: /@mutations ~w\(([^)]*)\)a/ },
  // **`@client_mutations`, not `@ordered_ops`.** The gate built to make
  // classification auditable was reading the list the code no longer
  // classifies by, and the committed census filed `close_store` under reads
  // in direct contradiction of `Loci.class(:close_store)` on the same commit.
  'lib/ampd/loci.ex': { mod: 'Ampd.Loci', attr: /@client_mutations @ordered_ops \+\+ \[([^\]]*)\]/, plus: /@ordered_ops \[([^\]]*)\]/ },
}

const census = {}
for (const [rel, { mod, attr, plus }] of Object.entries(CONVERTED)) {
  const code = codeOnly(readFileSync(join(LIB, rel.replace('lib/ampd/', 'ampd/')), 'utf8'))

  const sent = [
    ...code.matchAll(/ask\(\{:(\w+)/g),
    ...code.matchAll(/ask\(:(\w+)/g),
  ].map((m) => m[1]).filter((n, i, a) => a.indexOf(n) === i).sort()

  const m = code.match(attr)
  if (!m) { no(`${rel} declares its mutations`, 'the classification list could not be read'); continue }
  const parse = (x) => x.split(/[\s,]+/).map((t) => t.replace(/^:/, '')).filter(Boolean)
  const mutations = parse(m[1]).concat(plus ? parse((code.match(plus) || [, ''])[1]) : [])
  if (plus && mutations.length === parse(m[1]).length)
    no(`${rel}'s composed list resolves`, 'the base list it extends could not be read')

  const dead = mutations.filter((t) => !sent.includes(t))
  const reads = sent.filter((t) => !mutations.includes(t))
  const bare = (code.match(/GenServer\.call\(__MODULE__/g) || []).length

  census[mod] = {
    sends: sent.length, mutations: sent.filter((t) => mutations.includes(t)).length,
    reads: reads.length, declared_mutations: mutations.length, dead, bare,
  }

  if (bare) no(`${rel} sends everything through the boundary`, `${bare} bare call(s)`)
  else if (dead.length) no(`${rel} has no dead classification entries`, `${dead.join(', ')} named but never sent`)
  else ok(`${rel}: ${sent.length} messages sent — ${census[mod].mutations} mutations, ${reads.length} reads, 0 dead`)
}

writeFileSync(join(ROOT, 'tools/ordered-boundary-census.json'),
  JSON.stringify({ bare: found, converted: census }, null, 2) + '\n')

const total = Object.values(found).reduce((a, b) => a + b, 0)
console.log(`\n  unconverted bare client calls: ${total}\n`)
if (fail === 0) {
  console.log('  ordered boundary: \x1b[32mheld\x1b[0m\n')
} else {
  console.log(`  ordered boundary: \x1b[31m${fail} failed\x1b[0m\n`)
  process.exit(1)
}
