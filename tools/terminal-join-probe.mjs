#!/usr/bin/env node
/* terminal-join-probe — D.1.3c·2c·1c B5, and what it measures instead.
   ────────────────────────────────────────────────────────────────────────

   THE QUESTION

     A person clicks *Watch terminal* on a Worker occupied by a real
     confined Carrier. How many bytes reach the real xterm?

   Everything on the way is built and falsified: the host's pump, the
   attachment, the Plane, the socketpair, the Tauri Channel, the sequencing
   and the credit. `super-host verify` drives bytes across all of it. What
   has never been measured is the same path with **no test writing the
   bytes** — the product path, from a person's click, against the Carrier a
   product started.

   It runs the whole surface for real:

     SUPER_COCKPIT_CARRIER=1  the production chain to a RUNNING Carrier
                              with an ACQUIRED terminal            (B4)
     a real WebDriver click on the *Watch terminal* button
     `terminal_surface` creates the terminal webview               (product)
     `terminal_bind` opens the Plane                               (product)
     then it WAITS, and reports what arrived.

   The answer is the finding, whatever it is. This file asserts one thing
   only — that the click was accepted and the terminal opened — and then
   reports the byte count rather than requiring it, because requiring a
   number is how a probe stops being able to tell you the number is zero.

     node tools/terminal-join-probe.mjs [--wait-ms 8000]                   */

import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const APP = `${ROOT}/cockpit/target/release/super-cockpit`
const DRIVER_PORT = Number(process.env.TAURI_DRIVER_PORT ?? 4464)
const NATIVE_PORT = Number(process.env.TAURI_NATIVE_PORT ?? 4465)
const BASE = `http://127.0.0.1:${DRIVER_PORT}`
const wi = process.argv.indexOf('--wait-ms')
const WAIT_MS = wi > -1 ? Number(process.argv[wi + 1]) : 8000

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let pass = 0, fail = 0
const check = (name, ok, detail = '') => {
  if (ok) { pass++; console.log(`  \x1b[32mheld\x1b[0m         ${name}`) }
  else { fail++; console.log(`  \x1b[31mFAILED\x1b[0m       ${name}\n               ${detail}`) }
  return ok
}
const say = (s) => console.log(`               ${s}`)

async function wd(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method, headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  let json
  try { json = JSON.parse(text) } catch { throw new Error(`${method} ${path} → ${res.status} ${text.slice(0, 300)}`) }
  if (json.value && json.value.error) throw new Error(`${json.value.error}: ${json.value.message}`)
  return json.value
}

let session = null
const script = (js, args = []) => wd('POST', `/session/${session}/execute/sync`, { script: js, args })
const handles = () => wd('GET', `/session/${session}/window/handles`)
const focus = (h) => wd('POST', `/session/${session}/window`, { handle: h })
const labelOf = () => script(`const m = window.__TAURI_INTERNALS__ && window.__TAURI_INTERNALS__.metadata;
                              return m && m.currentWebview ? m.currentWebview.label : null;`)

async function views() {
  const out = {}
  for (const h of await handles()) {
    await focus(h)
    try { const l = await labelOf(); if (l) out[l] = h } catch {}
  }
  return out
}

async function poll(f, limitMs, everyMs = 300) {
  const deadline = Date.now() + limitMs
  let last = null
  while (Date.now() < deadline) {
    try { last = await f(); if (last) return last } catch (e) { last = null }
    await sleep(everyMs)
  }
  return last
}

const driver = spawn('tauri-driver',
  ['--port', String(DRIVER_PORT), '--native-port', String(NATIVE_PORT),
   '--native-driver', process.env.WEBKIT_WEBDRIVER ?? '/usr/bin/WebKitWebDriver'],
  { stdio: ['ignore', 'inherit', 'inherit'], detached: true,
    env: { ...process.env,
      AMPD_DIR: `${ROOT}/ampd`,
      SUPER_WORLD_MODE: 'ephemeral',
      /* The production chain: a Worker occupied by a confined Carrier whose
         terminal has been acquired. Without it the *Watch terminal* action
         is never rendered, because `terminal` is never `PRESENT`. */
      SUPER_COCKPIT_CARRIER: '1',
      WEBKIT_DISABLE_COMPOSITING_MODE: '1',
    } })

let stopped = false
const stop = () => {
  if (stopped) return
  stopped = true
  try { process.kill(-driver.pid, 'SIGTERM') } catch {}
}
process.on('exit', stop)
process.on('SIGINT', () => { stop(); process.exit(130) })

async function run() {
  const v = await poll(async () => { const x = await views(); return x.main ? x : null }, 60_000)
  check('the cockpit webview came up', !!(v && v.main), JSON.stringify(v))
  if (!v || !v.main) return
  await focus(v.main)

  /* The Worker the witness created, seen from the page's own frame. */
  const shape = await poll(() => script(`
    const f = window.cockpit && window.cockpit.frame;
    if (!f) return null;
    const pj = f.projection || {};
    return JSON.stringify({ top: Object.keys(f), projection: Object.keys(pj),
                            workers: Object.values(pj.workers || {}).map((w) => [w.id, w.occupancy, w.carrier, w.terminal]) });`), 30_000)
  say(`frame shape: ${shape}`)

  const row = await poll(() => script(`
    const f = window.cockpit && window.cockpit.frame;
    if (!f || !f.projection) return null;
    const ws = f.projection.workers || {};
    const hit = Object.entries(ws).map(([id, w]) => ({ id, ...w }))
      .find((w) => w.terminal === 'PRESENT');
    return hit ? JSON.stringify(hit) : null;`), 60_000)
  check('a Worker reaches the page with terminal PRESENT', !!row, String(row))
  if (!row) return
  const worker = JSON.parse(row)
  say(`worker ${worker.id} · occupancy ${worker.occupancy} · carrier ${worker.carrier} · terminal ${worker.terminal}`)

  /* A real click on the real button. Located by intent, exactly as the
     cockpit battery locates its own, so a renamed label does not silently
     turn this into a probe of nothing. */
  const el = await poll(async () => {
    try {
      return await wd('POST', `/session/${session}/element`, {
        using: 'css selector',
        value: `#world .row[data-id="${worker.id}"] button[data-intent="terminal_bind"]`,
      })
    } catch { return null }
  }, 30_000)
  check('the *Watch terminal* action is offered on that Worker', !!el, 'no button[data-intent="terminal_bind"]')
  if (!el) return
  await wd('POST', `/session/${session}/element/${Object.values(el)[0]}/click`, {})

  const outcome = await poll(() => script(`
    const li = document.querySelector('#receipt-list li[data-intent="terminal_bind"]');
    return li ? li.dataset.outcome : null;`).then((o) => (o === 'submitted' ? null : o)), 30_000)
  /* `accepted` is `cockpit.js`'s word for a resolved intent; `refused` and
     `failed` are the other two. Matching on 'ok' made a green outcome read
     as a red one, which is the probe grading itself against a vocabulary
     the product does not use. */
  check('the bind resolved, and not as a refusal', outcome === 'accepted',
        `receipt outcome ${outcome}`)

  /* The terminal webview, and then xterm itself. */
  const term = await poll(async () => { const x = await views(); return x.terminal ?? null }, 30_000)
  check('a real terminal webview exists after the click', !!term, 'no webview labelled "terminal"')
  if (!term) return
  await focus(term)

  /* `window.terminalPane` is the page's own surface — `terminal.js` names
     it, `tools/cockpit-battery.mjs` reads it, and it is the only thing in
     that page a probe may address. There is no `window.term`. */
  const ready = await poll(() => script(`return window.terminalPane ? JSON.stringify(window.terminalPane) : null;`), 30_000)
  check('the terminal page is live and has bound its sink', !!ready && JSON.parse(ready).bound === true,
        String(ready))
  say(`terminalPane at bind: ${ready}`)

  /* ── and now the measurement, which asserts nothing ───────────────── */
  console.log(`\n  waiting ${WAIT_MS} ms for bytes on the joined path…\n`)
  await sleep(WAIT_MS)

  const seen = await script(`
    const p = window.terminalPane || {};
    const el = document.querySelector('.xterm-screen') || document.body;
    const text = (el.innerText || '').replace(/[\\s\\u00a0]+$/, '');
    return JSON.stringify({
      frames: p.frames, bytes: p.bytes, applied: p.applied, consumed: p.consumed,
      acked: p.acked, beats: p.beats, gaps: p.gaps, fault: p.fault, closed: p.closed,
      rendered: text.length, text: text.slice(0, 400),
    });`)
  const m = JSON.parse(seen)
  say(`plane frames ${m.frames} · bytes ${m.bytes} · applied ${m.applied} · consumed ${m.consumed} · acked ${m.acked} · beats ${m.beats} · gaps ${m.gaps}`)
  say(`fault ${JSON.stringify(m.fault)} · closed ${JSON.stringify(m.closed)} · rendered characters ${m.rendered}`)
  if (m.rendered > 0) say(`screen: ${JSON.stringify(m.text)}`)
  const marker = m.text.includes('SUPER-DOGFOOD-R0-READY')
  console.log('')
  check('MEASUREMENT — the marker SUPER-DOGFOOD-R0-READY reached xterm', marker,
        `the joined path is OPEN and carried ${m.bytes} byte(s) in ${m.frames} frame(s) ` +
        `while sending ${m.beats} liveness beat(s). Nothing in the product can put a byte ` +
        'on it — see docs/reviews/D_1_3C_2C_1C_B5.md')
}

async function main() {
  try {
    await poll(async () => { try { await fetch(`${BASE}/status`); return true } catch { return false } }, 20_000, 200)
    const created = await wd('POST', '/session', {
      capabilities: { alwaysMatch: { 'tauri:options': { application: APP } } },
    })
    session = created.sessionId ?? created.capabilities?.sessionId
    if (!session) throw new Error(`no sessionId in ${JSON.stringify(created)}`)
    await run()
  } catch (e) {
    fail++
    console.log(`  \x1b[31mFAILED\x1b[0m       the probe could not run\n               ${e.message ?? e}`)
  } finally {
    if (session) { try { await wd('DELETE', `/session/${session}`) } catch {} }
    stop()
    await sleep(1500)
  }
  console.log(`\nterminal join probe: ${pass} held · ${fail} failed`)
  process.exit(fail === 0 ? 0 : 1)
}
main()
