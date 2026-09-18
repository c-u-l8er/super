#!/usr/bin/env node
/* check-reference-text — a record id on screen is a reference, by construction.

   WHAT WENT WRONG (2026-09-18)

     cockpit/ui/references.js renders ids in text as links with a tooltip
     (`a[data-record-ref]`), and app-shell.js's `node()` used it — for `<p>`
     only. Every span, summary, heading, list item and button that carried an
     id printed it as plain text, and the id pattern beside the kinds table
     had been typed by hand, so plans (dt_) and review attempts (da_) were
     never references even inside a paragraph. Five files, six sites, found by
     eye. Travis: "standardize so this bug doesn't happen again during dev".

   WHAT THIS HOLDS

     1. text sinks — no `.textContent =`, `.innerText =` or `createTextNode(`
        whose expression carries a record id (`.id`, `.ref`, `*_ref`, a literal
        `dt_0052`) anywhere under cockpit/ui or mobile/ui, outside the renderer
        itself. Those paths bypass referenceText. A genuinely plain sink says so
        on the same line, as a block comment reading `plain-text: <why>`.
     2. element factories — any file that builds elements generically
        (`createElement(tag)`) must route text through `referenceText`. This is
        how app-shell.js's `node()`, development.js's `el()` and the phone's two
        helpers were each, separately, the exception.
     3. the kinds table — every collection the palette finder searches
        (cockpit/ui/record-finder.js) is a kind in references.js, so anything
        the palette can list can be linked; and the derived pattern matches an
        id of every kind in the table.
     4. the runtime projects every collection the table names, so the table
        cannot name a bucket nobody fills.

   Static: seconds, no browser. tools/reference-text-smoke.mjs is the driven
   half — it walks every screen and asserts no id is outside a reference.

     node tools/check-reference-text.mjs                                     */
import {readFileSync, readdirSync, existsSync} from 'node:fs';
import {resolve, dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DIRS = ['cockpit/ui', 'mobile/ui'];
for (const d of DIRS) if (!existsSync(resolve(root, d))) { console.error(`check-reference-text: ${d} is missing — nothing to measure`); process.exit(2); }
const {referenceKinds, referencePattern} = await import(pathToFileURL(resolve(root, 'cockpit/ui/references.js')).href);

let held = 0; const failures = [];
const ok = (what, pass, detail = '') => { if (pass) held++; else failures.push(what + (detail ? ` — ${detail}` : '')); };

const files = DIRS.flatMap(d => readdirSync(resolve(root, d)).filter(f => f.endsWith('.js')).map(f => join(d, f)));
const RENDERER = 'cockpit/ui/references.js';
/* An id-bearing VALUE flowing into text — not a comparison of ids
   (`c.id===a.id` selects a record; it does not print one). */
const idish = expr => {
  if (/\b(?:[a-z]{2})_\d{3,}\b/.test(expr)) return true;
  for (const m of expr.matchAll(/\.(id|ref)\b|\b\w*_ref\b|\bticket_id\b/g)) {
    const after = expr.slice(m.index + m[0].length).trimStart(), before = expr.slice(0, m.index).trimEnd();
    const lhs = before.match(/[\w$.?[\]'"]+$/)?.[0] ?? '', op = before.slice(0, before.length - lhs.length).trimEnd();
    if (/^[=!]==?/.test(after) || /[=!]==?$/.test(op)) continue;
    return true;
  }
  return false;
};
const lineOf = (src, i) => src.slice(0, i).split('\n').length;

/* The expression after a sink, to the statement's end at nesting depth 0,
   honouring strings and template literals (their `${}` nests). */
function expression(src, from, closer) {
  let depth = 0, i = from, quote = null, tpl = 0;
  for (; i < src.length; i++) {
    const c = src[i], prev = src[i - 1];
    if (quote) { if (c === quote && prev !== '\\') quote = null; continue; }
    if (c === '`') { tpl = tpl ? tpl : 0; quote = null; /* template: scan to its end, tracking ${ } */
      let j = i + 1, d = 0; for (; j < src.length; j++) { const k = src[j]; if (k === '\\') { j++; continue; } if (d === 0 && k === '`') break; if (k === '$' && src[j + 1] === '{') { d++; j++; continue; } if (d && k === '}') d--; }
      i = j; continue; }
    if (c === '"' || c === "'") { quote = c; continue; }
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) { if (depth === 0) break; depth--; }
    else if (depth === 0 && (c === ';' || c === '\n' || (closer === ',' && c === ','))) break;
  }
  return src.slice(from, i);
}

// 1. text sinks
const sink = /\.(?:textContent|innerText)\s*=(?!=)|createTextNode\(/g;
for (const file of files) {
  if (file === RENDERER) continue;
  const src = readFileSync(resolve(root, file), 'utf8');
  for (const m of src.matchAll(sink)) {
    const start = m.index + m[0].length, expr = expression(src, start, m[0].endsWith('(') ? ')' : ';');
    if (!idish(expr)) continue;
    const line = lineOf(src, m.index), text = src.split('\n')[line - 1];
    if (/\/\*\s*plain-text:\s*\S/.test(text)) continue;
    ok(`text sink bypasses referenceText: ${file}:${line}`, false, `${m[0].trim()} ${expr.trim().slice(0, 70)}`);
  }
}
ok('no text sink under cockpit/ui or mobile/ui writes a record id as plain text', failures.length === 0);

// 2. element factories
for (const file of files) {
  if (file === RENDERER) continue;
  const src = readFileSync(resolve(root, file), 'utf8');
  const at = src.indexOf('createElement(tag)');
  if (at < 0) continue;
  const imports = /import\s*\{[^}]*\breferenceText\b[^}]*\}\s*from\s*'[^']*references\.js'/.test(src);
  const routes = src.slice(at, at + 600).includes('referenceText(');
  ok(`element factory routes text through referenceText: ${file}`, imports && routes, imports ? 'the factory body does not call referenceText' : 'references.js is not imported');
}

// 3. the kinds table
const kinds = referenceKinds();
const finder = readFileSync(resolve(root, 'cockpit/ui/record-finder.js'), 'utf8');
const searched = [...finder.matchAll(/^\s*\['([a-z_]+)','([^']+)'/gm)].map(m => ({collection: m[1], kind: m[2]}));
ok('the palette finder declares its collections in the shape this gate reads', searched.length >= 6, `${searched.length} rows`);
for (const s of searched) ok(`finder collection ${s.collection} is a reference kind`, kinds.some(k => k.collection === s.collection), `ids from ${s.collection} would print plain`);
for (const k of kinds) ok(`pattern matches a ${k.kind} id (${k.prefix}_0001)`, referencePattern().test(`${k.prefix}_0001`));
ok('the pattern is derived, not typed: no hand-written prefix list remains in references.js', !/\(\?:ws\|gl\|ln\|wk\|rp\|bt\)/.test(readFileSync(resolve(root, RENDERER), 'utf8')));

// 4. the runtime fills every collection the table names
const exDir = resolve(root, 'ampd/lib');
if (existsSync(exDir)) {
  const walk = d => readdirSync(d, {withFileTypes: true}).flatMap(e => e.isDirectory() ? walk(join(d, e.name)) : e.name.endsWith('.ex') ? [join(d, e.name)] : []);
  const elixir = walk(exDir).map(f => readFileSync(f, 'utf8')).join('\n');
  for (const k of kinds) ok(`the runtime names collection "${k.collection}"`, elixir.includes(`"${k.collection}"`), 'no Elixir source mentions it');
} else ok('ampd/lib present for the collection census', false, 'ampd/lib missing');

if (failures.length) { console.error(`check-reference-text: ${failures.length} FAILED · ${held} held`); for (const f of failures) console.error('  ' + f); process.exit(1); }
console.log(`check-reference-text: ${held} checks held`);
