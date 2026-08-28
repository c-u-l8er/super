# W.1.4.3 — a measurement is evidence about bytes, not names

**Artifact: `and-super-rev-w143.zip`, with `and-super-rev-w143.receipt.json` beside it.
Predecessor: `W.1.4.2`, `sha256:7dd1ab75…d1ff1`.**

> **Release-evidence only, again. The runtime is not touched.** `observe_once`, multiplicity
> routing and `RefusalLog` are exactly as W.1.4.1 shipped them.

Both of your falsifiers reproduce, and I reproduced them before changing a line. You are right on
every point, including the diagnosis of *why* the check was structurally incapable of firing.

---

## 0 · Measured — `site/proof/measurements.json`

Figures are in the receipt. The numbers that belong in prose are the subject of the round:

```
FALSIFIER A   W.1.4.2 archive, hero-light-preview.png removed, valid ZIP
              W.1.4.2 replay:  exit 0
              W.1.4.3 replay:  REFUSED — names the missing path and both digests

FALSIFIER B   same paths, same counts, no NUL, stabilityToken reverted to
              `return viewClock;`
              W.1.4.2 replay:  exit 0
              that archive's own authority battery, from its own bytes:
                               six assertions FAILED
              W.1.4.3 replay:  REFUSED — names site/app-prototype.html and both digests
```

B is the one that matters, and your framing of it is the correct one: a receipt could carry a
browser-assertion figure with zero failures beside an artifact whose own battery fails six of them.

---

## 1 · The dead branch, confirmed

Your diagnosis is exact. The code was:

```js
const walked = shipped(tmp);                    // tmp = the EXTRACTED ARCHIVE
const short  = walked.filter(w => !inArchive.has(w));
```

Both sides derive from the archive, so `short` was empty by construction. **The branch that was
supposed to name missing files could never name one.** It read like a check and was dead code.

I should flag how this got written, because it is the more useful part. I considered comparing the
archive against the build tree while writing W.1.4.2 and talked myself out of it — the reasoning
was that post-package activity makes the live tree an unreliable comparand. That reasoning was
sound about the *live tree at replay time* and I let it dispose of the whole idea, instead of
reaching the obvious next step: capture the manifest **before** packaging and compare against that.
A correct objection to one implementation retired the requirement.

---

## 2 · The law

Yours, adopted verbatim into the source:

> **Every release measurement must remain bound to the exact bytes whose behaviour produced it.**

And the ladder, which is worth keeping written down because each rung looks like the previous one
already handled it:

```
W.1.3.x   a human copied the wrong measurement
W.1.4.1   a machine measured the wrong file SET
W.1.4.2   the set and the count matched and the BYTES differed
```

---

## 3 · What changed

**`release-scope.mjs`** gains `contentManifest` / `serializeManifest` / `digestOf` /
`contentDigest`. The digest is over sorted `(path, size, sha256(bytes))` — **content, never ZIP
metadata**, so entry order, timestamps, compression method and permissions are excluded by
construction. Sorting happens in exactly one function, so the tree side and the archive side cannot
disagree by collating in two languages.

**`package.mjs`** writes the pre-package manifest — digest on line 1, one `sha256 size path` line
per shipped file — to a path **outside the tree**. It has to be outside: a file describing the
content digest would be part of the content it describes.

**`replay-artifact.mjs`** is rewritten. The expected side is that manifest; the actual side is
hashed from the **raw ZIP entries**, decompressing each and hashing its bytes. Neither side is
inferred from the other. It refuses on any missing path, extra path, or differing byte, and names
which. It also still checks the receipt figure, NUL absence and `measurements.json` byte identity —
byte equality implies those, but they tie the archive to the *receipt* rather than to the tree,
which is a different edge.

It also no longer silently joins an absolute path onto the tree root, which turned "point this at
an archive elsewhere" into a python stack trace.

**Receipt is `release-receipt@3`**:

```json
"release_content_sha256": "…",
"artifact_replay": { "scope": "matched", "content": "byte-identical" }
```

**And the note wording is corrected, which was a fair hit.** W.1.4.2 claimed every figure had been
"re-derived FROM this archive". Four were; the behavioural figures are captured from the gated run.
Claiming re-derivation the tooling does not perform is the same prose-over-evidence gap the proof
battery exists to close, one level up — and it is exactly the kind of sentence this arc keeps
finding. It now says measurements were produced by the gated run and that replay proved the shipped
path set and bytes identical to that tree, so the behavioural figures are bound to the bytes whose
execution produced them, **not re-executed from the archive**.

I agree with your architectural point and it is why I did not take the other route. Re-running the
BEAM battery from the extracted archive would prove *that* archive passes. Proving

```
bytes the gates tested == bytes handed to the packager == bytes in the final ZIP
```

keeps every behavioural measurement attached to the exact code that produced it, for the cost of
one hash instead of four and a half minutes.

---

## 4 · The two falsifiers are in the battery

`tools/sabotage-scope.sh` is nine cases now. The two new ones build **well-formed** archives — this
is semantic tamper, not corruption:

```
a declared file removed from a valid archive          your falsifier A
an archive edited to differ only in CONTENT          your falsifier B
```

Each names the sentence the gate must produce, so a gate that dies for an unrelated reason is not
scored as a catch. I also ran your two originals — the real PNG removal and the full
`stabilityToken` revert — against the new replay outside the harness, and both refuse while the
untampered control passes.

---

## 5 · Still open, and I agree neither should block W.2

**ZIP timestamps.** Identical content still yields a different archive hash, because entry mtimes
vary. Normalising timestamps and permissions would make `sha256` reproducible. The content digest
already gives the "same code" property that actually matters, and the sibling receipt binds the real
byte history, so this is ergonomics rather than evidence.

**Corrupt or truncated archives** fail noisily rather than being accepted. Inferior diagnostics, not
a soundness hole — and, as you say, nowhere near the semantic-tamper acceptance.

**`ampd/erl_crash.dump`** is still in the working tree. Excluded from the archive and gitignored;
yours to delete.

---

## 6 · Sequencing

```
W.1.4.1   at-most-once semantics            accepted, untouched
W.1.4.2   scope + measurement set           concept accepted
W.1.4.3   exact-byte artifact binding       this
W.2       Tauri LIVE LOCAL                   next, with nothing between
```

---

## 7 · Verify

```
bash tools/sabotage-scope.sh                # nine cases, including both of yours
bash tools/release.sh                       # every gate
```

To reproduce falsifier B by hand against this artifact:

```
node tools/package.mjs probe.zip /tmp/man               # manifest from the gated tree
python3 -c "import zipfile,re;
zin=zipfile.ZipFile('probe.zip')
zout=zipfile.ZipFile('tampered.zip','w',zipfile.ZIP_DEFLATED)
[zout.writestr(i, re.sub(rb'function stabilityToken\(b\)\{[^}]*\}',
  b'function stabilityToken(b){ return viewClock; }', zin.read(i.filename))
  if i.filename=='site/app-prototype.html' else zin.read(i.filename)) for i in zin.infolist()]
zout.close()"
node tools/replay-artifact.mjs tampered.zip /tmp/man    # names the file and both digests
```
