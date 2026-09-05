/* scope-manifest — the in-scope file set of a SourceBasis, with digests.

   Phase A · A8. Emits the manifest a validation job is admitted against:
   every file the job may read, and the exact bytes each one must have.

   ## Why this is not written in Rust inside the payload

   R0b.0 costed the alternative. `check-source-hygiene.mjs` is a pure
   predicate over the declared source bytes, and the obvious way to run it
   inside a Carrier is to run node inside a Carrier — which needs four more
   Landlock grants against a floor cap of four, plus reversing the `clone`
   denial for libuv. The architecture refuses that, correctly.

   The next obvious move is to reimplement the checker natively. But the
   checker is two things, and only one of them is small:

       WHAT IS IN SCOPE        skip-lists, a TEXT regex, a receipt pattern
       WHAT IS ASSERTED        the file contains no 0x00

   The second is irreducible and fits in a dozen lines of any language. The
   first is a hundred lines of accumulated judgement in `release-scope.mjs`
   — the file that exists because W.1.4.1 bound a figure of 113 to an
   archive containing 112. Reimplementing THAT in a second language is how
   two suites come to disagree about what they are measuring, which is the
   defect `check-source-hygiene` was itself written to prevent.

   So the seam is drawn between them and named rather than hidden. The
   canonical scope logic — this file's `counted()`, unchanged and shared
   with the packager and the gate — derives the manifest here. The Carrier
   evaluates the predicate over that manifest and nothing else.

   The claim the job may then make is exact:

       the Carrier evaluated P over scope manifest M of SourceBasis S

   and NOT

       the Carrier independently derived the release scope

   It did not, and saying so is cheaper than a second implementation.

   ## Why per-file digests, and not just a count

   A9. The job must be able to tell

       PREDICATE_FALSE          a file in scope contains a NUL
       SOURCE_BASIS_MISMATCH    the bytes are not the bytes admitted

   apart. A manifest of paths alone cannot: a file edited between admission
   and execution would make a hygiene verdict about content nobody
   authorized, and the job would report it as an ordinary pass or fail. With
   an expected digest per file the job refuses instead, and a moved basis
   stops being indistinguishable from a property becoming false.

   ## What is deliberately absent

   No absolute path. Entries are relative to the materialization root, which
   is the same reason `source-basis@1` carries a `resource_ref` and not a
   directory: a manifest that named host paths would put one inside the very
   object the job is admitted against.

   No count constant. The number moved 231 → 236 → 237 inside a single day
   of this round, purely because files were added; it is evidence about one
   revision and never vocabulary. `scope_digest` is the identity.

       node tools/scope-manifest.mjs <materialization-root>
       node tools/scope-manifest.mjs <root> --json                          */

import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { counted, serializeManifest, digestOf } from './release-scope.mjs';

/* The in-scope set for a source-hygiene job: exactly `counted()`, which is
   what `check-source-hygiene.mjs` walks. Sharing the function rather than
   the rule is the whole point — a copied predicate is a predicate that can
   drift, and this one has drifted before. */
export function scopeManifest(root) {
  return counted(root).map(rel => {
    const buf = readFileSync(root + '/' + rel);
    return {
      path: rel,
      size: buf.length,
      sha256: createHash('sha256').update(buf).digest('hex'),
    };
  });
}

/* Canonical bytes and their digest, both delegated to `release-scope.mjs`
   so that sorting happens in ONE place. Two sorts in two languages with
   different collation is a way to get two digests for one set. */
export function scopeDigest(entries) {
  return digestOf(entries);
}

export function serialize(entries) {
  return serializeManifest(entries);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = process.argv[2];
  if (!root) {
    console.error('usage: node tools/scope-manifest.mjs <materialization-root> [--json]');
    process.exit(2);
  }
  const entries = scopeManifest(root);
  const digest = scopeDigest(entries);

  if (process.argv.includes('--json')) {
    console.log(JSON.stringify({
      schema: 'scope-manifest@1',
      kind: 'source-hygiene',
      scope_digest: digest,
      entries,
    }, null, 2));
  } else {
    process.stdout.write(serialize(entries));
    console.log(`scope manifest: ${entries.length} file(s) · scope_digest ${digest}`);
  }
}
