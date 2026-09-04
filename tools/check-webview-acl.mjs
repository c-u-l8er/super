/* check-webview-acl — the outer authority gate, checked statically.
   ────────────────────────────────────────────────────────────────────────

   THE LAW

     A command this process registers is reachable only from a webview the
     capability names.

   W.2 did not hold it, and nothing looked wrong. Tauri's default is that
   application commands registered through `invoke_handler` are available
   to **every** window and webview in the application; capabilities gate
   plugin permissions. So W.2's capability read

       "the cockpit window may listen for the frames the host emits, and
        nothing else"

   beside an `intent` command any webview the process ever opened could
   have called. With one product window that was not exploitable. It was
   also not a boundary, and the boundary is the entire reason W.2 exists:
   the cockpit is going to host browser and application panes.

   THREE LISTS THAT MUST AGREE, and each can drift on its own:

     src/main.rs      tauri::generate_handler![…]   what is REGISTERED
     build.rs         AppManifest::commands(&[…])   what is IN THE ACL
     capabilities/    permissions: […]              what is GRANTED

   A command registered but absent from `build.rs` is outside the ACL —
   which is W.2's defect exactly, and it fails *open*. A command in the ACL
   but ungranted is dead. A grant for a command that no longer exists is a
   permission nobody can use and everybody reads as coverage.

   This is the static half. `tools/cockpit-battery.mjs` is the other half:
   it opens the untrusted pane — **as a child webview of the trusted
   window**, since W.2.2 — and requires **Tauri** to refuse `intent` from
   it, not our JavaScript and not `INTENT_SURFACE`.                      */

import { readFileSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

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

console.log('[&] Super — cockpit webview ACL\n');

const main = readFileSync(`${ROOT}/cockpit/src/main.rs`, 'utf8');
const build = readFileSync(`${ROOT}/cockpit/build.rs`, 'utf8');
const cockpitJs = readFileSync(`${ROOT}/cockpit/ui/cockpit.js`, 'utf8');
/* **EVERY capability file, and reading only `default.json` was a hole.**

   This gate read one file and asserted its `webviews` list had exactly one
   entry — which reads like "authority is granted to one webview" and is
   not. A second file in this directory is loaded by Tauri exactly as the
   first is, and was invisible here: the gate would have reported a
   perfectly closed boundary over a `capabilities/anything.json` granting
   `intent` to `*`.

   D.1.3c·2c·1b is what made that reachable rather than theoretical — the
   terminal pane is the first webview in this application that holds SOME
   authority and not the cockpit's, so there is now a second file. The
   per-file laws below are unchanged; what changed is that they are applied
   to all of them, and that the union is what the command lists are checked
   against. */
const capDir = `${ROOT}/cockpit/capabilities`;
const capFiles = readdirSync(capDir).filter((f) => f.endsWith('.json')).sort();
const caps = capFiles.map((f) => ({
  file: f,
  json: JSON.parse(readFileSync(`${capDir}/${f}`, 'utf8')),
}));

const cap = (caps.find((c) => c.file === 'default.json') ?? {}).json;

/* `generate_handler![a, b, c]` — read as source rather than as a comment
   about the source. */
const handler = (main.match(/generate_handler!\[([\s\S]*?)\]/) ?? [])[1] ?? '';
const registered = handler
  .split(',')
  .map((s) => s.trim())
  .filter((s) => s && !s.startsWith('//'))
  .sort();

const manifest = (build.match(/commands\(&\[([\s\S]*?)\]\)/) ?? [])[1] ?? '';
const declared = [...manifest.matchAll(/"([a-z_]+)"/g)].map((m) => m[1]).sort();

const snake = (s) => s.replace(/_/g, '-');
const granted = (cap.permissions ?? []).slice().sort();

/* The union across every capability, because "is this command dead" and
   "does this grant name something real" are questions about the
   application, not about one file. Which webview holds which is the
   per-file question, checked below. */
const allGranted = caps.flatMap((c) => c.json.permissions ?? []);
const grantedCommands = [
  ...new Set(
    allGranted.filter((p) => p.startsWith('allow-')).map((p) => p.slice('allow-'.length)),
  ),
].sort();

check(
  'the three lists can be read at all',
  registered.length > 0 && declared.length > 0 && granted.length > 0,
  `registered=${registered.length} declared=${declared.length} granted=${granted.length}`,
);

const outsideAcl = registered.filter((c) => !declared.includes(c));
check(
  'every registered command is declared to the ACL — none fails open',
  outsideAcl.length === 0,
  `registered in main.rs, absent from build.rs: ${outsideAcl.join(', ')}`,
);

const phantom = declared.filter((c) => !registered.includes(c));
check(
  'the ACL declares no command this process does not register',
  phantom.length === 0,
  `declared but never registered: ${phantom.join(', ')}`,
);

const ungranted = declared.filter((c) => !grantedCommands.includes(snake(c)));
check(
  'every declared command is granted to some webview — none is dead',
  ungranted.length === 0,
  `declared but not granted: ${ungranted.join(', ')}`,
);

const orphan = grantedCommands.filter((c) => !declared.map(snake).includes(c));
check(
  'no capability grants anything that does not exist',
  orphan.length === 0,
  `granted with no matching command: ${orphan.join(', ')}`,
);

/* **`core:default` is not "listening for frames".** It aggregates the core
   defaults, and `core:event:default` carries `allow-emit` and
   `allow-emit-to` as well as `allow-listen` — the ability to inject into
   the application's own event bus, which is not a read. The frame stream
   is a Channel the frontend hands over, so the cockpit needs no core
   permission at all, and having none is a stronger statement than having
   a carefully chosen few. */
const core = allGranted.filter((p) => p.startsWith('core:'));
check(
  'NO capability holds a core permission — the frame stream is a Channel, not the event bus',
  core.length === 0,
  `core permissions granted: ${core.join(', ')}`,
);

/* ── W.2.2 · a WEBVIEW grant, and W.2.1 wrote a WINDOW grant ─────────────

   tauri-2.11.5, `src/ipc/authority.rs`, `resolve_access`:

       cmd.webviews.iter().any(|w| w.matches(webview))
         ||                                              ← an OR
       cmd.windows.iter().any(|w| w.matches(window))

   called from `src/webview/mod.rs` with `window = self.window().label()`
   and `webview = self.label()`. So `windows: ["main"]` is satisfied by the
   WINDOW label alone and the webview's own label is never consulted —
   Tauri's own `acl/capability.rs` says it outright: *"the capability will
   be enabled on all the webviews of that window, regardless of the value
   of webviews"*.

   W.2.1's runtime witness passed because its pane was a separate
   `WebviewWindow`. Super's panes will not be. A browser pane, a Motor
   surface or a game pane is a CHILD WEBVIEW of the cockpit window, and
   under `windows` every one of them would have inherited `allow-intent`
   by being drawn inside the same frame.

   The substitution that reopens this is ONE WORD, in a file whose prose
   would go on describing a boundary that had stopped existing. So it is
   refused here rather than reviewed.                                     */

check(
  'the cockpit\'s authority is granted to the trusted WEBVIEW label',
  Array.isArray(cap.webviews) && cap.webviews.length === 1 && cap.webviews[0] === 'main',
  `webviews: ${JSON.stringify(cap.webviews)}`,
);

for (const { file, json } of caps) {
  check(
    `${file} grants to exactly one webview, by label`,
    Array.isArray(json.webviews) && json.webviews.length === 1,
    `webviews: ${JSON.stringify(json.webviews)}`,
  );

  check(
    `${file} names no window — a window grant reaches every webview inside it`,
    !('windows' in json),
    `windows: ${JSON.stringify(json.windows)} — this grants every child webview of that `
      + 'window, which is what a browser, terminal or Motor pane is',
  );

  check(
    `${file} grants nothing by pattern`,
    !(json.webviews ?? []).some((w) => /[*?[\]]/.test(w))
      && !(json.windows ?? []).some((w) => /[*?[\]]/.test(w)),
    JSON.stringify({ windows: json.windows, webviews: json.webviews }),
  );
}

/* **No two capabilities may name the same webview**, because the resolver
   takes the UNION of everything that matches. Two files each looking
   narrow would compose into a grant neither of them states, and the file a
   reader opens would not be the answer. */
const byWebview = new Map();
for (const { file, json } of caps) {
  for (const w of json.webviews ?? []) {
    byWebview.set(w, [...(byWebview.get(w) ?? []), file]);
  }
}
const doubled = [...byWebview.entries()].filter(([, f]) => f.length > 1);
check(
  'no webview is named by two capabilities — a grant is one file, readable in one place',
  doubled.length === 0,
  doubled.map(([w, f]) => `${w}: ${f.join(' + ')}`).join('; '),
);

/* **The terminal pane holds the read-only surface and no fourth command.**
   Not a restatement of the file: `intent` reaching this webview would be a
   terminal renderer holding a person\'s authority, and `bind_frame_stream`
   would make it a second reader of the world. Both are one line away in a
   file whose prose would go on describing a boundary that had stopped
   existing — which is the same shape as the `windows`/`webviews` slip
   above, and is refused here rather than reviewed. */
const term = caps.find((c) => c.file === 'terminal.json');
if (term) {
  const p = (term.json.permissions ?? []).slice().sort();
  check(
    'the terminal pane holds exactly the read-only byte surface',
    JSON.stringify(p) === JSON.stringify(['allow-terminal-ack', 'allow-terminal-close', 'allow-terminal-stream']),
    `terminal.json permissions: ${JSON.stringify(p)}`,
  );

  check(
    'and no command for input or resize exists anywhere in this process',
    !/terminal_input|terminal_resize|terminal_write/.test(main + build),
    'SHAPE or DRIVE has an entry point — read-only is meant to be structural, '
      + 'not a stage the code is passing through',
  );

  check(
    'the pane that renders a terminal cannot decide one exists',
    !(term.json.permissions ?? []).includes('allow-terminal-surface'),
    'terminal.json holds allow-terminal-surface — the renderer could then '
      + 'create its own surface, and a webview that can open webviews is not '
      + 'a leaf',
  );
}

/* ── D.1.3c·2c·1b·1 · the terminal surface is a PRODUCT surface ──────────

   Two properties, and the second is the security-relevant one.

   **It is not behind the testing witness.** `SUPER_COCKPIT_PANE=1` is what
   `tools/cockpit-battery.mjs` sets to open the untrusted pane. Until this
   slice the terminal webview was created in the same branch, so normal
   Super rendered `Watch terminal` on every PRESENT Worker and had nowhere
   to put one: no webview, no sink, and `Terminal::park` refuses before a
   socket exists. A capability reachable only from a test harness is not a
   capability, and the gate holds the separation rather than the comment.

   **It cannot be aimed.** `terminal_surface` creates a webview, which is
   the one command in this process that could become "open a page of my
   choosing inside the trusted window" by growing an argument. The label
   and the URL are module constants; the command's only page-supplied
   parameter is a boolean. That is checked structurally, because the
   difference between this and an arbitrary-webview factory is one
   parameter.                                                            */
{
  const decl = main.match(/async fn terminal_surface\(([\s\S]*?)\)\s*->/);
  check(
    'terminal_surface exists and is declared once',
    !!decl,
    'no `async fn terminal_surface(..) ->` in main.rs',
  );

  if (decl) {
    /* Everything the caller could supply. `app` and `queue` are injected by
       Tauri from managed state and are not page arguments.

       Split at depth zero: `queue: State<'_, Queues>` contains a comma and
       naive splitting reported a parameter called `Queues>`, which is the
       parser being wrong about the source rather than the source being
       wrong — and a gate that fails for its own reasons trains people to
       ignore it. */
    const params = [];
    let depth = 0;
    let cur = '';
    for (const ch of decl[1]) {
      if (ch === '<' || ch === '(' || ch === '[') depth += 1;
      if (ch === '>' || ch === ')' || ch === ']') depth -= 1;
      if (ch === ',' && depth === 0) { params.push(cur.trim()); cur = ''; continue; }
      cur += ch;
    }
    if (cur.trim()) params.push(cur.trim());
    const supplied = params.filter(
      (s) => s && !/^app\s*:/.test(s) && !/^queue\s*:/.test(s),
    );
    check(
      'terminal_surface takes exactly one page-supplied argument, a boolean',
      supplied.length === 1 && /^open\s*:\s*bool$/.test(supplied[0]),
      `page-supplied parameters: ${JSON.stringify(supplied)}`,
    );
  }

  check(
    'the terminal label and page are constants, not parameters',
    /const TERMINAL_LABEL: &str = "terminal";/.test(main)
      && /const TERMINAL_URL: &str = "terminal.html";/.test(main)
      && /WebviewBuilder::new\(\s*TERMINAL_LABEL,\s*tauri::WebviewUrl::App\(TERMINAL_URL\.into\(\)\),/.test(main),
    'the terminal webview is built from something other than the two constants',
  );

  /* Every webview this process can construct, by the string it is built
     from. Two, and both are literals in this file. */
  const built = [...main.matchAll(/WebviewUrl::App\(([\s\S]*?)\.into\(\)\)/g)]
    .map((m) => m[1].trim());
  check(
    'this process can construct exactly two webviews, both named in source',
    built.length === 2 && built.includes('"pane.html"') && built.includes('TERMINAL_URL'),
    `WebviewUrl::App call sites: ${JSON.stringify(built)}`,
  );

  /* The `if pane {` block, isolated, so what it still governs is checked
     rather than described. */
  const witness = main.match(/if pane \{([\s\S]*?)\n            \}/);
  check(
    'SUPER_COCKPIT_PANE governs the untrusted witness and nothing else',
    !!witness
      && /"pane"/.test(witness[1])
      && !/TERMINAL_LABEL/.test(witness[1])
      && !/terminal\.html/.test(witness[1]),
    'the terminal webview is created inside the SUPER_COCKPIT_PANE branch — '
      + 'the product surface would exist only when a test harness asks for it',
  );

  check(
    'the product path opens the surface before it binds a terminal',
    /if \(name === 'terminal_bind'\) await terminalSurface\(true\);/.test(cockpitJs),
    'cockpit.js submits terminal_bind without ensuring a sink — the runtime '
      + 'would refuse it for a reason about our startup order, not authority',
  );
}

/* ── W.2.2 · and the same rule where it is actually enforced ─────────────
   A lossy send on a message that RELEASES the delivery valve is the second
   W.2.2 defect: `try_send` on a full bounded channel returns `Full` and the
   message is gone, so a dropped `Ack` leaves `in_flight` occupied and a
   dropped `HoldEnd` leaves `holds` non-empty — permanently, because the
   frontend does not retry. There is now no call site in this program that
   can discard one, and the cheapest way to keep it that way is to refuse
   the method by name.                                                    */
const worker = readFileSync(`${ROOT}/cockpit/src/worker.rs`, 'utf8');
/* Code lines only. Both files DISCUSS `try_send` at length — the defect is
   the point of the comment — and a scan that could not tell the account of
   a defect from the defect would make the fix unwritable. */
const lossy = `${main}\n${worker}`
  .split('\n')
  .filter((l) => !l.trimStart().startsWith('//') && /\btry_send\b/.test(l))
  .map((l) => l.trim());
check(
  'no valve-control message is sent lossily — `try_send` appears nowhere',
  lossy.length === 0,
  lossy.join(' | '),
);

/* ── W.2.3.1 · the one Tauri internal the page is allowed to touch ───────
   Recovering from a lost transport index means retiring a `Channel` whose
   own cleanup can never run, and the only way to do that is
   `__TAURI_INTERNALS__.unregisterCallback` — the body of Tauri's own
   `Channel.cleanupCallback()`. That is a real dependency on an internal and
   it is declared here rather than discovered later.

   `runCallback` is the seam beside it that looks equivalent and is not.
   `scripts/core.js` installs it with `Object.defineProperty(obj, name,
   {value})`, whose omitted `writable` and `configurable` both default to
   false — MEASURED on the running app: assigning to it throws `TypeError:
   Attempted to assign to readonly property`, and redefining it throws too.
   A page that reached for it would ship a recovery path that dies on its
   first line, in a module (strict mode) where the failure is an exception
   rather than a silent no-op. Refused by name so nobody has to rediscover
   that. The battery's sabotage reaches the same layer through the
   `callbacks` map, which Tauri exposes and which is mutable.            */
const uiSrc = readFileSync(`${ROOT}/cockpit/ui/cockpit.js`, 'utf8');
const ui = uiSrc.split('\n');
/* **Block comments are removed as spans, not line by line.**
 *
 * This used to drop lines whose first non-space character was `*`, `/*` or
 * `//`, which is not what a comment is: the prose in this file wraps without
 * a leading `*`, so the second and later lines of every explanation counted
 * as code. It happened to be harmless for the three W.2.3.1 checks below —
 * measured, both ways, rather than assumed — and it was not harmless for the
 * W.2.3.3 check that refuses `heard_at` by name, which fired on the sentence
 * describing why the name is refused. **A scan that cannot tell the account
 * of a defect from the defect makes the fix unwritable**; the `try_send`
 * check above says so in as many words and then does the same thing.
 */
const codeLines = uiSrc
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/(^|[^:])\/\/.*$/gm, '$1')
  .split('\n');
const internals = codeLines.filter((l) => /__TAURI_INTERNALS__\s*\??\s*\.\s*(\w+)/.test(l))
  .map((l) => l.trim());
const allowed = /__TAURI_INTERNALS__\s*\??\s*\.\s*unregisterCallback\b/;
check(
  'the page reaches for exactly one Tauri internal, and it is the declared one',
  internals.length > 0 && internals.every((l) => allowed.test(l)),
  internals.length === 0
    ? 'no reference found — the channel a rebind replaces is no longer retired'
    : internals.join(' | '),
);
check(
  '`runCallback` is not reached for — it is readonly and assigning to it throws',
  !codeLines.some((l) => /\brunCallback\b/.test(l)),
  codeLines.filter((l) => /\brunCallback\b/.test(l)).map((l) => l.trim()).join(' | '),
);

/* ── W.2.3.1 · only a frame may end a withdrawal ─────────────────────────
   W.2.3 called `restore()` from the heartbeat arm, so evidence that the
   LINK was alive cleared a claim about the WORLD. Those are two different
   facts and this round is about the case where they come apart.

   **Checked statically, and that is a real limitation, stated.** On the
   shipped host a fresh channel's first message is always a frame — the
   loop delivers before it beats — so there is no window in which a
   heartbeat could reach a withdrawn page first, and therefore no dynamic
   witness to write. That the rule holds today by another process's emit
   order is exactly the reason to make it hold by construction instead: a
   turn that beat before it delivered would silently reintroduce it.       */
const heartbeatArm = (() => {
  const src = ui.join('\n');
  const at = src.indexOf("msg.schema === 'cockpit-heartbeat@1'");
  return at === -1 ? null : src.slice(at, src.indexOf('\n  }', at));
})();
const restoreCalls = codeLines.filter((l) => /(^|[^.\w])restore\s*\(/.test(l)).map((l) => l.trim());
check(
  'a withdrawal is ended by a frame and by nothing else — `restore` has one call site',
  heartbeatArm !== null && !/\brestore\s*\(/.test(heartbeatArm)
    && restoreCalls.filter((l) => !l.startsWith('function ')).length === 1,
  heartbeatArm === null
    ? 'the heartbeat arm could not be located'
    : `heartbeat arm mentions restore: ${/\brestore\s*\(/.test(heartbeatArm)}; `
      + `call sites: ${restoreCalls.join(' | ')}`,
);

/* ── W.2.3.3 · the collapsed clock, refused by name ──────────────────────

   W.2.3.2 wrote one field, `heard_at`, from the top of `deliver` before
   anything had looked at what the message said, and the lease consulted it.
   Two facts were in it — *the link is alive* and *what is on screen is
   still being maintained* — and the heartbeat that could report delivery
   ABANDONED was, by arriving, the thing that kept the page from acting on
   the report.

   The repair is two named clocks. What would undo it is one identifier: a
   single `heard_at` reintroduced anywhere, or `projection_at` written from
   the top of `deliver` beside the link clock. Both are one-line edits under
   which every comment in the file goes on describing a distinction that has
   stopped existing — the same reason `windows` and `try_send` are refused
   above rather than reviewed.                                            */
const collapsed = codeLines.filter((l) => /(^|[^_\w])heard_at\b/.test(l)).map((l) => l.trim());
check(
  'the collapsed clock is gone — `heard_at` names two facts and appears nowhere',
  collapsed.length === 0,
  collapsed.join(' | '),
);

/* **Counted, not merely present.** A clock is only evidence about what
   wrote it, so the whole property is *which lines may write one*:

     link_heard_at    `deliver`, when a message arrived
                      `nextCandidate`, when a candidate was attempted
     projection_at    `deliver`, and only there — the heartbeat arm and the
                      frame arm, which are the two kinds of message that can
                      attest maintenance

   W.2.3.2's `bind()` wrote the clock a third time, in the continuation of
   its own invoke, so a slow or saturated bind minted lease time for the
   candidate it produced — while the comment two functions up said the
   candidate's deadline began at the attempt and was not restarted by
   binding. **The code and the brief disagreed and the code was the one
   running.** There is no dynamic window in which to witness that (a bind
   that resolves in a millisecond moves the clock by a millisecond), so it
   is held here, where it is exactly falsifiable: put the assignment back
   and the count goes to three. Same argument as `restore` above. */
const assigns = (name) => codeLines.filter((l) => new RegExp(String.raw`\b${name}\s*=[^=]`).test(l))
  .map((l) => l.trim());
const linkWrites = assigns('link_heard_at');
const projWrites = assigns('projection_at');
check(
  'the link clock is advanced by an arriving message and by a candidate attempt — nothing else',
  linkWrites.length === 2 && linkWrites.every((l) => /Date\.now\(\)/.test(l)),
  `${linkWrites.length} assignment sites: ${linkWrites.join(' | ')}`,
);
check(
  'and the projection clock only by something that attested the projection',
  projWrites.length === 2 && projWrites.every((l) => /Date\.now\(\)/.test(l)),
  `${projWrites.length} assignment sites: ${projWrites.join(' | ')}`,
);

/* ── W.2.3.3 · a bind and an unbind name the position they address ───────

   `main.rs` claimed a bind and an unbind could not overtake one another
   because they shared the control lane. The lane orders what is IN it;
   getting there is an `async_runtime::spawn` per command and a
   `spawn_blocking` per send, neither ordered against the other. The
   ordering is carried by the message now, and both ends have to keep
   carrying it — a page that stopped sending the identity, or a host that
   stopped comparing it, would restore the hazard with the prose intact. */
const streamed = ['bind_frame_stream', 'unbind_frame_stream'].filter((cmd) => {
  const call = codeLines.find((l) => l.includes(`'${cmd}'`));
  return call && /\bstream\b/.test(call);
});
check(
  'both stream commands are invoked with the binding they address',
  streamed.length === 2,
  `carry a stream: ${streamed.join(', ') || 'neither'}`,
);
check(
  'and the host compares it — a generation within a page, so a reload is not refused',
  /fn bind\(&mut self, stream: StreamId/.test(worker)
    && /cur\.page == stream\.page && stream\.generation <= cur\.generation/.test(worker)
    && /fn unbind\(&mut self, stream: StreamId/.test(worker)
    && /self\.stream\.as_ref\(\) != Some\(&stream\)/.test(worker),
  'Delivery::bind / Delivery::unbind no longer refuse a superseded binding',
);

console.log(`\n  ${registered.length} commands · granted to webview ${(cap.webviews ?? []).join(', ')}`);
/* Prefixed — see the note in `tools/cockpit-battery.mjs`. */
console.log(`webview acl: ${held} held · ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
