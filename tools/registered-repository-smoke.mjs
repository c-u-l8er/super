#!/usr/bin/env node
/* registered-repository-smoke — the Editor opens a REGISTERED repository by
   reference, with no native chooser.
   ────────────────────────────────────────────────────────────────────────

   THE GAP THIS CLOSES

     `choose_workbench` opens a GTK modal on the cockpit's main thread. A
     script cannot answer it, and while it waits every other command stalls
     — including a harness's own teardown. The workbench root was also held
     in memory only, so every restart re-required a person at the display
     before a single proposal could be applied. Two rounds of dogfooding on
     2026-09-16/17 were lost to exactly that.

   THE RULING THIS PINS

     Registration IS the person's decision: `register_repository` stores the
     folder they picked in the native chooser, ordered, in the world. So a
     registered repository may be reopened by its `rp_` ref without a dialog.
     The page sends the ref and nothing else; the runtime answers the folder
     to the HOST over the bridge; `git_root` re-checks it; the page still
     never supplies, and never receives from the runtime, a path. A ref for
     nothing registered, a path, or an empty string is refused.

   HOW IT GETS A REGISTERED REPOSITORY WITHOUT A CHOOSER

     `SUPER_COCKPIT_CARRIER=1` — the D.1.3b·2f witness — registers
     `d13b2f-repo` inside the throwaway world through the bridge, which is
     the only other route to registration and is not reachable from a page.

     node tools/registered-repository-smoke.mjs                             */
import {execFileSync} from 'node:child_process';
import {open} from './lib/cockpit-control.mjs';

process.env.SUPER_COCKPIT_CARRIER = '1';
process.env.GDK_BACKEND ??= 'x11';

let held = 0, failed = 0;
const check = (what, ok, detail = '') => {
  console.log(`  ${ok ? '\x1b[32mheld\x1b[0m' : '\x1b[31mFAILED\x1b[0m'}  ${what}${detail ? ' — ' + detail : ''}`);
  ok ? held++ : failed++;
};
const q = s => JSON.stringify(s);

// Is a window with the native chooser's title on the display? Asked of X
// directly, so the answer does not depend on the page being responsive.
function chooserWindows() {
  const py = `
import ctypes as c
x=c.CDLL('libX11.so.6');W=c.c_ulong;P=c.c_void_p
x.XOpenDisplay.restype=P;x.XDefaultRootWindow.argtypes=[P];x.XDefaultRootWindow.restype=W
x.XQueryTree.argtypes=[P,W,c.POINTER(W),c.POINTER(W),c.POINTER(c.POINTER(W)),c.POINTER(c.c_uint)]
x.XFetchName.argtypes=[P,W,c.POINTER(c.c_char_p)];x.XFree.argtypes=[P]
d=x.XOpenDisplay(None)
n=0
def walk(w):
  global n
  name=c.c_char_p();x.XFetchName(d,w,c.byref(name))
  if name.value and name.value.decode(errors='replace')=='Open repository for local development': n+=1
  if name.value: x.XFree(name)
  r=W();p=W();ch=c.POINTER(W)();cnt=c.c_uint()
  if x.XQueryTree(d,w,c.byref(r),c.byref(p),c.byref(ch),c.byref(cnt)):
    ids=[ch[i] for i in range(cnt.value)]
    if ch: x.XFree(ch)
    for i in ids: walk(i)
walk(x.XDefaultRootWindow(d));print(n)`;
  return Number(execFileSync('/usr/bin/python3', ['-c', py], {encoding: 'utf8'}).trim());
}

console.log('\nregistered-repository (Editor root by reference, no chooser)\n');
const started = Date.now();
let c;
try {
  c = await open();
  const repo = await c.until(async () => (await c.list('repositories'))[0], 60_000, 'a registered repository in the fixture world');
  check('the carrier witness registered a repository in the throwaway world', /^rp_\d+$/.test(repo.ref), `${repo.ref} · ${repo.name}`);
  check('and the projection carries its ref and name but no path', repo.name === 'd13b2f-repo' && !('path' in repo), Object.keys(repo).join(','));

  await c.page(`document.querySelector('[data-nav=editor]').click()`);
  const option = await c.until(() => c.page(`return [...document.querySelectorAll('#development-registered-editor option')].map(o => [o.value, o.textContent]).find(([v]) => v === ${q(repo.ref)}) ?? null`), 15_000, 'the Editor lists the registered repository');
  check('the Editor toolbar lists the registered repository by name and ref', option[1] === `${repo.name} · ${repo.ref}`, option[1]);
  check('Open registered is disabled until one is chosen', await c.page(`return document.querySelector('#development-open-registered-editor').disabled`));
  check('the native chooser is still offered, for a folder not yet registered', await c.page(`return document.querySelector('#development-choose-editor')?.textContent`) === 'Other folder…');
  check('nothing is open yet', await c.page(`return document.querySelector('[data-screen=editor] .workbench-root').textContent`) === 'No repository selected');

  await c.page(`const s = document.querySelector('#development-registered-editor'); s.value = ${q(repo.ref)}; s.dispatchEvent(new Event('change'));`);
  check('choosing one enables Open registered', await c.page(`return !document.querySelector('#development-open-registered-editor').disabled`));
  const before = Date.now();
  await c.page(`document.querySelector('#development-open-registered-editor').click()`);
  const root = await c.until(async () => { const t = await c.page(`return document.querySelector('[data-screen=editor] .workbench-root').textContent`); return t !== 'No repository selected' ? t : null; }, 15_000, 'the Editor adopts the root');
  const took = Date.now() - before;
  check('the Editor adopts the registered folder as its root, with no dialog', root.endsWith('/d13b2f-repo'), `${root} in ${took} ms`);
  check('no window titled like the native chooser exists on the display', chooserWindows() === 0);
  const status = await c.native('development_request', {request: {operation: 'status'}});
  check('the host holds that root in the workbench session', status.root === root && status.generation >= 1, `generation ${status.generation}`);
  check('the page can list the repository through the held root', await c.page(`return document.querySelector('#editor-tree .development-folder')?.textContent`) === '/');
  check('the shell control is enabled, because a root is held', await c.page(`return !document.querySelector('#terminal-new').disabled`));

  // Reopening bumps the generation — the same rule the chooser has, so a
  // proposal bound to the earlier generation is refused rather than applied.
  const again = await c.openRepository(repo.ref);
  check('reopening the same repository is a new generation, as the chooser would be', again.generation === status.generation + 1 && again.root === root, `${status.generation} → ${again.generation}`);

  for (const [bad, expect] of [['rp_9999', 'not registered'], ['/tmp', 'Choose a registered repository.'], ['', 'Choose a registered repository.'], [`${repo.ref}/..`, 'Choose a registered repository.']]) {
    let err = null;
    try { await c.openRepository(bad); } catch (e) { err = e; }
    check(`${q(bad)} is refused — ${expect}`, err !== null && err.message.includes(expect), err ? err.message.slice(0, 120) : 'NOTHING WAS THROWN');
  }
  const after = await c.native('development_request', {request: {operation: 'status'}});
  check('and the refusals changed nothing: the root and generation are as before', after.root === root && after.generation === again.generation);
  check('the whole flow finished inside a wall-clock budget — the page never blocked', Date.now() - started < 120_000, `${Date.now() - started} ms`);
} catch (e) {
  check('the smoke ran to completion', false, String(e).slice(0, 300));
} finally {
  if (c) { try { await c.close(); } catch {} }
}
console.log(`\nregistered-repository: ${held} held · ${failed} failed\n`);
process.exit(failed ? 1 : 0);
