/* package — write the archive from `release-scope.mjs`, and from nothing else.

   **THERE WERE TWO PACKAGERS AND THEY DID NOT AGREE.** `release.sh` chose
   between them on whether the `zip` binary happened to be installed:

     zip     -x "ampd/_build/*" "ampd/priv/data/*" "ampd/priv/*.so"
                "host/target/*" "*.zip" "*.orig" "old_scrap/*"

     python  skip ./ampd/_build ./ampd/priv/data ./ampd/.elixir_ls
                  ./.git ./host/target ./old_scrap
             skipfiles .so .zip .orig

   The `zip` path excludes neither `.git` nor `.elixir_ls`; the `python` path
   excludes both. Neither excludes `deps`, which the hygiene walker did. So
   the bytes a revision names depended on the toolchain of the box that
   packaged it — in a system whose subject is identity and provenance, and
   whose own release script carries a paragraph titled A REVISION MUST NAME
   ONE BYTE HISTORY.

   The divergence never fired: `super/` has no `.git` of its own, `.elixir_ls`
   is absent, `ampd/deps` is absent, and this box has no `zip`. One
   `mix deps.get` before a release is all it would have taken.

   One packager now, over `shipped()`, in sorted order — because a ZIP whose
   entry order depends on readdir order is a different byte history for the
   same content. Node has no archive writer in its standard library, so the
   file list is computed here and handed to python's `zipfile`; the LIST is
   the interface, and it comes from exactly one declaration.               */

import { writeFileSync, mkdtempSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { shipped, undeclared, contentManifest, serializeManifest, digestOf } from './release-scope.mjs';

const here = new URL('.', import.meta.url).pathname;
const root = here + '..';
const zip = process.argv[2];
/* **THE PRE-PACKAGE MANIFEST IS WRITTEN OUTSIDE THE TREE.** It records the
   exact bytes handed to the packager, and `replay-artifact.mjs` compares the
   produced archive against it. It cannot live in the tree: a file describing
   the content digest would be part of the content it describes. */
const manifestOut = process.argv[3];
if (!zip) { console.error('package: usage — node tools/package.mjs <zip-name> [manifest-out]'); process.exit(1); }

/* A shipped file that the scope declaration has no opinion about is refused
   rather than packaged. `ampd/erl_crash.dump` is why: five megabytes of a
   BEAM that died during boot, gitignored, 40% of the archive, shipped for
   four revisions because no list mentioned it either way. Silence is not a
   decision, and this is where silence stops being available. */
const stray = undeclared(root);
if (stray.length) {
  console.error('RELEASE REFUSED · files the scope declaration does not classify:');
  for (const s of stray) console.error(`    ${s}`);
  console.error('  Every shipped file is textual (NUL-scanned and counted) or declared');
  console.error('  opaque. A third category means the archive carries bytes no gate has');
  console.error('  an opinion about. Classify it in tools/release-scope.mjs, or exclude it.');
  process.exit(1);
}

const files = shipped(root);
const manifest = join(mkdtempSync(join(tmpdir(), 'super-pkg-')), 'files.txt');
writeFileSync(manifest, files.join('\n') + '\n');

/* Hashed BEFORE packaging, from the tree the gates ran against. */
const entries = contentManifest(root);
const digest = digestOf(entries);
if (manifestOut) writeFileSync(manifestOut, digest + '\n' + serializeManifest(entries));

execFileSync('python3', ['-c', `
import sys, zipfile, os
zip_path, manifest, root = sys.argv[1], sys.argv[2], sys.argv[3]
names = [l for l in open(manifest).read().split('\\n') if l]
with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
    for rel in names:
        z.write(os.path.join(root, rel), rel)
`, join(root, zip), manifest, root], { stdio: 'inherit' });

console.log(`package: ${files.length} files, ${statSync(join(root, zip)).size} bytes -> ${zip}`);
console.log(`content: sha256:${digest}`);
