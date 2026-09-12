/* Drive a real cockpit from a script, through the door the page already uses.
 *
 * ## Why this is not a new authority surface
 *
 * Every form in the cockpit submits the same way:
 *
 *     const { invoke } = window.__TAURI__.core;      // cockpit.js:139
 *     invoke('intent', { name, args })               // cockpit.js:706
 *
 * This module calls that. Not a socket, not an RPC port, not a second channel
 * — the same `intent` command, from the same webview, through the same
 * `check-webview-acl.mjs` grant, into the same `:human_control` channel, with
 * the same `Ampd.CommandSpec` validation and the same total order on the other
 * side. Nothing here can express an operation a person sitting at the app
 * could not, because it is submitting through the same one they would.
 *
 * What it removes is the *clicking*, which is presentation. What it does not
 * remove is any check: a refusal comes back as a refusal and is thrown, so a
 * script cannot mistake "the host said no" for "it worked".
 *
 * ## What it still cannot do, and why that is correct
 *
 * Two things resist this and neither is a gap:
 *
 *   * `choose_repository` opens a NATIVE chooser and accepts no path from the
 *     page. The folder a person selects is the whole input. `chooseRepository()`
 *     below opens the dialog and returns what the host says; it cannot answer
 *     the dialog.
 *   * Connecting a provider means signing in to an account in a browser.
 *
 * Both bind the world to something outside it. A script may drive the world;
 * it may not establish what the world is bound to.
 *
 * ## Use
 *
 *     import {open} from './lib/cockpit-control.mjs';
 *     const cockpit = await open();                 // a throwaway world
 *     const cockpit = await open({real: true});     // THE REAL WORLD
 *     const ws = await cockpit.intent('open_workspace', {name: 'Super'});
 *     const p  = await cockpit.projection();
 *     await cockpit.close();
 *
 * `open({real:true})` refuses while the world lock is held, because a second
 * cockpit parks and writes nothing and that is indistinguishable from success.
 */
import {spawn, execFileSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, existsSync, rmSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');
const sleep = ms => new Promise(r => setTimeout(r, ms));

export class Refused extends Error {
  constructor(intent, code, result) {
    super(`${intent} was refused: ${code}`);
    this.name = 'Refused';
    this.intent = intent;
    this.code = code;
    this.result = result;
  }
}

export async function open({
  real = false,
  port = Number(process.env.COCKPIT_CONTROL_PORT ?? 4495),
  fixture = !real,
  startTimeout = 90_000,
} = {}) {
  const base = `http://127.0.0.1:${port}`;

  // Refuse before spawning anything. A second cockpit against a locked world
  // opens, parks, and reports nothing wrong — the failure that looks like
  // success is the one worth refusing loudly.
  const stateHome = process.env.XDG_STATE_HOME ?? `${process.env.HOME}/.local/state`;
  const lock = `${stateHome}/super/worlds/default/world.lock`;
  if (real && existsSync(lock)) {
    let holder = '';
    try {
      holder = execFileSync('fuser', [lock], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore']}).trim();
    } catch {}
    if (holder) {
      throw new Error(
        `the world lock is held by pid${holder}. A second cockpit parks and writes nothing, ` +
        `which looks exactly like success. Stop it first: systemctl --user stop super-desktop`);
    }
  }

  const temp = mkdtempSync('/tmp/cockpit-control-');
  mkdirSync(temp, {recursive: true});
  const world = real
    ? {AMPD_DIR: `${ROOT}/ampd`}
    : {AMPD_DIR: `${ROOT}/ampd`, XDG_DATA_HOME: `${temp}/data`, XDG_STATE_HOME: `${temp}/state`,
       SUPER_WORLD_MODE: 'ephemeral'};

  const driver = spawn('tauri-driver',
    ['--port', String(port), '--native-port', String(port + 1), '--native-driver', '/usr/bin/WebKitWebDriver'],
    {cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
     env: {...process.env, GDK_BACKEND: 'x11', SUPER_COCKPIT_PANE: '0',
           SUPER_COCKPIT_FIXTURE: fixture ? '1' : '0',
           WEBKIT_DISABLE_COMPOSITING_MODE: '1', ...world}});
  let log = '';
  driver.stdout.on('data', b => (log = (log + b).slice(-8000)));
  driver.stderr.on('data', b => (log = (log + b).slice(-8000)));

  async function wd(method, path, body) {
    const r = await fetch(base + path, {
      method, headers: {'content-type': 'application/json'},
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(120_000)});
    const j = await r.json();
    if (!r.ok || j.value?.error) throw new Error(JSON.stringify(j).slice(0, 400));
    return j.value;
  }

  async function until(fn, ms, what) {
    const end = Date.now() + ms;
    let last;
    while (Date.now() < end) {
      try { const v = await fn(); if (v) return v; last = v; } catch (e) { last = e.message; }
      await sleep(250);
    }
    throw new Error(`timed out waiting for ${what} (last seen: ${String(last).slice(0, 200)})`);
  }

  let session = null;
  const cleanup = async () => {
    if (session) await wd('DELETE', `/session/${session}`).catch(() => {});
    try { process.kill(-driver.pid, 'SIGTERM'); } catch {}
    if (!real) { try { rmSync(temp, {recursive: true, force: true}); } catch {} }
  };

  try {
    await until(() => fetch(`${base}/status`).then(r => r.ok).catch(() => false), 30_000, 'tauri-driver');
    session = (await wd('POST', '/session', {capabilities: {alwaysMatch: {'tauri:options':
      {application: `${ROOT}/cockpit/target/release/super-cockpit`}}}})).sessionId;
    // Without `tauri:options.application` tauri-driver launches a bare WebKitGTK
    // MiniBrowser and every selector is simply missing, which reads as the app
    // being broken. The frame is what proves it is the cockpit.
    await until(() => sync('return !!window.cockpit?.frame?.projection'),
      startTimeout, 'the runtime to publish a frame');
  } catch (e) {
    await cleanup();
    throw new Error(`${e.message}\n--- tauri-driver ---\n${log.slice(-1200)}`);
  }

  function sync(code, args = []) {
    return wd('POST', `/session/${session}/execute/sync`, {script: code, args});
  }
  /* `invoke` returns a promise, so the sync form would hand back an empty
     object and every refusal would read as acceptance. */
  function asyncScript(code, args = []) {
    return wd('POST', `/session/${session}/execute/async`, {script: code, args});
  }

  const control = {
    /** The projection as the page holds it, or null before the first frame. */
    async projection() {
      const raw = await sync('return JSON.stringify(window.cockpit?.frame?.projection ?? null);');
      return JSON.parse(raw);
    },

    /** Everything under one collection, as an array. */
    async list(kind) {
      const p = await control.projection();
      return Object.values(p?.[kind] ?? {});
    },

    /** The first record in `kind` where `field` equals `value`, or undefined. */
    async find(kind, field, value) {
      return (await control.list(kind)).find(r => r?.[field] === value);
    },

    /**
     * Submit one human-control intent and return the host's result.
     *
     * Throws `Refused` when the host refuses, carrying the refusal code. A
     * script that ignores a refusal would go on to build on a record that does
     * not exist, so this is thrown rather than returned.
     */
    async intent(name, args = {}) {
      const result = await asyncScript(`
        const done = arguments[arguments.length - 1];
        window.__TAURI__.core.invoke('intent', {name: arguments[0], args: arguments[1]})
          .then(r => done(JSON.stringify({ok: true, result: r ?? null})))
          .catch(e => done(JSON.stringify({ok: false, error: String(e)})));
      `, [name, args]);
      const parsed = JSON.parse(result);
      if (!parsed.ok) throw new Error(`${name} failed: ${parsed.error}`);
      const refusal = parsed.result?.refusal?.code;
      if (refusal) throw new Refused(name, refusal, parsed.result);
      return parsed.result;
    },

    /**
     * Submit an intent and wait for the record it creates to reach the
     * projection. The intent returns when the host accepts it; the record
     * appears when the next frame carries it, and those are not the same
     * moment — building on the first is how a script races the world.
     */
    async create(name, args, {kind, field, value, ms = 20_000}) {
      const already = await control.find(kind, field, value);
      if (already) return {record: already, created: false};
      await control.intent(name, args);
      const record = await until(() => control.find(kind, field, value), ms, `${kind} ${value}`);
      return {record, created: true};
    },

    /** A native host command (not an intent). */
    async native(command, args = {}) {
      const result = await asyncScript(`
        const done = arguments[arguments.length - 1];
        window.__TAURI__.core.invoke(arguments[0], arguments[1])
          .then(r => done(JSON.stringify({ok: true, result: r ?? null})))
          .catch(e => done(JSON.stringify({ok: false, error: String(e)})));
      `, [command, args]);
      const parsed = JSON.parse(result);
      if (!parsed.ok) throw new Error(`${command} failed: ${parsed.error}`);
      return parsed.result;
    },

    /**
     * Open the native repository chooser.
     *
     * Returns whatever the host reports. This cannot answer the dialog: the
     * command accepts no path and the folder a person picks IS the input.
     * Present so a caller can open it and then say, honestly, that a person
     * has to finish it.
     */
    chooseRepository() { return control.native('choose_repository'); },

    /** Raw page access, for the rare thing that is genuinely about the page. */
    page: sync,
    until,
    session: () => session,
    close: cleanup,
  };
  return control;
}
