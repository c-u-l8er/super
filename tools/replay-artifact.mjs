/* replay-artifact — prove the archive IS the bytes the gates tested.

       bytes the gates tested == bytes handed to the packager
                              == bytes inside the final ZIP

   **W.1.4.2's VERSION PROVED A SET PROPERTY AND ITS RECEIPT CLAIMED A BYTE
   PROPERTY.** Two archives were built to show the gap, and it accepted both:

     A   the same archive with `site/preview/hero-light-preview.png`
         removed. Accepted — because the expected file list was produced by
         walking the EXTRACTED ARCHIVE:

             const walked = shipped(tmp);                 // from the archive
             const short  = walked.filter(w => !inArchive.has(w));

         A file absent from the archive cannot appear in `walked`, so
         `short` was empty by construction. The branch that was supposed to
         name missing files could never name one. Dead code that read like
         a check.

     B   the same paths, the same count, no NUL byte, and one line of
         `site/app-prototype.html` reverted to a known-bad `stabilityToken`
         returning the view clock instead of the projection digest.
         Accepted, reporting the same figures. Running that archive's OWN
         `authority-battery.mjs` against its OWN bytes fails six of its
         assertions — beside a receipt recording zero failures.

   B is the one that matters. The whole point of binding figures to a hash
   is that the figures describe the thing the hash names, and a semantic
   tamper that preserves path and count passed silently.

   So the expected side now comes from the PRE-PACKAGE MANIFEST written by
   `package.mjs` — the tree the gates ran against — and the actual side is
   derived from the RAW ZIP ENTRIES, hashing each entry's decompressed
   bytes. Neither side is inferred from the other. Any missing path, extra
   path, or differing byte refuses.

   The comparison is over CONTENT, never ZIP metadata, so it is unaffected
   by the archive not being byte-reproducible: entry order, timestamps,
   compression method and permissions do not enter the digest.

   Usage:  node tools/replay-artifact.mjs <zip> <pre-package-manifest>    */

import { readFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, isAbsolute } from 'node:path';
import { counted, TEXT, digestOf } from './release-scope.mjs';

const here = new URL('.', import.meta.url).pathname;
const root = here + '..';
const zipArg = process.argv[2];
const manifestPath = process.argv[3];
if (!zipArg || !manifestPath) {
  console.error('replay: usage — node tools/replay-artifact.mjs <zip> <pre-package-manifest>');
  process.exit(1);
}
/* An absolute path used to be silently joined onto the tree root, which
   turned "point this at an archive elsewhere" into a confusing stack trace
   from python. */
const zipPath = isAbsolute(zipArg) ? zipArg : join(root, zipArg);
if (!existsSync(zipPath)) { console.error(`replay: no such archive — ${zipPath}`); process.exit(1); }

const fail = [];

/* The expected side: written before packaging, from the gated tree. */
const manifestText = readFileSync(manifestPath, 'utf8');
const [expectedDigest, ...manifestLines] = manifestText.trimEnd().split('\n');
const expected = new Map(manifestLines.map(l => {
  const [sha256, size, ...rest] = l.split('\t');
  return [rest.join('\t'), { sha256, size: Number(size) }];
}));

/* The actual side: each entry's decompressed bytes, hashed from the archive
   itself. Not a walk of an extracted tree — that is the mistake this file
   exists to not repeat. */
const raw = execFileSync('python3', ['-c', `
import sys, zipfile, hashlib
z = zipfile.ZipFile(sys.argv[1])
for n in z.namelist():
    if n.endswith('/'): continue
    b = z.read(n)
    print(hashlib.sha256(b).hexdigest() + '\\t' + str(len(b)) + '\\t' + n)
`, zipPath], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).trimEnd();

const actualEntries = raw ? raw.split('\n').map(l => {
  const [sha256, size, ...rest] = l.split('\t');
  return { sha256, size: Number(size), path: rest.join('\t') };
}) : [];
const actual = new Map(actualEntries.map(e => [e.path, e]));

const missing = [...expected.keys()].filter(p => !actual.has(p));
const extra   = [...actual.keys()].filter(p => !expected.has(p));
const changed = [...expected.entries()]
  .filter(([p, e]) => actual.has(p) && actual.get(p).sha256 !== e.sha256)
  .map(([p, e]) => `${p} — gated ${e.sha256.slice(0, 12)}…, archive ${actual.get(p).sha256.slice(0, 12)}…`);

if (missing.length) fail.push(['files the gated tree shipped that the archive does not contain', missing]);
if (extra.length)   fail.push(['files in the archive that the gated tree did not ship', extra]);
if (changed.length) fail.push(['files whose BYTES differ from the ones the gates tested', changed]);

/* The digest is the single-value form of the same comparison. It is checked
   as well as the per-file diff, because the diff is for a human and the
   digest is what the receipt carries. */
const actualDigest = digestOf(actualEntries);
if (actualDigest !== expectedDigest) {
  fail.push([`content digest: gated ${expectedDigest.slice(0, 16)}…, archive ${actualDigest.slice(0, 16)}…`,
             ['A measurement is evidence about bytes, not filenames or counts.']]);
}

/* And the figure the receipt binds still has to reproduce. Kept from
   W.1.4.2 — byte identity implies it, but this ties the archive to the
   RECEIPT rather than to the tree, which is a different edge. */
const tmp = mkdtempSync(join(tmpdir(), 'super-replay-'));
try {
  execFileSync('python3', ['-c', 'import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])',
                           zipPath, tmp], { encoding: 'utf8' });

  const receipt = JSON.parse(readFileSync(join(root, 'site/proof/measurements.json'), 'utf8'));
  const claimed = receipt.figures?.source_text_assets?.value;
  const actualCount = counted(tmp).length;
  if (claimed !== actualCount) {
    fail.push([`source_text_assets: the receipt says ${claimed}, the archive contains ${actualCount}`,
               ['This is the W.1.4.1 defect. A figure measured over one set and bound to',
                'another is not a measurement of the release.']]);
  }

  const nul = counted(tmp).filter(rel => readFileSync(join(tmp, rel)).includes(0));
  if (nul.length) fail.push(['literal NUL in shipped text assets', nul]);

  const a = readFileSync(join(root, 'site/proof/measurements.json'));
  let b; try { b = readFileSync(join(tmp, 'site/proof/measurements.json')); } catch { b = null; }
  if (!b) fail.push(['the archive does not contain site/proof/measurements.json', []]);
  else if (!a.equals(b)) {
    fail.push(['the archive ships a different measurements.json than the one being bound',
               [`tree ${a.length} bytes`, `archive ${b.length} bytes`]]);
  }

  if (fail.length) {
    console.error('RELEASE REFUSED · the archive is not the bytes the gates tested.');
    for (const [what, detail] of fail) {
      console.error(`  ${what}`);
      for (const d of detail.slice(0, 12)) console.error(`      ${d}`);
      if (detail.length > 12) console.error(`      … and ${detail.length - 12} more`);
    }
    process.exit(1);
  }

  const textCount = actualEntries.filter(e => TEXT.test(e.path)).length;
  console.log(`replay: ${actualEntries.length} files byte-identical to the gated tree ` +
              `(${textCount} text, content sha256:${actualDigest.slice(0, 16)}…)`);
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
