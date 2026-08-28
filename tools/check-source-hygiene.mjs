/* check-source-hygiene — the browser battery must run the browser's source,
   and the gate must measure the set the receipt binds.

   `site/app-prototype.html` carried one literal U+0000, written as a raw
   byte inside a string literal:

       const key = p.kind+'<NUL>'+r;          (intersectScope, W.1.3.2)

   The intent was sound — a separator that cannot occur in a kind or a
   resource name. The encoding was not, and it split the two things that are
   supposed to be the same source:

     tools/authority-battery.mjs   reads the file as UTF-8, pulls <script>
                                   text out with a regex, and evals it, so
                                   the separator is U+0000.

     an actual browser             tokenises it. WHATWG HTML specifies that
                                   U+0000 in the script-data state is a parse
                                   error and is emitted as U+FFFD, so the
                                   separator is U+FFFD.

   Measured, not inferred: before the fix the live DOM contained exactly one
   U+FFFD and zero U+0000, and the battery's copy the reverse. Both characters
   happen to work as a separator, so nothing was wrong — which is the problem.
   A parity gap that is currently harmless is a parity gap you find out about
   from the one that is not, and the suite called "the browser battery" was
   not executing what a browser executes.

   So: no NUL in any text asset. Not "no NUL in HTML" — the same byte breaks
   diffing, `grep` (which silently reclassifies the file as binary and reports
   NO matches with exit 1 — that cost this session a wrong diagnosis before it
   cost it the right one), and every tool that assumes text. Write the six
   characters \u0000.

   **W.1.4.2 MOVED THE UNIVERSE OUT OF THIS FILE.** It used to keep its own
   skip-lists, and they described a set that was neither what the packager
   shipped nor what the receipt claimed. Three files this gate exists to
   protect were outside it — `ampd/c_src/ampd_fd_nif.c` (the twelve lines of C
   `release.sh` ships specifically to be compiled at the far end),
   `host/Cargo.lock`, and `site/preview/preview-meta.json` — and one file that
   was NOT shipped was inside it, which is how W.1.4.1's receipt came to say
   113 about an archive containing 112. `tools/release-scope.mjs` is now the
   single declaration, the packager derives from it, and the post-package
   replay proves the archive agrees. See that file for the full account.   */

import { readFileSync } from 'node:fs';
import { counted } from './release-scope.mjs';

const here = new URL('.', import.meta.url).pathname;
const root = process.argv[2] || here + '..';

const bad = [];
const files = counted(root);

for (const rel of files) {
  const buf = readFileSync(root + '/' + rel);
  const n = buf.indexOf(0);
  if (n < 0) continue;
  const line = buf.subarray(0, n).toString('utf8').split('\n').length;
  const total = buf.filter(b => b === 0).length;
  bad.push({ path: rel, line, total,
             ctx: buf.subarray(Math.max(0, n - 30), n + 10).toString('utf8').replace(/\0/g, '<NUL>') });
}

if (bad.length) {
  console.error('source hygiene: literal NUL in text assets');
  for (const b of bad) {
    console.error(`  ${b.path}:${b.line} — ${b.total} NUL byte(s)`);
    console.error(`    …${b.ctx.trim()}…`);
  }
  console.error('  A browser emits U+FFFD for U+0000 in script data; the battery evals the');
  console.error('  raw bytes and sees U+0000. The two suites are then not running the same');
  console.error('  source. Write the textual escape \\u0000 instead of the byte.');
  process.exit(1);
}

console.log(`source hygiene: clean — ${files.length} source text assets, 0 NUL bytes`);
