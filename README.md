# [&] Super — Rev W.2.3.3 bundle

Open **site/index.html**. Best served over http so the proof fetch and the
portfolio nav are live:

    python3 -m http.server 8000 --directory site   # then http://localhost:8000

(Direct file:// open also works — the page falls back to the build-embedded
copy of the proof artifact and says so in the label.)

## Layout

`site/` is the deployable website, matching the portfolio convention
(`code/site/`, `AmpersandBoxDesign/site/`). Everything the deployed host
serves lives under it and nothing else does — so `site/` can be published on
its own, and the runtime, the host and the gate chain sit beside it rather
than inside it.

    super/
    ├── site/        the website: index, prototype, blueprint, 404, amp-nav,
    │                preview, proof — everything the deployed host serves
    ├── ampd/        the authority runtime (Elixir/OTP)
    ├── host/        super-host (Rust) — a library, with a three-line binary
    ├── cockpit/     the desktop cockpit (Tauri v2) — links the same library
    ├── conformance/ the frozen vector corpus
    ├── tools/       the release gate chain
    ├── docs/        every review brief, under docs/reviews/
    └── old_scrap/   superseded copies, kept rather than deleted

## What's in here
- `site/index.html` — super.computedriven.com. Dark premium hero; a volumetric beam
  sweeps through smoke and lights up the stage, which is the REAL prototype
  embedded live (not a screenshot). Every figure on the page is read from
  `proof/latest.json` and links to its receipt.
- `site/app-prototype.html` — the clickable prototype. Three roots —
  **Bots / Nav / Runtime** — over one world: a Bot explains, Nav organizes
  (grouped screens), Runtime proves (the literal supervision tree). Plus a
  working workspace switcher (trvm ⇄ pricing-page), lanes with
  LOCAL/FLEET/CLOUD placement, kill/restart, engine swap, gate replay,
  rulings, ⌘K. No root is the permanent default: a first-ever launch opens
  on Nav / Mission Control, where a person orients, and after that the
  surface reopens where it was left — on the Bot that was being talked to,
  if that was Bots.
- `site/AGENT_SUPER_APP_BLUEPRINT.md` — the Rev F spec + §11 F.1 review response.
- `ampd/` — the authority runtime (Elixir/OTP). Not simulated.
- `host/` — `super-host`, the Rust host: it creates a `socketpair`, spawns
  `ampd` holding one end as fd 3, takes the human control channel, and
  passes one descriptor per engine over that bridge with `SCM_RIGHTS`.
  **No socket file is ever created**, so there is no path for another
  same-user process to find or race. `super-host verify` drives the C1.1
  acceptance battery **from a separate OS process** — the only gate here
  that does not run inside the BEAM it is testing, and the only one that
  can prove there is nothing on the filesystem to open, that a spawned
  engine inherits exactly one descriptor and no other, and that 96
  concurrent commands down one socket each get their own reply.
- `cockpit/` — the desktop cockpit, a Tauri v2 app. It links `super_host`
  as a library, so the `CockpitLoop` it runs is **the same code**
  `super-host verify` exercises rather than a second implementation of the
  continuity hierarchy that agrees with the first by inspection. A worker
  thread owns the runtime and the human control channel; the WebView
  receives `cockpit-frame@1` over a Channel it hands over itself, and
  submits intents, and can do nothing else — it holds no core Tauri
  permission at all. Two bounded lanes reach that thread: mutations, which
  may make a person wait, and valve control — bind, acknowledge, hold,
  release — which is drained first and can never be dropped.

  **The one law it exists to hold:** the rendered world is a function of the
  last frame and of nothing else. A revocation that resolves SUCCESS moves
  nothing on screen — the row leaves when a frame arrives in which the grant
  is gone. `tools/cockpit-battery.mjs` drives a real WebKit WebView through
  exactly that sequence and holds the intermediate state open, and
  `tools/sabotage-cockpit.sh` requires the named check to go red with the
  fix disabled. The hold is not a timer: `ui/cockpit.js` takes a keyed hold
  on frame delivery for the duration of every submission, which is a
  product rule before it is a testing one — *do not reflow the list a
  person is clicking on.*

  **Two gates, and the outer one is Tauri's.** `build.rs` declares the
  app's commands to the ACL and `capabilities/default.json` grants them to
  the **webview** labelled `main` alone, so a webview the cockpit does not
  trust cannot invoke `intent` at all — a refusal the battery measures
  against a real unprivileged pane rather than reasoning about. The grant
  names a webview and not a window on purpose: Tauri resolves a command
  against the two lists with an **or**, so `windows: ["main"]` would grant
  every webview drawn inside that window, and the browser, Motor and game
  panes Super is heading toward are exactly that. The pane the battery
  refuses is therefore a child webview of the cockpit's own window.

  **A successful send is not a delivery.** Tauri hands a Channel payload
  under 8192 bytes to `webview.eval`, and wry's WebKitGTK `eval` passes the
  script to `run_javascript` and returns `Ok(())` **without inspecting the
  asynchronous result** — with no callback the `Result` is dropped
  (`wry-0.55.1`; upstream wry#1644 reports exactly this losing Channel
  messages and hanging the channel). So the host can be told a frame
  arrived when no JavaScript ever ran. An unacknowledged frame is therefore
  kept whole and **sent again as itself** — same sequence, same bytes,
  never a newer state that would skip one a person was entitled to see —
  the page applies a repeat once and acknowledges it every time, and a
  frame older than one already applied never walks the world backwards.

  **A quiet world and a dead stream are not the same picture.** The host
  says so on the same Channel with a heartbeat, which is not a frame: it
  carries no projection, is not counted, and never writes the world region.
  It carries the valve's own diagnosis — which of *sink*, *in flight* and
  *holds* is false — because a closed valve is the one situation where that
  cannot be asked for. If the page hears nothing at all for longer than the
  lease it was given, it **withdraws**: the badge changes, the world region
  is cleared, and every control that submits authority is disabled. A
  timeout may say *I no longer know this is being maintained*; it may never
  invent world state.

  **And hearing something is not the same as being maintained.** W.2.3.2 had
  one clock, written by every arriving message before anything read what the
  message said — so a heartbeat reporting that the host had *abandoned*
  delivery of a newer frame was, by arriving, the thing that kept the lease
  from firing. The page went on offering authority against a projection it
  had been told was superseded. There are two clocks now and two deadlines —
  *I have heard nothing* and *nothing has confirmed for a whole lease that
  what I am showing is current* — plus an immediate withdrawal when the host
  positively says it gave up. It is not a hypothetical asymmetry: Tauri picks
  a Channel transport by payload size, so a small heartbeat and a large frame
  travel two paths that fail independently.

  **A message is evidence for the position it was issued from.** Every bind
  and unbind names the binding it addresses — `{page, generation}` — and both
  ends refuse anything sent from a position that is no longer live. A stale
  completion still knows which function to call; it has stopped having any
  standing to call it.

      cargo build --release --manifest-path cockpit/Cargo.toml
      node tools/cockpit-battery.mjs        # needs a display + tauri-driver
      node tools/cockpit-bigframe.mjs       # the >8192-byte Channel transport
      node tools/cockpit-maintenance.mjs    # the deadline the shipped retry
                                            # depth makes unreachable

  There is no installer. `bundle.active` is `false`: this builds and runs,
  and nothing here is a thing a person could download.
- `site/proof/` — RESULTS.txt + BRIEF.md (the receipts) and `latest.json`
  (generated). `tools/emit-proof.mjs` regenerates it:

      node tools/emit-proof.mjs

## The light
The hero effect was rebuilt frame-by-frame against the reference
screencast: a fixed vertical shaft drops from the top of the hero,
through drifting smoke, onto the app's top edge — blue column, lower
flare, a warm kiss at the contact point, a bloom that hugs the frame,
and a rim light along the stage's top border (CSS, centered on the
shaft via --bx). It is ambient and looping, fades up once, respects
prefers-reduced-motion (still lit, just not animated), and is pure
Canvas2D — no WebGL, no CDN, nothing that can fail on machines
without hardware acceleration. The app is interactive immediately.

## Release pipeline (truth gates)

    ./tools/release.sh

runs: verify-artifact (the receipt artifact must be complete — gate replay
itself happens upstream in the TRVM repo) -> emit-proof (RESULTS.txt ->
latest.json) -> inject-proof (every #proofEmbed must equal the artifact) ->
stamp-rev (README/blueprint/footer/zip name all derive from release.json)
-> proof-battery (forbidden literals are DERIVED from latest.json; any
occurrence outside #proofEmbed or proof:quoted fences fails) ->
authority-battery (loads the prototype headlessly and runs the falsifier
table: wrong actor/repo/placement/workspace refuse, run-scoped grants
expire, one-shots consume, approval-class effects HOLD until an approval
bound to the exact canonical-SHA-256 intent exists, forged or stale
approvals refuse, grant edits reconcile the whole domain, placement is
derived-and-cited, and consent executes in its held context) ->
render-preview + check-preview (the social image's figures must match the
artifact). Stale embeds, transcribed figures, authority bypasses, and
diverged previews are all release failures, not fallbacks. The pipeline
also re-exports conformance/authority-vectors.json against the frozen
simulator, and replays all <!--vectors-->42<!--/vectors--> vectors on the
BEAM (ampd/, `mix test`: <!--tests-->220<!--/tests-->, 0 failures). That replay is a
LOAD-BEARING gate: release.sh REFUSES on a box without Elixir rather than
printing a release line while half the conformance claim went untested. tools/preview-release.sh is the honest degraded path — it runs
every browser gate, cannot package, and says plainly what it did not
verify. Those figures are stamped by
stamp-counts from the corpus and the suites; a transcribed count fails
the release, because the two that were transcribed drifted for two
revisions.

Two stages were added after packaging at W.1.4.2 and rebuilt at W.1.4.3.
`package.mjs` writes the archive from `release-scope.mjs`, refuses any file
that declaration does not classify, and emits a pre-package content manifest —
sorted `(path, size, sha256(bytes))` over the tree the gates ran against.
`replay-artifact.mjs` then hashes the raw ZIP entries and refuses if any path
or any byte differs from that manifest. The sibling receipt is
`release-receipt@3` and carries `files`, `release_content_sha256` and a
structured `artifact_replay`. The chain also runs the BEAM falsifier battery
now — see below for why that changed.

## The host gates are in the pipeline now

They were not, and F.8.1 is the argument. That release ran the whole chain,
printed "every gate green", and shipped a runtime that leaked a descriptor
on every *rejected* bridge command — a defect no suite running inside the
BEAM can construct, because a descriptor with no Erlang owner only exists
after an `SCM_RIGHTS` receive. The chain that packaged the zip never ran the
one battery that could see it. So `release.sh` now builds the host and runs
both host batteries, and REFUSES without `cargo` exactly as it refuses
without `mix`. Each battery prints its own totals; none of them are
transcribed here, because the two numbers that used to be were both stale
within one revision.

    ./host/target/release/super-host verify         # the acceptance battery
    bash tools/sabotage-host.sh                     # each descriptor fix, falsified
    ./host/target/release/super-host world          # where the durable world lives

## The browser battery must run the browser's source

    node tools/check-source-hygiene.mjs             # no NUL in any text asset

`site/app-prototype.html` carried one literal U+0000 as a string separator
from W.1.3.2 to W.1.3.2b. `authority-battery.mjs` reads the file as UTF-8,
pulls the `<script>` text out with a regex and evals it, so it saw U+0000.
A browser tokenises it, and WHATWG HTML makes U+0000 in the script-data
state a parse error emitted as U+FFFD — so the browser saw U+FFFD. Measured
before the fix: exactly one U+FFFD and zero U+0000 in the live DOM, and the
reverse in the battery's copy.

Both characters work as a separator, so nothing was broken. That is the
reason to care: a parity gap that is currently harmless is one you learn
about from the gap that is not, and the suite called "the browser battery"
was not executing what a browser executes.

The same byte also makes `grep` silently reclassify the file as binary and
report **no matches with exit 1** — indistinguishable from a stale pattern,
and it cost one session a wrong diagnosis before it cost it the right one.

## The counts, and the tool that derives them

    bash tools/sabotage-counts.sh                   # the count gate, falsified

`stamp-counts.mjs` exists so no conformance figure is ever typed, and
nothing checked that it could refuse anything. W.1.3.2a is the argument: a
round whose review brief is largely *about* eliminating count drift shipped
a hand-typed browser count in §10 that disagreed with its own stamped table
two hundred lines above — and the release stayed green, because the
bare-count scan named two READMEs and not the document being reviewed.
Stamping a file and auditing it are different guarantees.

Seven cases, including a clean tree (a gate that refuses everything is not
a gate), a hand-edited marker (which is *restamped*, not refused — a
distinction that had never been measured), and a red battery (whose number
must not get stamped at all: a failing suite's count written in as though
it passed is worse than a stale one, because it is fresh).

## The bracket around the harnesses that write to the source tree

    bash tools/sabotage-guard.sh                    # the bracket itself, falsified

`sabotage-bots.sh` and `sabotage-host.sh` edit files in `site/` and
`ampd/lib` + `host/src` in place and restore them, and they run *after* the
suites that would notice a bad restore. So each is wrapped in a `guarded`
bracket that fingerprints those paths either side. W.1.3.1 introduced the
bracket and wrote, in a review brief, "the guard has its own falsifier."
There was no such harness — the sentence was the proof, which is the exact
defect `proof-battery.mjs` fails the release for, several levels up.

Writing one at W.1.3.2a found that two of the three cases the bracket
claims to catch were not caught. A harness that restored its source and
left its `.orig` behind fingerprinted **identical** and printed "tree
integrity restored" (`fingerprint` excludes `*.orig` by design, and neither
packager did). A harness that died mid-probe took the whole script with it
at `set -e` before the post-fingerprint ran, so a sabotaged file in the
tree produced **no output at all** — packaging stopping is not the same as
the bracket working, and only one of those two was ever true.

The harness runs against a scratch tree it owns, under `set -e` because
that is how `release.sh` calls it, and each case names the sentence the
bracket has to produce. Asserting a nonzero exit is not enough: under the
old bracket both death cases passed that test, because dying *is* a nonzero
exit. A nonzero exit is not a verdict.

## The gate release.sh did not run, until it shipped a bad release

    cd ampd && bash tools/sabotage.sh        # now inside tools/release.sh

It takes four and a half minutes — it recompiles and re-runs the suite once
per probe — and that cost was the argument for keeping it out of the chain:
a gate that slow would get skipped rather than run.

W.1.4 is the counter-argument. It passed every gate in `release.sh`, printed
a release line, and was still wrong — this battery found that one of its
falsifiers had gone dead, and the round had to be re-minted as W.1.4.1. So
`release.sh` green was demonstrably not falsifiers green, and the only
record that the falsifiers had run was a sentence in a review brief, for the
one property that separated the bad artifact from the good one.

It refuses here now exactly as `mix` and `cargo` do, and its figure is bound
to the artifact like every other. `tools/preview-release.sh` is still the
honest degraded path that cannot package.

`sabotage.sh` stubs each fix out and requires the test to go RED — a test
that passes with its fix disabled is an invariant check, not a falsifier.
It also checks that the sabotage still COMPILES, because a sed expression
that breaks the build turns every test red and would otherwise be scored as
the strongest possible result. Two probes carried from C1.1.2 were doing
exactly that; they are re-pointed, and that round's figure should be read as
16 rather than 18.

Adding it to the chain needed one repair first. It and `tools/sabotage-host.sh`
printed byte-identical summary lines, and `emit-measurements.mjs` reads
figures out of the release log by regex — so whichever battery printed first
would have been recorded under the other one's name. `bot`, `guard` and
`count` sabotage were already prefixed; these two were the only ones nobody
had needed to tell apart. They are `beam sabotage:` and `host sabotage:` now.

## The measurement must describe the bytes the receipt binds

    node tools/check-source-hygiene.mjs         # walks tools/release-scope.mjs
    node tools/package.mjs <zip>                # the only packager
    node tools/replay-artifact.mjs <zip>        # re-derived from the archive
    bash tools/sabotage-scope.sh                # the law, falsified

W.1.4.1's receipt recorded 113 text assets and bound it to the SHA-256 of an
archive containing 112. Nothing was transcribed — both numbers came out of
the same tool, on the same tree, within the same minute. The gap was in the
SET: the gate counted the working tree at stage 3, which still held the
previous round's sibling receipt, and `rm -f and-super-rev-*` removed it at
stage 27, one stage before the archive was built.

Looking for the class rather than the instance found it pointing both ways.
`ampd/erl_crash.dump` — five megabytes, gitignored, 40% of the archive —
shipped in every release because no list mentioned it in either direction.
Three shipped files sat outside the gate that exists to protect them:
`ampd/c_src/ampd_fd_nif.c` (shipped specifically to be compiled at the far
end), `host/Cargo.lock`, and `site/preview/preview-meta.json`. And there were
two packagers, chosen on whether the `zip` binary happened to be installed,
excluding different sets — so the bytes a revision named depended on the
toolchain of the box that packaged it.

`tools/release-scope.mjs` is the one declaration now, and the gate, the
packager and the replay all walk it. `replay-artifact.mjs` is what makes that
load-bearing rather than tidy: it extracts the archive that was just built and
re-derives the figures from those bytes. Two walkers reading one declaration
*probably* enumerate the same files, and "probably" is exactly what was true
of the old pair right up until it wasn't.

> **A release measurement must quantify the same artifact set the receipt
> binds. Measurement scope is part of artifact identity.**

That closed the SET defect and left a BYTE defect one level down, which
W.1.4.3 closed. The replay derived its expected file list by walking the
extracted archive:

    const walked = shipped(tmp);              // tmp = the EXTRACTED ARCHIVE
    const short  = walked.filter(w => !inArchive.has(w));

Both sides came from the archive, so `short` was empty by construction — the
branch meant to name missing files could never name one. Two well-formed
archives proved it: one with `site/preview/hero-light-preview.png` removed,
and one with the same paths, the same counts and no NUL byte, whose
`stabilityToken` had been reverted to return the view clock instead of the
projection digest. Both were accepted. The second one's own authority
battery, run against its own bytes, fails six of its assertions — beside a
receipt recording none.

So the expected side is now a PRE-PACKAGE manifest — sorted
`(path, size, sha256(bytes))` over the tree the gates ran against, written
outside the tree — and the actual side is hashed from the raw ZIP entries.
Neither is inferred from the other, and any missing path, extra path or
differing byte refuses. The digest is over content, never ZIP metadata, so it
is unaffected by the archive not being byte-reproducible.

> **Every release measurement must remain bound to the exact bytes whose
> behaviour produced it.**

This is why a content digest beats re-running the suites after packaging.
Re-running the BEAM battery from the extracted archive would prove that
archive passes; proving `bytes tested == bytes packaged == bytes shipped`
keeps every behavioural figure attached to the exact code that produced it,
for the cost of one hash.

## Honesty notes
- **A Bot does not know the world. It knows its projection of the world.** Bots is the third
  root: a Bot explains, Nav organizes, Runtime proves. It is also where every mechanism of the
  last five rounds stops applying, because prose has no cursor, no citation, and nothing in it
  can fail closed. An utterance here is **not world truth — it is a cited derivation from one
  coherent frame**, built once under a stability check and handed over, so every claim shares
  one basis by construction rather than by timing. W.1.3 stamped a cursor after several live
  reads and shipped a torn projection wearing a coherent label: two claims read at views 2 and
  3, stamped 3, marked CURRENT.
- **A Bot learns that its view changed only when its own projection changed.** W.1.3 rode
  `authoritySnapshot()` — a digest over *every* actor's grants — on each utterance so a Bot
  could tell whether its view was stale. W.1.3.1 removed it and left the global view clock,
  which leaks the same fact through a narrower pipe: a Bot that cannot see lanes watched a
  lane change turn its claims stale while its own projection stayed byte-identical. Freshness
  is now digest against digest, and `bot-projection@1` carries no global clock anywhere — not
  in the cursor, not on the basis line, not on the board.
- **Visibility is a grant, scoped by resource, and it is checked per object.** `super.observe.
  lanes · lane-a` used to widen back to every lane, because the projection asked once per
  *kind* and then emitted the category. There is now one scope algebra — `(kind, resource)`
  predicates with `admits` and `intersectScope` — used by both the projection and the group
  boundary, because two implementations of "what may be seen" were wrong in the same
  direction and that is the argument for there being one.
- **A citation existing and a Bot being permitted to read the cited thing are different
  gates.** W.1.3 checked only the first, so Scout — who observes evidence and runtime — could
  assert that three lanes were running. A claim cites an object **id from the frame the Bot
  was handed**; there is no path that accepts a hand-written screen name. An aggregate cites
  every object that established it, and a derived collection is admitted by its members rather
  than its own id, so a summary cannot smuggle three lanes past a boundary permitted none.
- **Freshness belongs to the claim, and the class belongs to the object.** `view_revision`
  moves when a channel opens, so marking whole utterances stale against it turns a
  conversation entirely red within minutes. Four kinds — only `snapshot` decays. And the class
  is not the claim's to declare: labelling a live lane state `durable` made it eternal truth,
  so each frame object now says what it can support. The only durable objects are receipts; if
  none has been minted, a Bot makes no durable claim, rather than demonstrating a class it has
  no object for.
- **STALE and UNESTABLISHED are different facts.** Stale means this *was* a coherent statement
  about a world state that is no longer current — still evidence. Unestablished means no world
  state was ever found in which these facts coexisted — not old truth, unestablished truth. A
  warning badge does not turn a possibly impossible conjunction into a derivation, so an
  unestablished frame supports no factual claim at all. The Bot can still say that it could not
  establish a view; that utterance carries no claims.
- **Creating a Bot confers zero authority, and delegation is not a second way to be
  authorized.** A Bot may delegate only a capability it holds, and the child must narrow or
  equal **every** dimension — resource, duration, workspace, run, placement, budget, policy.
  Capability-and-duration alone cannot see that a delegation turned `human_approval_required`
  into `auto`, which is a different effect on the world than the parent authorized. Revoking a
  parent revokes its children in the same operation. A Bot may **hold** an approval-class
  capability and may never hold the consent: every `approve_*` and `revoke_*` is human-control
  only, and delegating one refuses `human-control-only`.
- **A Group is a governed disclosure context, not ambient Bot-to-Bot memory.** Its scope is
  the intersection of its members' **observation predicates** — not their kind names, which is
  how two Bots with disjoint resources on one kind still disclosed to each other. Adding a
  member can never widen anyone; `bot(*) ∩ bot(auditor)` is exactly Auditor. A claim enters
  only if the *group* projection admits every object it cites — not if the speaker can see it.
  The law is encoded and asserted; no group messaging runtime exists yet.
- **The browser battery had no proof any of its assertions could fail.** That is the gap
  `sabotage-host.sh` closed for the host and nothing had closed here, and this arc has
  already mislabelled three invariant checks as falsifiers. `tools/sabotage-bots.sh` stubs
  each bot law out and requires a named assertion to go RED; it screens for a sabotage that
  breaks the parse and for one that matches nothing, because the first turns every assertion
  red for the wrong reason and the second is a probe gone stale against a refactor. It caught
  two defects in its own first run: an assertion that passed for the wrong reason, and a
  sabotage that was semantically a no-op (`return true && x` is `x`) and so read as the law
  being unfalsifiable.
- **The durable world lives at `$XDG_STATE_HOME/super/worlds/default`**, is `0700`, and
  is never deleted by this program. Until F.8.1 the host pointed its stores at a
  pid-and-timestamp directory and removed it on exit — so quitting Super destroyed the
  world and a crash orphaned one the next launch would never look at. A verification run
  still gets a disposable world of its own, which is the rule that was wrongly being
  applied to both.
- **One host per world**, enforced by an advisory lock held for the host's lifetime; a
  second is refused `world-already-open`.
- **The receiver owns what it receives.** `SCM_RIGHTS` is `dup(2)` into the *receiving*
  process's table, and `socket:close/1` will not `close(2)` a descriptor OTP did not
  create — so a received descriptor had no owner in Erlang and no call that could free
  it. `Ampd.NativeFd` is three syscalls: the sink, the `FD_CLOEXEC` that `dup(2)` drops,
  and a way to observe both. Every descriptor out of ancillary data ends at the sink,
  bound or surplus or rejected. Measured in `super-host verify` as an exact return to
  baseline, and each fix falsified by `tools/sabotage-host.sh`.
- **`adopt_channel/3` consumes its channel argument exactly once** — into a live
  connection, or into a sink — and that holds for refusals as much as successes. F.8.2
  claimed "one sink, three call sites, no fourth exit" and there was a fourth: the fast
  refusal when the control channel is already claimed read the descriptor as `_fd` and
  returned. Discarded in the source, never closed by anything. **100 refused claims, 100
  descriptors**, on the one move a hostile local process always has — asking for
  something it is not permitted to have.
- **Every authority operation executes only in the world its channel was bound to.**
  Closing the channels of a destroyed world is not the same as stopping work that was
  already in flight. Measured: with the coordinator suspended, a world reset and a
  `kestrel` `request_grant` queued behind it — and on resume the request landed in the
  world the reset had just created, actor, capability and reason intact, in a world that
  never had a kestrel. Killing a connection does not retract a message already in another
  process's mailbox. The expectation is captured when the **channel** is bound and checked
  at the linearization point inside the coordinator, which refuses
  `world-incarnation-changed`.
- **A generation change ends an incarnation, and authority is reacquired on the other
  side.** F.8.2.4 fenced the above on installation identity alone, reasoning that a
  restore leaves the actor named and the stores in place. `Ampd.World`'s own definition
  says otherwise — generation moves only when durable truth is *wholesale replaced* — and
  stale consent and stale work are different laws: a queued `request_grant` has no
  approval to invalidate, so it simply opens a new request in the restored world on behalf
  of an actor that world may never have named. The fence is now the whole incarnation, and
  `advance_lineage/2` closes every channel bound to the one that ended, so the person
  reacquires control and each engine reattaches. This is `CLOUD_V1.md` §1 — *state moves,
  authority does not* — made mechanical instead of aspirational.
- **The expectation is sampled at bind time, and that is now actually probed.** F.8.2.4's
  probe replaced the peer record's lineage with `nil`, which proves the expectation must
  *exist*, not when it is read. In a witness whose coordinator is suspended the two sample
  points read the same world, so a submission-time implementation passed it. The witness
  that separates them suspends `Ampd.Bridge` *inside* the advance — manifest already at
  generation 2, channels still bound to generation 1 — and only bind-time sampling refuses
  there.
- **A peer-bound command may return information only from the incarnation that peer
  belongs to.** F.8.2.5 made that true of writes and not of reads, because
  `Authority.in_world/2` only parks a value that `Authority.tx/1` later reads — so a command
  reaching no coordinator was fenced by nothing, and the `:both` commands did not even
  enter it. Measured in the interval a lineage advance opens between its durable bump and
  its channel barrier: the same generation-1 handle got `world-incarnation-changed` for
  `request_grant` and a served `agent_projection` assembled out of generation 2. The fence
  is now at the one chokepoint every peer-bound command passes, and it reads the manifest
  rather than the coordinator — a fence that has to ask the coordinator cannot answer
  during the one operation it exists for, because that operation is holding it.
- **The revision on a projection describes the projection actually returned.** The cursor
  and the content were sampled independently, and Elixir evaluates the cursor first.
  Measured with `Ampd.Session` suspended to park the build between the two: a frame
  labelled `revision 1` whose content was `revision 2`, with the grant an intervening
  revocation removed already absent. That is worse than a stale frame — a client comparing
  cursors believes it has already rendered this state, so the correction never arrives, and
  the correction is a revoked grant still on the screen. Frames are now assembled under a
  continuity seqlock: sample, build, sample again, accept only if nothing moved.
- **A busy world is still an observable world.** The seqlock alone starves — 40 of 40 reads
  failed to settle against a process issuing back-to-back grant edits. Refusing them by
  name was the obvious next move and the wrong one, so the last attempt assembles the frame
  *inside* the total order, where nothing can linearize between the cursor and the content.
  Optimistic first because the pessimistic path makes every mutation wait behind a dozen
  registry reads. There is no `projection-unstable` refusal: the fallback made it
  unreachable, and a code no input can produce is a promise to an operator that nothing
  keeps.
- **The host classifies continuity and reacquires.** `superseded_by` answered "is this
  new", and all three ways a frame can be new demand different actions — apply, resnapshot,
  or discard the authority you are holding and take it again. `Continuity` is that
  hierarchy as an enum, and `CockpitLoop` is the event loop F.8.2.5 reported as not
  existing: it holds human control, holds one coherent projection, and re-establishes both
  when the world says they are no longer valid. Its EOF witness was itself weak — it
  dropped the channel, which exercises the empty-slot path — and `tools/sabotage-host.sh`
  caught that by disabling the EOF check and staying green.
- **A fenced effect request is normalized like every other refusal.** `request_effect` is
  the one command that does not pass through `Control.settled/2`, and `Gateway.perform/5`
  received the coordinator's `refusal@1` through the same `{:refused, _}` tuple it uses
  for its own authorization verdicts. Measured: the agent got a bare `refusal@1` with no
  `allow` key and `operator_detail` still attached — `Refusal.project_result/2` only
  projects a map that carries a `"refusal"` key, so it sailed past the dual-disclosure
  boundary. Shipped in F.8.2.4 and invisible to its battery, whose only fence witness used
  `request_grant`.
- **A continuity frame names which world it is, not merely how far along.** A factory reset
  mints a new installation and sets `generation` back to 1, and the coordinator survives —
  so `world_generation`, `projection_epoch` and even the direction of `revision` all read
  as an ordinary advance. Measured: `w-0d840f34… gen 1 epoch cf7320ae rev 3` →
  `w-0e2b4559… gen 1 epoch cf7320ae rev 4`. Two different worlds, and a client holding the
  old triple would have called the second the next revision of the first. `continuity/0`
  now leads with `world_incarnation` — `H(installation_id ‖ generation)`, hashed because
  installation identity is operator-only while continuity frames go to agents too.
- **A refused channel has ceased to exist before the refusal is observable.** F.8.2.2's
  refusal branch waited a flat second for the connection to die and then returned
  *without rolling back*. Measured: a bind refused into a socket whose send buffer was
  full came back after **1003 ms with the socket still open** — the connection was stalled
  in `socket:send/2`, which waits forever on a peer that is not reading. The refusal frame
  is gone entirely (a channel that never committed has no reader by construction, and the
  refusal reaches its caller by the route they asked on), the rollback is unconditional,
  and the wait shares the startup deadline instead of inventing a second one. Now 2 ms,
  socket closed.
- **No channel outlives the world it was bound to.** `Bootstrap.reset_world!/0` reset
  `Ampd.Peer` and never `Ampd.Bridge`, though the comment above it was already the argument
  for doing both. Measured: after a production world reset, two sockets still open, two
  channels still listed, and **the person refused a control channel in the world they had
  just reset** — the claim held on behalf of a connection to a world that no longer existed.
  World generation changed; capability generation did not. `Bridge.reset/0` is now a
  barrier that terminates and disposes before replying, and it runs *before* `Peer.reset/0`
  so identities are detached by the table that minted them.
- **A channel handoff is a transaction** — committed to one live connection, or rolled
  back completely. F.8.2.1 said ownership moved to the connection process when
  `Connection.start/3` returned; it did not, because a `:socket` handle is owned by its
  `{otp, controlling_process}` and that stayed `Ampd.Bridge`. The startup was a bare
  `spawn` racing a `receive after 5_000` against a `GenServer.call` whose own default
  deadline is also `5_000`, and every abnormal exit fell through the gap. Measured before
  it was fixed: a killed connection left its socket open, its channel listed and its
  identity resolving; a killed *control* connection left `control-channel-already-claimed`
  set forever, so one crash took the person's authority and never gave it back; and a
  suspended `Ampd.Peer` produced a live `kestrel` binding **after** the host had been told
  `channel-bind-failed`. Now: `spawn_monitor` with one ordered deadline, rollback before
  the reply, a `DOWN` backstop in the bridge that owns the socket, and identities that
  cannot outlive the process that asked for them.
- **A baseline taken after the adversary is not a baseline.** F.8.2's exact equalities
  were exact about the wrong number: the battery asked for a second control channel three
  hundred lines above where it measured "baseline", so the leak from its own adversarial
  request had already been absorbed into the number everything else returned to. The
  descriptor baseline is now taken at boot, before anything adversarial runs.
- **F.8.1 called the original leak "bounded by channels ever opened, not by traffic", and
  it was not.** The same false ownership model was in the *rejected*-command path, where
  it cost a descriptor per command: sabotaging that one fix now measures 90 descriptors
  leaked by 30 refused commands. It survived a green release because nothing inside the
  BEAM can construct a descriptor with no Erlang owner, and the release chain never ran
  the one battery that could. It does now, and refuses without it.
- **The sink has no exceptions.** It refused descriptors below 3, reasoning that a
  received one is never 0, 1 or 2 — true of how the host spawns the runtime today, false
  of Linux, and false of a desktop session launching a GUI. That made it an ownership
  exception, which is the bug class it exists to end; it also masked a crash
  (`adopt_channel(-1, …)` took the bridge down once the floor came off). The real hazard
  is closed where it arises: the host guarantees 0, 1 and 2 are open in the child before
  `exec`, so a received channel can never become the runtime's stdout.
- **The DOM is a function of the last frame, and an intent that succeeds
  moves nothing.** The natural way to write a desktop app is to remove the
  row when the call returns, because the call returning *means* the row is
  gone. It does not: it means the runtime accepted the request, and whether
  the row is gone is a fact about the world that the world states in a frame
  carrying the incarnation it was assembled in. Removing it on `allow`
  renders a world nobody asserted — W.1 spent four rounds establishing that
  a projection is truthful, and a WebView that draws its own optimism throws
  all of it away one function call from the end. Measured through a real
  WebView: the grant is still on screen when the revocation resolves
  SUCCESS, still there a second and a half later, and leaves only when the
  frame that removes it arrives. Two things are asserted about that
  interval, not one — the row is present, **and** no frame has been
  delivered — because the first alone would also pass for a renderer that
  received a frame and failed to apply it.
- **A cockpit does not reflow the list a person is clicking on.** Every
  submission takes a hold on frame delivery and releases it when the
  outcome is known. It is why the intermediate state above is a state and
  not a race: the hold and the intent are drained — both of them, to empty
  — by the one thread that also emits, before it computes a frame, so the
  hold is in force before the world can move. **The holds are keyed**, because two
  overlapping clicks against one boolean means the first to finish frees
  the surface underneath the second — one flag carrying two facts, which
  is the same shape as `superseded_by` collapsing three continuity answers
  into one bit.
- **A frame is sent to a sink the page handed over, never to whoever is
  listening.** A global event and an asynchronously-registered listener
  race, and losing that race is not a dropped frame but a wedge: the frame
  is marked in flight, the page never sees it, nothing is acknowledged and
  nothing further may be sent. So the frontend constructs the Channel,
  installs its handler, and only then binds it. A sink that binds *late* —
  after a reload, say — is brought up to the current state rather than
  waiting for the world to change next, or it is a blank cockpit attached
  to a healthy runtime.
- **A command this process registers is reachable only from a webview the
  capability names.** Tauri's default is the opposite: application commands
  are available to every window and webview unless they are declared to the
  ACL. The first version of this shipped a capability describing a boundary
  that was not there, which is worse than a missing boundary because it
  reads as coverage. Measured against a real unprivileged pane, which is
  refused by Tauri — `Command intent not allowed by ACL` — and not by any
  JavaScript of ours. **A WEBVIEW, not a window**: a window-scoped grant
  reaches every webview inside that window, so a pane hosted in the
  cockpit's own frame would inherit human-control authority by being drawn
  there. The witness is a child webview, because a separate window is
  denied under either spelling and would prove the easier thing.
- **A liveness-critical message is delivered when the CONSUMER says so.**
  Producer-side success is not delivery: the send returned `Ok`, the
  JavaScript may never have run, and a valve that treats *sent* as
  *received* closes for the life of the page. Absence of acknowledgement
  must produce retry, recovery, or an explicit loss of the claim — never
  permanent silence. That is the end-to-end argument arriving inside the
  cockpit, and it is why the frame is retransmitted, why the link has a
  heartbeat, and why the page is allowed to stop believing its own screen.
- **A message that releases a gate may not be sent lossily.** New work may
  be refused BUSY — the mutation queue is bounded and a wedged runtime must
  not become a memory leak — but an acknowledgement or a hold release must
  enqueue or say it could not. Sent with `try_send`, they were discarded on
  a full buffer: a lost acknowledgement leaves a frame in flight forever
  and a lost release leaves a hold set non-empty forever, so **the
  congestion signal prevented the message that clears congestion**, and
  nothing retried either. Two lanes now, both bounded, both blocking,
  control drained first. Measured by saturating the mutation lane on
  purpose and issuing the release inside that window.
- **The cockpit cannot ask the world a question.** Its intent surface is
  human-control mutations and nothing else, checked against
  `Ampd.CommandSpec` rather than against the comment beside it. A cockpit
  that could call `operator_projection` would hold a second view with no
  incarnation, no epoch and no revision attached to it, and could render
  from that instead — a second way to learn the world is a second source of
  truth however carefully the first one was built.
- **There is still no desktop app to install.** The cockpit builds and runs;
  `bundle.active` is `false` and there is no installer, no signing and no
  update path. The site says no desktop app exists, which remains true of
  the thing a person would download.
- The web prototype is SIMULATED RUNTIME (badged in its topbar): that state
  machine is still JavaScript, and it is the frozen executable spec the
  conformance vectors are exported against — deliberately not replaced by
  `ampd/`, because a simulator that tracks the implementation cannot
  contradict it. Its dashboard figures are bound to proof/latest.json, and
  its gate replay derives every number it prints from that artifact.
- Tiers are labeled planned.
- preview/hero-light-preview.png is generated from the same artifact
  (the figures in the image are read from latest.json) and is wired as
  og:image for shares.
- Figures the artifact doesn't establish are hidden, not invented.



## Desktop app connection — 2026-09-06

The cockpit now presents Mission Control, Workspaces & lanes, Capabilities,
Evidence and Runtime as navigable pages over its existing live frame stream.
Bots offers browser sign-in for ChatGPT / Codex, a local Claude CLI connection, automatic local Ollama connection,
and advanced OpenAI / Anthropic API-key management for a session
conversation and reviewed workspace setup proposals. See [Bots](docs/app/BOTS.md)
for setup, context sharing and limits. A page
finder supports Ctrl/Cmd+K; existing ordered actions and terminal watching remain
on their original bridge. The website prototype remains simulated.

See [the prototype/runtime gap map](docs/app/PROTOTYPE_RUNTIME_MAP.md) for the
field-level support and limits. The prototype's Bots / Nav / Runtime rail and
five navigation groups are present. The workspace switcher scopes workspaces,
goals, lanes and workers; authority and evidence remain runtime-wide.
A native Linux folder chooser registers a Git repository through the host;
the page receives only its reference, and the list updates from runtime frames.
Local conversation history and runtime bot registration are connected. Older-history
paging and autonomous multi-bot execution remain open.

Build with `cargo build --release --offline --manifest-path cockpit/Cargo.toml`.
Run `node tools/cockpit-app-smoke.mjs` for the isolated product-flow check.
Launch the daily desktop with `tools/start-desktop.sh`. It prefers native Wayland
and falls back to X11, overriding an inherited test-runner `GDK_BACKEND` setting.
For deliberate backend troubleshooting, use `SUPER_DESKTOP_BACKEND=x11` or
`SUPER_DESKTOP_BACKEND=wayland`. The mobile observer launcher uses the same entry point.
The isolated `tools/native-ui-test.sh` wrapper still explicitly selects X11 for
WebDriver capture; that test setting should not choose the daily desktop backend.
There is still no installer.

## Local development tools — 2026-09-07

The Nav rail includes Editor, Terminal, and Browser in that order. Choose a local
Git checkout with the native folder picker, browse/edit/save its text files, run a
non-interactive command with live output and a Stop control, and preview a local
HTTP/HTTPS server inside the app. These are human-operated machine tools, separate
from runtime actor grants and evidence. Bot worktree execution and reviewed diffs
remain open. See [usage and boundaries](docs/app/LOCAL_DEVELOPMENT.md).
