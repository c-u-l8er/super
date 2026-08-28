# [&] SUPER — Product Blueprint
**Rev F · 2026-08-20 · supersedes Rev E ("The Agent Super App")**
Synthesizes `and_super_strategy.docx` — the Desktop / Cloud / Runtime strategy — into the working spec. Home: **super.computedriven.com**.

---

**Revision:** W.2.3.3 (stamped from release.json)

## 0 · What changed at Rev F

1. **Name.** The product is **[&] Super**, not "The Agent Super App." *Super* means a super-surface above interchangeable engines and below the user — it must never read as a vague all-purpose AI app. Differentiation is control, placement, evidence, authority, and world-state semantics.
2. **The cloud is load-bearing.** ComputeDriven is the control plane (identity, sync, restore, fleet, hosted execution, billing) — the commercial center, not an add-on.
3. **Three surfaces, one world.** [&] Super (desktop), ComputeDriven Web (control room), T&R (native OS) are projections of the same WRL world — not integrations between separate systems.
4. **Placement is a first-class governed computation.** LOCAL / CLOUD / FLEET are execution sites in one world, and eligibility is derived from capability, cost, and data policy — with a citable derivation.
5. **The epistemic ladder goes everywhere.** `spec → in_tree → live_local → live_deployed → external` becomes a visible property of every claim, gate, and goal.
6. **The roadmap is now Phases 0–9** (superseding Rev A–E; mapping in §9).

---

## 1 · Thesis

[&] Super is the **local-first compute surface for a persistent ComputeDriven world**: the place where work is directed, placed, observed, governed, evidenced, and carried between local machines, ComputeDriven Cloud, and the eventual T&R OS.

Everyone else is converging on "agents that do work" — agent panes, chat, terminal polish. [&] Super does not compete there. Its question is deeper:

> Others answer: *"How do I get agents to do the work?"*
> [&] Super answers: **"What exactly did the work establish, what was it allowed to change, where did it run, and why may the result be committed?"**

The runtime is authoritative; every UI — desktop, web, OS — is a projection that can crash and resynchronize, because it was never the truth. Checks, receipts, and falsifiers outrank model prose. The CLI (`amp`) and the desktop call the same runtime (`ampd`); business logic exists once.

**Architecture shorthand:** *Elixir runs the society. Rust runs the machine. WRL describes the world. TRVM increasingly enforces its laws. ComputeDriven makes that world persistent and distributed.*

---

## 2 · One world, three surfaces

| Surface / layer | Role |
|---|---|
| **[&] Super** | Desktop development & operations cockpit — goals, agents, lanes, claims, obligations, diffs, evidence, fleet placement, runtime state. |
| **ComputeDriven Web/Cloud** | Remote control room — identity, device/node membership, encrypted selective sync, presence, restore, hosted execution, placement scheduling, billing, org controls. |
| **T&R** | Native OS environment where the same world becomes spatial — windows, roads, tracks, machines, agents, dashboards. |
| **WRL** | Serializable, inspectable representation of the shared world and its topology. |
| **TRVM** | Runtime that progressively gives semantic force to transitions, receipts, convergence, authority. |
| **TRAAVIIS** | Evidence/provenance — the externally communicable record of what was established. |
| **RuneFort** | High-density visualization of system state and topology. |

**Naming hierarchy:** `[&] Super` (user-facing surface) · `amp` / `ampd` (CLI + headless daemon) · `ComputeDriven` (commercial platform + control plane) · `T&R` (native OS realization).

---

## 3 · Object model

| Object | Lives under | Notes |
|---|---|---|
| Workspace | `WorkspaceSupervisor` | One goal-world; owns everything below. |
| Goal | `GoalServer` | e.g. `EMISSION_CONFORMANCE-v1`; carries epistemic chips. |
| Lane | `LaneSupervisor → Lane` | Independent attack: agent + worktree + budget + **placement**. |
| Agent identity | `WorkerSupervisor` | Identity ≠ engine. Memory, budget, authority, obligations, heartbeat survive engine death/swap. |
| Engine (harness) | child of identity | claude-code / codex / test-harness — replaceable. |
| Evidence | `EvidenceLedger` | Claims, films, receipts; each stamped with an **epistemic level**. |
| Obligation | `ObligationRegistry` | Gates merges; created by promotions and rulings. |
| Ruling | arbiter session | Settles claims; refusals name themselves. |
| Routine | scheduler | Timed supervised work (nightly-gate-replay, sweeps, sentinels). |
| Authority | capability table | Typed capabilities — `emit(term, family, {budget?})`, never argv. |
| Placement | scheduler + WRL | LOCAL / CLOUD / FLEET; derived, constrained, citable. |
| Node | `Fleet/Presence` | Adopted machines: workstation, mini server, GPU box, ComputeDriven-hosted, roaming. |
| Account | ComputeDriven | Identity, device membership, plan/tier, encrypted sync scope, restore points. |

**Epistemic ladder** (visible on claims, gates, goals): `spec → in_tree → live_local → live_deployed → external`. A claim states where it was earned — never higher.

---
| **Capability Pack** | Installable package: skills, MCP servers/Apps, adapters, hooks, UI, schemas, conformance tests. Installation confers zero authority. |
| **Capability** | A typed action the runtime can authorize (`github.pr.create`, `mail.send`), classed observe → destructive/admin. |
| **Grant** | Scoped authority: identity + capability + resource + duration (once/run/agent/workspace) + policy. |
| **Approval** | A human/runtime gate a class of effects must pass before committing. |


## 4 · App shell

```
┌──────────────────────────────────────────────────────────────────┐
│ topbar   [&] super · workspace ▾ · gates 25/25 · budget · ⌘K     │
├───────────────┬──────────────────────────────────┬───────────────┤
│ rail          │ canvas                           │ inspector     │
│ (the literal  │ (active surface)                 │ (frozen       │
│  supervision  │                                  │  snapshots —  │
│  tree)        │                                  │  entry-       │
│               │                                  │  snapshot@1)  │
├───────────────┴──────────────────────────────────┴───────────────┤
│ journal ▸ total event ticker (nothing happens off the record)    │
└──────────────────────────────────────────────────────────────────┘
```

Lane cards carry **placement chips** (`LOCAL · travis-desktop`, `FLEET · ms02`, `CLOUD · cd-west`). Evidence rows carry **epistemic pills**. Authority is shown *beside* placement so cloud movement never looks implicit.

---

## 5 · Surfaces

**5.1 Mission Control** — the society at a glance. Stats (lanes live, agents, fleet nodes, gates green, cert streak), the goal card with epistemic chips, mini-lanes, obligations due, latest evidence. Job: answer "is the world healthy and what needs me?" in five seconds.

**5.2 Lanes** — parallel attacks on one goal. Columns per lane: heartbeat, agent/engine/placement chips, worktree @ sha, activity line, budget meter, Pause / **Kill harness** / Worktree. Kill → supervisor restarts the engine; identity, worktree, evidence, budget survive. Compare bar diffs lane↔lane; **Promote** creates obligations; merges wait on green gates.

**5.3 Agents** — the roster. Each card: identity, goal, memory size (citable claims), authority count, obligations. Detail view renders the *actual supervision tree* with the Harness line swappable live — claude-code ⇄ codex — proving engine ≠ identity.

**5.4 Fleet & Placement** — machines are floors for supervisors. Node cards (load, resident workers) including ComputeDriven-hosted capacity; "+ Adopt node" (a node is adopted, not configured). Placement panel shows the three sites — LOCAL / FLEET / CLOUD — and the **governed-placement card**: a task spec (`requires: gpu.cuda`, `source_data: denied_remote`, `max_cost`) with its **derived placement** and the reason. Moving a lane is placement, not migration.

**5.5 Editor** — hands on the worktree. File tree, code with **agent gutters** (who touched what), inline claim cards linking regions to the ledger. Epistemic level shown on each claim chip.

**5.6 Evidence** — the ledger. Filter pills (claims / obligations / rulings / films); every row: kind, **epistemic pill**, assertion, emitted-by, citations, § ref. Selecting a row freezes its snapshot into the Inspector. Ladder legend on-screen.

**5.7 Gates** — Replay runs the actual suite and streams output; counts render *from this run* (nothing transcribes a number). Cert stamp with byte-identical streak. Gate grid mirrors verify.sh line for line.

**5.8 Rulings** — open questions wait for the arbiter: confirm `film-budget-negative` vs `film-budget-invalid` (value-fault vs spelling-fault); admit the tenth harness species (stale-literal assertions). Ruling → obligations update → journal line.

**5.9 Routines** — supervised scheduled work: nightly-gate-replay (gpu01), ledger-compaction, stale-literal-sentinel (awaiting ruling), dependency-sweep (cd-west).

**5.10 Authority & Budgets** — the capability table with schemas and Revoke; budget meters; the **refusal log by name** (`film-budget-negative` · fix a value / `film-unknown-flag` · fix a spelling / `authority-revoked` · fix a permission).

**5.11 Settings** — engines (keys live in the Rust body's keychain), sandbox policy, fleet enrollment, journal retention, and the **ComputeDriven account**: plan/tier, encrypted selective sync, restore points, hosted capacity. Local-first: everything but the account works with the cloud off.

---

## 6 · Cross-cutting mechanics

1. **Supervision is visible.** The rail *is* the tree; failure is a lifecycle event with a name, never a mystery.
2. **Engine ≠ identity.** Harnesses are replaceable children; the agent is the supervised identity around them.
3. **Capability-typed actions.** `emit(term, family, {budget?})` — argv is a transport type, not a capability type; diagnostics inexpressible through the authority are refused.
4. **Refusals name themselves.** Every refusal tells you whether to fix a value, a spelling, or a permission.
5. **Snapshot-at-entry.** Decisions cite frozen records (`derivation.entry-snapshot@1`), never live objects.
6. **Total journal.** Nothing happens off the record; the ticker is the tail of the truth.
7. **Epistemic ladder.** Claims/gates/goals wear `spec → in_tree → live_local → live_deployed → external`; the UI makes the hierarchy *more* central than the rough draft did.
8. **Governed placement.** LOCAL/CLOUD/FLEET eligibility is computed from capability, cost, hardware, and data policy — and the derivation is citable (TRVM can later verify or reproduce it).
9. **Local-first, cloud-optional.** Genuinely useful with the cloud off; ComputeDriven adds persistence, sync, restore, fleet, and elastic capacity.

---

- **Install ≠ authorize.** A pack on disk holds no authority; grants are separate, scoped, inspectable objects.
- **Updates cannot silently widen authority.** A version bump that requests new capabilities, egress, or placement is HELD until the diff is reviewed; updating may preserve the old grant set.

## 7 · Architecture

```
[&] SUPER UI ── Tauri 2 · lightweight HTML/TS        (the projection)
ELIXIR / OTP ── goals · agents · lanes · supervisors  (the society)
RUST ────────── PTY · git · fs · hashing · sandbox    (the machine)
SQLITE ──────── durable local ledger → replicated WRL (the memory)
WRL ─────────── topology · intent · capability        (the world)
TRVM ────────── execution · receipts · verification   (the law)
COMPUTEDRIVEN ─ identity · sync · fleet · cloud       (the persistence)
```

`amp` (CLI) and the desktop shell both speak to `ampd`; the Python/HTML rough draft is frozen as the **behavioral oracle** with fixtures and conformance tests.

---

## 8 · Commercial shape

One platform, not a product zoo. Tiers: **Local/Free** ([&] Super, local agents, local WRL world, local receipts, BYO engines) → **Driver** (account, encrypted sync, restore, modest cloud) → **Fleet** (multiple machines, distributed execution, remote runners, richer scheduling) → **Factory** (teams, larger fleets, automation, hosted compute, policy/governance). The differentiated move: users attach machines they already own; ComputeDriven sells coordination, persistence, visibility, and elastic overflow.

---
- Later paid value: private/org capability catalogs, org-wide grant policy, hosted pack verification, encrypted credential vault/sync, cloud-backed connector execution, metered hosted effects.


## 9 · Path (Phases 0–9; supersedes Rev A–E)

| Phase | Build | (was) |
|---|---|---|
| 0 | Freeze reference — tag Python/HTML draft; fixtures, transcripts, conformance tests | Rev A |
| 1 | Desktop shell — Tauri wrap, stable behavior, IPC boundary | Rev B |
| 2 | Elixir runtime — workspace/goal/lane/worker/evidence/obligation/routine/presence supervisors | Rev B |
| 3 | Rust native core — git, worktree, PTY, fs, hashing, process, sandbox authority | Rev B |
| 4 | Local ledger — durable, replayable; actions bound to receipts + explicit authority | Rev C |
| 5 | ComputeDriven account + sync — identity, device membership, encrypted world sync, restore | new |
| 6 | Remote / fleet execution — eligible-node placement across local, owned, hosted | new |
| 7 | WRL authority — topology, capability, placement in WRL, not framework config | Rev C |
| 8 | TRVM integration — execution/verification under TRVM, differential-tested vs OTP | Rev D |
| 9 | T&R — same world rendered natively in the OS; no OS-specific data model | Rev E+ |

---

## 10 · Open questions for the next ruling

1. **Editor own-vs-embed at Phase 1–3:** ship our editor, or embed the existing one and own everything around it?
2. **Sync scope granularity:** which WRL state is selectable for encrypted sync by default — receipts always, worktrees never, memory per-agent?
3. **Where placement policy lives:** WRL records from Phase 6, or config until Phase 7 makes it representable?
4. **Tier boundary for fleet size:** how many adopted nodes before Driver → Fleet?

---

**North star:** *[&] Super is the local-first compute surface for a persistent ComputeDriven world: Elixir supervises its living actors, Rust owns machine authority, WRL describes its topology, and TRVM progressively makes its execution verifiable.*

---
- Pack signing scheme (signature wraps the canonical manifest; no circular self-reference).
- Default approval classes per capability class — where exactly does "remote draft" end and "publish" begin?
- Credential residency defaults per tier (local keychain / adopted node / ComputeDriven vault / org vault).
- Private registry ownership and org catalog governance.


## 11 · Rev F.1 — response to first-pass review

1. **Proof binding (priority zero).** The homepage no longer types a count into markup. `tools/emit-proof.mjs` parses the verifier's own `RESULTS.txt` → `proof/latest.json` (sha256, run id, per-gate figures, totals; cert fields provenance-tagged to `BRIEF.md`). The page fetches the artifact at load (with a build-embedded copy as the `file://` fallback, labeled as such), renders `—` and hides any figure the artifact doesn't establish, and every figure links to its receipt. The pipeline is literally `verify → proof/latest.json → homepage`.
2. **The hero is the app.** The marketing page embeds `app-prototype.html` live in the stage (scaled iframe) — no separate hand-drawn preview to drift. A volumetric beam sweeps through smoke and lights it up; when the light settles, the frame becomes interactive.
3. **Navigation ≠ supervision tree.** The rail now defaults to human groups — WORK (mission, lanes, editor) · SOCIETY (agents, routines) · COMPUTE (fleet & placement) · TRUTH (evidence, gates, rulings) · SYSTEM (authority, settings) — with a **Nav / Runtime** toggle that reveals the literal live supervision tree ("show me what is actually alive").
4. **One mundane world.** The workspace switcher works: `trvm ⇄ pricing-page`. The pricing world is an ordinary Tuesday — research CLOUD, implementation LOCAL, browser-test FLEET, deploy **HELD** on a human-approval obligation — same machinery, zero cosmology.
5. **Release-state honesty.** No "Download" CTA anywhere; the site says Phases 1–2 are in progress, the prototype is what's real today, and the tier grid is labeled *planned shape — nothing is for sale yet*.


---

## 12 · Rev F.2 — truth closure

1. **The prototype stopped lying about itself.** Topbar carries a `SIMULATED RUNTIME` badge; Mission Control now says the production runtime *projects* this surface from supervisors while the prototype *simulates* that projection; the rail footer states where its figures come from. The "mock state" comment became "simulated state (Phase 2: projected from ampd / OTP)."
2. **The prototype's figures are bound, not typed.** It carries its own `#proofEmbed` (injected at build) plus a live `fetch('proof/latest.json')` refresh; the gate grid, topbar badge, mission stats, cert stamp, routines "last run," inline claim evidence, and the boot ticker all derive from the artifact. The gate replay derives every number it prints — totals, cert hash, next streak — from `PROOF`, and the receipt-prose it streams is fenced as `proof:quoted`.
3. **The ordinary Tuesday refuses its own green check.** `deployed commit = tested commit` is now `○ pending · deploy held` on the homepage, matching the prototype.
4. **Stale embeds are a release failure.** `tools/inject-proof.mjs` writes every `#proofEmbed` from `latest.json` and asserts byte-equality; `tools/release.sh` orders the gates: emit → inject → battery → package.
5. **A battery hunts transcribed figures.** `tools/proof-battery.mjs` fails the build when proof-like literals appear outside `#proofEmbed` or `proof:quoted` fences. First run caught six violations (an inline claim card, an evidence row, the routines table, and the boot ticker); all were bound or fenced; the battery now passes clean.
6. **The share preview identifies the product.** `preview/hero-light-preview.png` renders the light *and* an identifiable Super UI — tree rail, goal card with epistemic chips, placement-tagged lanes, receipts — with its figures read from the artifact; wired as `og:image`.

**Ruling adopted from review:** the site architecture is frozen. The next credibility increase is the Tauri/Elixir seam — `WorkspaceSupervisor` stops being simulated state and becomes an actual OTP supervisor whose process state this exact UI projects.

---

## 13 · Capability System (Rev F.3 / C0)

**Verdict adopted:** build the plugin system, but the authority primitive is not "plugin."
**A plugin is something you can install. A capability is something you are allowed to exercise.**
Other plugin systems answer *what can I add?* Super answers *what exactly may this installed thing do, for whom, where, with whose authority, at what cost — and what receipt proves the effect?*

### 13.1 Terminology

UI may say **Plugins**; architecture says **Capability Pack** (the package), **Adapter** (MCP/HTTP/CLI/native reach), **Skill** (procedural knowledge, Agent Skills format preferred), **Capability** (typed action), **Grant** (scoped authority), **Effect**, **Approval**, **Placement**, **Receipt**, **Policy**, **Projection** (returned UI, incl. MCP Apps).

### 13.2 Six inspectable states

available → installed → **requested** → **authorized** → exercised → committed → **receipted**. The separation is the product: a pack can be installed and hold nothing; a grant binds identity + capability + resource + duration; runtime history distinguishes attempted from committed from receipted.

### 13.3 Capability classes → default policy

| Class | Examples | Default |
|---|---|---|
| observe | read file, query issue | grantable by scope; receipt recommended |
| local mutate | patch worktree | allowed in isolated worktree; receipt required |
| remote draft | draft PR/email | allowed when reversible; receipt required |
| remote commit/publish | send, post, open PR, deploy | human approval |
| spend/provision | provision runner, buy credits | budget + approval |
| destructive/admin | delete, merge protected, rotate key | deny; narrow one-shot grants |

Declarations may constrain resource/path scope, egress domains, read/write, approval, duration, max calls, max dollars, eligible nodes/regions, secret refs, cross-boundary data, reversibility, receipt requirement.

### 13.4 Install flow

discover → inspect → verify signature/manifest/conformance → **install (zero authority)** → connect credential out-of-band → review requested capabilities → grant a subset → assign → invoke → approval if required → effect → receipt. Packs stay useful under partial authority; refusals name themselves (`authority-missing · mail.send`, with scope, reason, current grant, and one-tap escalation: once / run / agent / keep denied).

### 13.5 Updates are authority diffs

A version bump that adds capabilities, egress domains, or placement eligibility is **HELD**: the diff shows code-change size beside the authority surface delta; the user may update while preserving the old grant set, leaving new requests ungranted. *Updates can change code. They cannot silently change authority.* This binds supply-chain review to the authority system.

### 13.6 Secrets: gateway, never engine

```
engine → typed invocation → ampd → Capability Gateway
  (policy · placement · budget · approval · secret reference)
    → Rust body → OS keychain/vault → external service
```
The engine sees `github.pr.create(repo=…, …)`; it never sees `Authorization: Bearer …`. Credential residency is selectable (local keychain / adopted node / ComputeDriven vault / org vault) and **intersects placement**: a capability is eligible only where its secret may reside. Placement cannot widen data access.

### 13.7 Receipts

Every meaningful effect emits `capability-effect-receipt@1`: pack@version, capability, actor, workspace, authority-snapshot hash, placement, secret ref (+ `secret_material_exposed_to_engine: false`), approval id, request/result hashes, committed flag, timestamp. No secret material is logged. Receipts feed the existing Evidence surface and epistemic ladder — **no second audit ledger**.

### 13.8 Ecosystem stance

MCP and Agent Skills are consumed, not fought: MCP is adapter/transport (tools become *requested* typed capabilities; MCP Apps render sandboxed), skills are procedural components; **neither implicitly grants authority**. CLIs wrap behind typed adapters (argv is transport, not authority). `super-pack.toml` is a container manifest pointing at skills/MCP/UI/hooks/tests/schemas; TOML first, WRL-authoritative later. Verification shows exactly what was checked (signature, hash, SBOM, conformance, falsifiers, authority surface counts, egress, source) — never a five-star safety score. "ComputeDriven Verified," if introduced, means only that the listed checks were reproduced for that exact version.

### 13.9 Registry & local-first invariant

ComputeDriven is index and trust/control plane (publisher identity, signed versions, verification receipts, org catalogs, optional vault) — never a runtime chokepoint. Local packs install from folder/Git/URL. If the cloud disappears: installed packs, local grants, local secrets, local invocation, and local receipts all keep working; sync waits.

### 13.10 Phases

C0 vocabulary + UI prototype (this revision) · C1 local manifest/registry (SQLite, zero-authority default) · C2 grants + named refusal + snapshot-at-entry · C3 credential gateway (Rust keychain bridge, redaction tests) · C4 MCP + Agent Skills adapters · C5 receipts + approval queue + one-shot grants · C6 ComputeDriven registry/signatures/org catalogs · C7 placement/fleet with secret-residency eligibility and budgets · C8 WRL authority graph · C9 TRVM enforcement/replay of authority + placement transitions.

### 13.11 Non-negotiable invariants

1 installed ≠ authorized · 2 updates cannot silently widen authority · 3 secrets never enter engine transcripts · 4 grants scope identity+capability+resource+duration/policy · 5 placement cannot widen data access · 6 denied capabilities fail before the effect · 7 meaningful effects emit receipts · 8 receipts cite exact pack version + authority snapshot · 9 packs stay useful under partial grants · 10 local execution needs no cloud · 11 MCP/skills are adapters, not authority · 12 trust claims state exactly what was verified · 13 UI is a projection; runtime grants are authoritative · 14 capability receipts feed Evidence — no second ledger · 15 **authorization is not approval** — approval is a separate consumable object bound to the exact request hash; changing the request invalidates the consent · 16 **consent has an identity**: an approval binds grant identity (actor + capability + resource + duration + placement) + the exact effect intent + pack version + authority snapshot, canonicalized and digested with real SHA-256 — an approval matching on digest alone, or carrying a fake hash label, is a forgery the gateway must refuse · 17 **placement is derived, not asserted** — the site an effect runs on is computed from grant eligibility ∩ pack data policy ∩ secret residency, the derivation is cited by the refusal and by the receipt, and consent executes in the context it was granted for, never in ambient state · 18 **a snapshot is a commitment, not a counter** — `authority-snapshot@1` is the canonical SHA-256 of the active grant set, pack versions, and policies; same authority, same bytes; any change, a new hash · 19 **consent binds a proposal, not a capability** — approvals carry an effect-request identity and revision; independent proposals hold independent consent, and only a revision of the *same* proposal stales its prior approval · 20 **restart must never widen authority** — every authority-bearing registry recovers its persisted truth; revoked stays revoked, retired stays retired, consent and receipts survive, and unknown recovery state fails closed.

**C0 shipped in this revision:** homepage nav + `#capabilities` section (install≠authorize copy, prototype-labeled catalog tiles with visible authority counts, interactive held authority-diff); prototype `Capabilities` screen (Installed/Discover/Local, search, GitHub grant matrix with durations, gateway-only secret line, placement constraints, named `authority-missing` escalation, one-shot receipt into Evidence, held 1.5.0 update that preserves old grants); `CapabilityRegistry`/`GrantRegistry` in the runtime tree, labeled `sim`. Everything remains inside the SIMULATED RUNTIME boundary until ampd (C1+).

---

## 14 · Rev F.3 / C0.1 — authority boundary closure

Review of C0 found the prototype violating its own capability law: checkbox clicks mutated the authoritative grant map directly, `Exercise` emitted committed receipts without an authority check, and the post-update `NEW` row could gain authority by selection. All closed:

1. **`requested` vs `granted` are separate objects.** Checkboxes edit the draft (`cap.requested`); nothing authoritative happens on selection, and the journal says so. Named law adopted: **UI selection is not authority.**
2. **`Grant selected` is the only bulk commit boundary** (`commitGrant()`): it copies the draft into the grant set and mints a new authority snapshot; escalation buttons are the only other commit path, and they say what they commit.
3. **Every exercise funnels through `authorize()`.** There is no code path from a button to an effect receipt that bypasses it. Denied/ungranted attempts produce a named refusal, `adapter_call none`, `receipt none` — attempts are not effects.
4. **One-shot grants are consumable objects** (`gr_0193`-style: capability, actor, scope, `uses_remaining`, status). The gateway consumes them atomically; the receipt cites the grant id; a retry is refused.
5. **The 1.5.0 `issue.write` row cannot gain authority by selection** — it joins the draft like everything else and only a commit grants it.
6. **Catalog tabs derive from install state** (`packs[*].installation` → tab), so installing Postgres moves its card; search filters within the active tab instead of overriding it. UI is projection, even in the simulation.
7. **A negative battery enforces all of the above** (`tools/authority-battery.mjs`): it loads the prototype headlessly and fails the release if selection grants, if an ungranted or class-denied exercise produces a receipt, if a consumed one-shot authorizes twice, or if tabs stop deriving from state.

**Release provenance/identity closure (also this revision):** `release.json` is the single revision source — README, blueprint header, homepage footer label, and the package filename are stamped/derived from it (`tools/stamp-rev.mjs`). `tools/verify-artifact.mjs` validates the receipt artifact's completeness before emit (gate replay itself remains upstream in the TRVM repo, and the pipeline says so). The proof battery now **derives** its forbidden literals from `proof/latest.json` instead of a hardcoded list. The social preview is regenerated from the artifact during release when the renderer's deps are present, writes `preview/preview-meta.json`, and `tools/check-preview.mjs` hard-fails the release if the preview's figures diverge from the artifact.

---

## 15 · Rev F.3 / C0.2 — grant & approval semantics closure

Review of C0.1 found that grants were still stored as booleans (`granted[key]=true`), so actor, resource, duration, and placement were shown by the UI but not enforced by `authorize()`; the duration selector was cosmetic; "once" meant two different things in two flows; and — most importantly — granting an approval-class capability silently pre-approved every future effect. All closed:

1. **Grants are authority objects.** `activeGrants` holds `{id, actor, capability, resource, duration, placement, workspace, run, uses_remaining?}`; the three defaults are seeded as objects, not booleans. `authorize()` matches every dimension and, on a near miss, **names the failing one**: `actor-mismatch`, `scope-mismatch`, `placement-denied`, `run-expired`, `workspace-mismatch`, `one-shot-consumed`.
2. **Durations govern.** `once` mints the same consumable object in both flows (matrix commit with duration=once and the escalation button are one mechanism); `run` grants die when the run ends (an "End run" palette action demonstrates it); `workspace` grants refuse from the other workspace; `agent` follows the actor.
3. **Three layers, honestly separated.** `pack.surface` (what a version declares, with `introduced:`), `grantDraft` (what the human is considering), `activeGrants` (what the runtime authorizes). Updating to 1.5.0 expands the **surface** only; draft and active grants are untouched, and the journal says exactly that.
4. **Authorization is not approval.** A grant on `pr.create` is *eligibility*. Each effect computes a request hash; the gateway HOLDS it, creates a pending approval bound to that exact hash, and the Inspector offers approve/deny. Approval is consumed by one effect; the receipt cites `grant · approval · request`. A request modified after approval hashes differently and is held again — stale intent cannot ride old consent.
5. **The battery grew the review's falsifier table** (`tools/authority-battery.mjs`): wrong actor, wrong repo, wrong placement, wrong workspace, expired run, double one-shot, granted-but-unapproved held with zero adapter calls, exact-request approval commits once, modified request refused, surface-expansion leaves draft+grants unchanged, uncommitted selection unauthorized, state-derived tabs. All release gates.
6. **Provenance fields added to the artifact:** `run.replayed_at` and `run.verifier` are parsed from the receipt header; `upstream.repo/commit` are explicitly `null` with a note until the upstream emitter records them — the artifact now distinguishes when the verification ran from when the site regenerated.

The five laws now read: **Identity ≠ engine · Installation ≠ authority · Authority ≠ approval · Attempt ≠ effect · Effect ≠ proof.**

---

## 16 · Rev F.3 / C0.3 — authority identity & consent provenance

C0.2's review reproduced a real bypass: approvals matched on `request_hash` alone, so a granted approval forged for the wrong capability, actor, or grant — but carrying the right hash — authorized. And the "hash" was a 32-bit DJB value wearing a `sha256:` label. Both closed, plus two grant-editor set bugs:

1. **Consent identity.** The gateway now builds a full `approval-intent@1` envelope — pack@version, capability, actor, resource, grant id, authority snapshot, placement, and the request parameters — canonicalizes it (recursive key-sort, so the same intent always yields the same bytes), and digests it with a **real synchronous SHA-256** whose honesty the battery verifies against `node:crypto`. The approval matcher requires the digest **and** every identity field; forged approvals with the right digest and wrong capability/actor/grant/version/snapshot/placement refuse.
2. **Named staleness.** When state drifts under a granted approval — pack version bumped, snapshot changed, placement moved, any request parameter edited — the approval is marked `STALE` and the journal names the field that changed since consent. Stale consent cannot ride, and the user is told *why*.
3. **The grant editor reconciles the whole domain.** Committing a draft diffs desired authority against **every** active grant in the identity domain: unchecking revokes all of them (two grants, both die), changing the duration revokes the old identity and mints the new one (`workspace → run` replaces, never accumulates), and re-committing the same desired grant is a no-op. "Capability selected" was never the whole desired grant — the desired grant is the full identity, and the editor now behaves that way.
4. **Empty intent refuses.** Approval-class effects with no request refuse as `request-missing` — nothing ever hashes `{}`.
5. **The battery implements the review's C0.3 table** — 32 assertions now: every forged-approval variant, real-SHA-256 verification, canonical-form key-order independence, parameter-edit staleness, whole-domain revocation, duration replacement, idempotent commits — all release gates.

**Ruling adopted:** the JavaScript authority simulator freezes here. It has become what it needed to be — an executable specification. C1 implements `CapabilityRegistry → GrantRegistry → ApprovalSupervisor → CapabilityGateway` in ampd (Elixir/OTP), and the C0–C0.3 batteries become the conformance vectors the real runtime must satisfy.

---

## 17 · Rev F.3 / C0.4 — placement derivation & consent execution (simulator freeze)

The last blocking review before C1 found placement was the one pillar still grant-shaped but not policy-true — `ctx.placement` was a hardcoded string, cloud denial came from a grant array literal rather than a derivation, and nothing was citable. Plus three integrity gaps. All closed:

1. **Placement is a derivation.** `derivePlacement(pack, grant, ctx)` walks the sites through grant eligibility ∩ pack data policy (`source_data: private` excludes hosted cloud) ∩ secret residency (`github.oauth: local·fleet`), returns the chosen site **with its citations**, and names the governing constraint when it refuses — `placement-denied · cloud — data-policy: source_data private — hosted cloud excluded`. Receipts carry the derivation; the approval envelope binds the **derived** site. The homepage's placement card and the runtime finally agree.
2. **Consent executes in its held context.** A pending approval stores the context it was held under; approving executes there — flip the ambient workspace between hold and approve and the effect still commits, because consent was given to *that* request in *that* context. When the underlying grant genuinely dies before approval (run ended), the failure is **surfaced**: the approval goes STALE with a named reason in the Inspector, the journal, and a toast — never a silent no-op.
3. **`authorize()` is pack-generic.** Browser and Postgres declare real surfaces with versions and policies; any `pack.capability` resolves through the same gateway; unknown packs refuse as `capability-undeclared`; Postgres `query.write` demonstrates `denied-by-default` by class.
4. **Run identities retire.** Ended run ids enter a retired set forever; a forged context carrying an old run id refuses even if it matches a grant's stamp.
5. **Receipts are durable model objects** (`receiptsLog`), not just DOM rows — each cites capability, pack@version, grant, approval, intent digest, the placement derivation, and the authority snapshot. The Evidence table renders them; it never *is* them.
6. **The battery grew to 42 assertions**, adding: default derivation cites its constraints, cloud refusal names the policy, receipts cite the derivation, held-context consent commits across a workspace flip, dead-grant approvals surface as stale, retired run ids refuse when forged, cross-pack authorization, unknown-pack refusal, and class-default denial.

**The simulator is hereby FROZEN.** Grants, approvals, placement, refusals, receipts, and provenance are all doctrine-true and falsifier-protected. C1 implements the same four subsystems in ampd (Elixir/OTP); these batteries are its conformance suite.

---

## 18 · Rev F.3 / C1 — ampd: the authority runtime is real

The freeze held: nothing in the simulator's semantics changed. Instead, the semantics got a second implementation — on the BEAM — and a contract binding the two.

**What runs.** `ampd/` is an OTP application: `Session` (workspace · current run · retired runs), `CapabilityRegistry` (packs, versions, surfaces, policies), `GrantRegistry` (grant objects + draft + authority snapshot), `Approvals` (consent bound to intent digests), `Receipts` (the effect ledger) — five supervised processes under `one_for_one` — plus `Ampd.Gateway`, the one door, and `Ampd.Core`, the pure parity layer (canonicalization, SHA-256 intent digests, placement derivation, the exact refusal strings).

**The contract.** `tools/export-vectors.mjs` extracts 25 language-neutral conformance vectors from the frozen simulator and *executes each against the frozen engine before exporting* — a vector the simulator disagrees with kills the export. The same generator writes `conformance/authority-vectors.json` and `ampd/test/fixtures/vectors.exs` from one source. `mix test` replays them on the BEAM: **25 tests, 0 failures**, covering install-grants-nothing, actor/scope/workspace/run refusals by name, retired-run forgery, one-shot consumption, denied-by-default, undeclared packs, empty-intent refusal, held-without-receipt, exact-intent commit, consumed-approval re-hold, four forged-approval fields, parameter staleness, placement derivation with citations, the cloud data-policy refusal, consent-in-held-context, dead-grant staleness surfaced, surface expansion granting nothing — and one vector asserting **byte-exact SHA-256 intent-digest parity** between JavaScript and Elixir canonicalization.

**Honesty ledger.** C1 contains no adapters, no secret store, no network effects, and no UI socket; the prototype still says SIMULATED because it still is. C1.1 is the projection seam — the frozen UI subscribing to these processes and flipping to live-local. The accepted rulings on the compute fabric (Fabric under COMPUTE; Tailscale as the first FabricProvider via the local daemon API; capability-derived network envelopes; join approvals through the same approval registry) are direction, not code: nothing here pretends to network.

---

## 19 · Rev F.3 / C1.0a — crash truth & authority commitment

The first OTP round exposed exactly what it should have: parity is not correctness. Three semantic gaps survived from the simulator, and OTP's own restart machinery could resurrect authority. All closed, in both runtimes, under one corpus:

1. **The authority snapshot is content-addressed now.** `authority-snapshot@1` canonicalizes the active grant set (sorted, normalized), pack versions, and policies, and takes a real SHA-256 — in the browser engine and in `Ampd.Core.snapshot_of/2` alike. Minting a one-shot changes it; revoking restores nothing stale; insertion order is irrelevant; ambient workspace is context, not authority, and deliberately stays out of the commitment (so consent held in one workspace still executes there after the ambient world flips). A conformance vector carries a JS-computed snapshot hex that Elixir must reproduce byte-for-byte — cross-language commitment parity, proven.
2. **Proposals have identity.** Approval intents carry `request_id` + `request_revision`. Independent effects hold independent consent — requesting PR B no longer stales the approval for PR A — and only a *revision of the same proposal* stales its prior consent, named as such. The random snapshot marker is gone from both engines.
3. **Ambient placement no longer hardcodes `local`** — context carries no site; the derivation supplies it.
4. **One canonical corpus drives both runtimes.** The exporter validates every vector against the frozen engine on every release (it *is* the JS corpus runner), and `mix test` replays the same fixtures on the BEAM: **32 conformance vectors**, now including proposal coexistence, revision staleness, snapshot commitment (format, change-on-mint, idempotent-commit byte-identity), whole-domain revocation, duration replacement, and both cross-language parity digests. The JS battery retains a handful of browser-projection assertions (tabs, DOM receipts, draft rendering) that are UI-only by nature.
5. **Crash truth.** Every registry writes through `Ampd.Store` (DETS on disk) and recovers its persisted state — the *durable* effect ledger is finally telling the truth. Four crash falsifiers run in `mix test`: revoke → kill GrantRegistry → restart → **still refuses**; end a run → kill Session → **run-b51 stays retired, identity does not regress**; commit a receipt → kill Receipts → **the receipt survives**; hold consent → kill Approvals → **exactly the same pending exists, and still executes on approval**. Supervisor restart intensity is raised so deliberate kills are a test instrument, not an outage. **36 tests, 0 failures.**

**Still open, on purpose:** the gateway's reads and consumptions span processes, so a TOCTOU window exists between authorization and effect — harmless with no adapters, load-bearing the moment one exists. The accepted design is the EffectSupervisor CLAIMED → COMMITTED/FAILED/UNKNOWN machine anchored in the store; that is C1.1's first job, alongside the projection socket. DETS is durable to disk, not replicated — an honest single-node truth.

---

## 20 · Rev F.3 / C1.0b — bootstrap truth & effect atomicity

C1.0a's review found the runtime contradicting its own first law at the one moment it is least defensible: startup. Three defects, all **reproduced on the BEAM before being fixed** — this box has Elixir 1.19.4 / OTP 28, so each was a failing probe first and a passing falsifier after, not a reading of the source.

1. **Installation confers zero authority — and now so does boot.** `GrantRegistry.initial/0` minted `github.repo.read`, `github.issue.read`, and `github.pr.draft`, so a fresh `ampd` booted holding authority nobody granted. Production boot is now `Ampd.Bootstrap.new_world!/0` and mints nothing; the C0 conformance world moved to `Ampd.TestFixture.seed_demo!/0`. `Ampd.reset/0` gives you the empty world, `Ampd.reset_demo/0` the fixture, and only the second one is allowed to create a grant.

2. **Data loss can no longer widen authority.** `Store.load/2` read "no `:state` record" as "initialize defaults", so deleting `grant_registry.dets` re-minted those three grants — *including one that had been explicitly revoked*. The measured before/after was `authority-missing` → `allow=true`. Now `world-meta@1` (installation id, schema version, initialized-at, store generation) is written **after** every store is seeded, so a manifest on disk proves the stores were real. Manifest present + authority store absent ⇒ the registry is **sealed**: it serves no authority, refuses to be written, and the gateway turns the seal into `RECOVERY-STATE-MISSING · …` at the one door.

   New law: **Bootstrap may create authority state only through an explicit initialization transition. Recovery may never infer authority from defaults.**

3. **A fourth defect the review did not reach — DETS repairs itself.** `:dets.open_file` defaults to `repair: true` and will silently rewrite a table damaged by an unclean shutdown, dropping what it cannot parse. For an authority store that is indistinguishable from a partial revocation nobody ordered, and it is exactly the "unknown recovery state" the module claimed to fail closed on. Stores now open `repair: false`; damage seals as `RECOVERY-STATE-UNTRUSTED`.

4. **A receipt attests to the authority that authorized it.** `emit_receipt` re-sampled `snapshot()` *after* `authorize()` had consumed the one-shot, so the receipt cited a world that had never authorized the effect. On the approval path it was worse: consent was bound to `645c…` while the receipt cited `9d7a…`, breaking the evidence chain at its most load-bearing joint. Receipts now carry `authority_snapshot_at_entry` **and** `authority_snapshot_after`, so a one-shot tells its own story — X authorized this, the effect spent its use, Y is what remains. Fixed in **both** runtimes (it was a shared semantic bug, not a port error) and pinned by three vectors.

5. **The TOCTOU window is closed by ordering, not by a database.** `Ampd.Effects` is the durable journal — `effect-request@1` / `effect-attempt@1` — running PROPOSED → AUTHORIZED → APPROVED → CLAIMED → ATTEMPTED → COMMITTED/FAILED/UNKNOWN → RECONCILE. Two properties do the work, and neither is a storage feature: the **claim is a single serialized call**, so two racing exercises cannot both hold one proposal; and the **journal is written before the world is touched** — CLAIMED durable before consent is consumed, ATTEMPTED durable before an adapter would be called. Anything in flight at restart recovers as UNKNOWN and is queued rather than guessed, and an UNKNOWN effect **cannot be re-claimed** — its adapter may already have changed the world, which is the double-effect this machine exists to prevent.

   The idempotency key is the intent digest Super already computes. That is the whole reason UNKNOWN is recoverable: exactly-once does not survive a process boundary, so what crosses it must be a key the far side agrees to deduplicate.

6. **Counts are derived now.** `ampd/README.md` and the root README still said "25 vectors / 25 tests" two revisions after the corpus reached 32. `tools/stamp-counts.mjs` writes both figures from the exported corpus and the suites themselves, and **fails the release** if a bare count appears outside its markers — the same treatment the proof battery already gave the homepage, applied to the file that drifted.

**Measured, not asserted:** 35 conformance vectors, replayed on the BEAM at 51, 0 failures, order-independent across seven seeds; the browser battery at 55 assertions. Breakdown: 35 conformance vectors + 4 crash + 5 bootstrap + 7 effect.

**Two bugs this pass found in its own new code**, both worth recording because they are the same class: `:dets` counts openers *per process*, so a handle retained by the application master — and another dropped by `Store.boot` when it sealed — pinned tables open on inodes that were later unlinked, after which every "write" landed in a file with no name and the store silently vanished. A registry now closes its own table, seeding releases its handle immediately, and sealing releases the handle it took. The manifest test caught the second one only because the suite runs under random seeds.

**Still open, on purpose:** no adapters, no secret store, no network, no UI socket — the adapter slot in `perform/5` takes a function whose default does nothing, and that is the only simulated part of the effect path. DETS remains single-node; its 2 GB ceiling and per-table recovery are the two facts that will force SQLite before real connectors ship, and the transition semantics are now pinned by vectors so the port cannot lose them. **The order stays: C1.1 — the real UI projection, SIMULATED → LIVE LOCAL — before Tailscale, before anything else.** The projection must speak typed commands (`request_grant`, `revoke_grant`, `approve_effect`, `deny_effect`) that re-enter this boundary; a socket exposing `GrantRegistry.mark/2` would be a bypass around everything above, and `approve_effect` in particular needs a local peer identity before "live local" is allowed to mean "trusted local".

---

## 21 · Rev F.3 / C1.0b.1 — authority linearization

C1.0b's review accepted the round, upheld the sealed-registry design and the SQLite deferral, and **narrowed one claim that was too broad.** C1.0b said the TOCTOU window was closed by ordering. It was not, quite:

1. **`Effects.claim/1` serialized effects against effects — nothing serialized an effect against a *grant mutation*.** This interleaving was reachable: decide under grant G → another process revokes G *and returns* → propose → claim → consume → adapter runs. An effect could execute using an authorization sampled before a revocation that had already completed.

   Closed by `Ampd.AuthorityCoordinator`: every authority-changing command and every effect claim passes through one process, giving them a total order. `Ampd.Authority` is now the public linearized API; the registry functions are primitives the coordinator calls once it holds the order, and the conformance runner drives the linearized API so the vectors exercise the real path.

   The law: **CLAIM is the authority boundary.** Before it, revocation wins — `perform` re-decides *inside* the order, so a stale verdict cannot ride. After it, the effect holds an authority lease for its frozen snapshot, and a later revocation does not retroactively cancel an effect that may already have touched the world. The adapter deliberately runs **outside** the lock: holding authority across a remote call would make every revocation wait on a stranger's TCP timeout, and the lease is what makes that safe.

   **The falsifier that earns this:** 24 concurrent exercises against a single one-shot use. Without the coordinator, several decide "allow" before any consumes, and authority is double-spent — verified by stubbing `transact/2` out and watching the test go red. Two neighbouring tests pass with or without the coordinator; they are labelled in the file as invariant checks rather than falsifiers, because a test that cannot fail is not evidence.

2. **Effect identity is not consent identity.** C1.0b used the approval digest as the external idempotency key. That is wrong in exactly the case the key exists for: reconcile an UNKNOWN effect after an unrelated grant change, and the far side is handed a *different* key for the same desired effect — deduplicating against nothing. Split:

   - `effect-intent@1` → **`effect_key`** — capability, resource, request id/revision, params. What should happen. Carries no actor, grant, snapshot, or placement, and is asserted to carry none.
   - `approval-intent@1` → **`approval_digest`** — embeds `effect_key` plus actor, grant, authority snapshot, placement, pack version. Why this actor may make it happen now.

   The receipt carries both. Vectors pin that the effect key survives an authority change and the approval digest does not, in both runtimes, with cross-language parity on a fixed envelope.

3. **A fourth recovery state: the orphaned world.** A manifest that is *absent* beside authority stores that are *present* looks exactly like a first boot and is not one — it is either an interrupted initialization or a world whose manifest was lost, and those are indistinguishable. Seeding over it would destroy the evidence and replace it with defaults: the same widening the manifest exists to prevent, arriving from the other direction. The truth table is now explicit, and `ORPHANED-WORLD` seals rather than seeds.

4. **Sealed registries stopped projecting fabricated defaults.** A sealed `CapabilityRegistry` was serving the built-in GitHub/Browser/Postgres surfaces — pack policies that are not installed, including the `source_data: private` that decides placement. Not an authorization bypass (the gateway seals first), but sealed state should not invent content. Each registry now has a `sealed_state/0` that is neutral and empty.

5. **`store_generation` became world lineage.** Renamed `generation` (manifest `schema_version` 2). It advances only when durable truth is wholesale replaced — restore, factory re-initialization, import — never for ordinary writes, and a semantics-preserving migration moves `schema_version` instead. Restoring a generation-3 snapshot into a generation-7 world yields **generation 8** carrying `restored_from`, so a stale client can never read a rollback as continuity.

6. **The BEAM replay is a mandatory gate.** `tools/release.sh` printed "every gate green" on a box without Elixir while skipping half the conformance claim. It now **refuses** with a named reason and exits non-zero; `tools/preview-release.sh` is the honest degraded path, cannot package, and states plainly that the Elixir half is unverified.

**Measured:** 39 conformance vectors, replayed on the BEAM at 72, 0 failures across six seeds; the browser battery at 60 assertions. Breakdown: 39 conformance vectors + 4 crash + 5 bootstrap + 7 effect + 8 linearization + 9 world.

**Deferred by ruling, not oversight:** SQLite lands after C1.1 and **before any real side-effecting adapter** — DETS is sufficient while nothing external is touched, and the transition semantics are pinned by vectors so the port cannot lose them. Per-adapter reconciliation contracts (`native_idempotency` · `queryable` · `preallocated_id` · `manual` · `unsupported`) are accepted as the shape of RECONCILE but not built; there is no adapter to declare one. Splitting `PackArtifactRegistry` (reconstructable from a signed content-addressed artifact) from `InstalledCapabilityContract` (authority-bearing) is accepted as the right long-term shape, and until it exists the whole capability registry seals.

**C1.1's gate, unchanged and now the largest open risk:** human consent needs a trustworthy local origin before the badge may say LIVE LOCAL. Same-UID processes — agents, Claude Code, Codex, plugins, shells — can all reach a generic local socket, so `approve_effect` must not share a channel with `get_state`. The accepted design is a private inherited channel from the Tauri Rust host that never exists as a discoverable filesystem endpoint, with general agent traffic on a separate endpoint, and **no persistent human token in `world.json`**, since any same-user process could read it.

---

## 22 · Rev F.3 / C1.1.0 — projection boundary correctness

C1.0b.1 was accepted with a ruling: **enter C1.1, but close the interface-level invariants before the badge changes.** The review also found a bypass in C1.1.0's own predecessor, and it was real — reproduced before it was fixed.

1. **`decide/4` was never read-only.** Its docstring said "consumes nothing", and for approval-class capabilities it opened a pending approval and marked prior consent stale. So a bare `decide` **mutated approval state outside the total order** — measured: one pending approval created, `AuthorityCoordinator.ops()` unchanged; and a granted approval driven to `stale` with an ops delta of zero. That directly contradicted C1.0b.1's claim that approval mutations are ordered.

   Split three ways, as ruled:

   - **`preflight/4`** → `preflight@1`, advisory, **creates nothing and stales nothing**. A UI renders "eligible now · approval required", never "authorized".
   - **`request_effect`** → the ordered mutation that may open a proposal.
   - **`perform/5`** → re-checks and claims; the authority boundary is unchanged.

   `decide/4` is `@doc false` and refuses outright when called from outside the coordinator.

2. **The coordinator boundary is mechanical now, not documentary.** A GenServer receives its caller, so an authority-bearing mutation is served only when that caller *is* the `AuthorityCoordinator` — anything else gets `unordered-authority-mutation` and the state is untouched. `CapabilityRegistry`'s `install`/`update` moved from `handle_cast` to `handle_call` for this reason alone: **a cast carries no caller, so a mutation that cannot be attributed cannot be ordered**, and pack policy is authority because `source_data` and secret residency decide where an effect may run.

   One consequence worth recording: a sealed registry now **refuses by name instead of raising**. The mutation arrives from the coordinator, so a raise would kill the total order along with the registry — one lost store would have become a node-wide outage.

3. **A fifth recovery state: `WORLD-META-UNTRUSTED`.** `World.read/0` accepted any parseable non-empty map, so `{"foo":"bar"}` counted as an initialized world. **Presence is not validity.** `schema`, `schema_version`, `installation_id`, `initialized_at`, and `generation` are now validated by shape; an invalid manifest seals, is never overwritten (it might be a real world's), and the refusal names which fields are wrong.

4. **Two channels, one refusal, two projections.** Every local process runs as the same OS user, so "same UID" proves nothing and the split has to be structural: an agent may *ask* for anything — `request_effect` opens a proposal and parks it on consent — and may never *give* consent. `refusal@1` carries `code · component · retryable · requires_human · public_message · correlation_id` for the general channel and `operator_detail` only for human control. The agent learns *what to do*; it never reads which store is gone or which world this is.

   **The transport is C1.1 proper, and `Ampd.Control` says so in its own moduledoc:** until the private inherited channel from the Tauri host exists, `origin` is supplied by the caller and is **not yet a trust boundary** — it is the place the trust boundary goes.

5. **`approve_last/0` is demoted to a conformance helper.** With two effects in flight, "approve whatever is last" is the wrong identity semantics. `Ampd.Control.approve_effect(request_id, approval_id)` requires both identities and refuses `approval-identity-mismatch` when they disagree — a failure `approve_last/0` could not even express.

**Measured:** 39 conformance vectors, replayed on the BEAM at 87, 0 failures across seven seeds; the browser battery at 60 assertions. Breakdown: 39 conformance vectors + 5 bootstrap + 9 control + 4 crash + 7 effect + 12 linearization + 11 world.

**Accepted and still deferred:** SQLite after the projection and **before any real side-effecting adapter**; the five reconciliation classes (`native_idempotency` · `queryable` · `preallocated_identity` · `manual` · `unsupported`) as a mandatory declaration for every future adapter, unbuilt because there is no adapter to declare one; the `PackArtifactRegistry` / `InstalledCapabilityContract` split. Also accepted and unbuilt: the **execution lease** — a deadline after ATTEMPTED that resolves to UNKNOWN (never FAILED, because a timeout says *we stopped knowing*, not *it did not happen*), with a late adapter return becoming reconciliation evidence rather than silently rewriting UNKNOWN → COMMITTED, and `ABORTED_BEFORE_ATTEMPT` for the case where the journal proves the world was never touched.

**What is left before the badge may change:** the transport. Everything above is the boundary the transport attaches to.

---

## 23 · Rev F.4 / C1.1.1 — identity and projection

C1.1.0 was accepted with a direction rather than a feature list: **make identity and projection
trustworthy before networking anything.** Two laws came out of it, and both are now enforced.

1. **Connection determines actor; payload never does.** The grant algebra is keyed on
   `ctx["actor"]`, so while the actor travelled inside the command a caller-supplied actor *was*
   a caller-supplied authority. `Ampd.Peer` binds a channel to an identity when the channel is
   created; `request_effect(capability, resource, request)` has no `ctx` argument to assert one
   in. Workspace and run come from the session the runtime holds; the only thing a caller
   contributes is a placement *preference*, which can only narrow.

   `claim_control_channel/0` succeeds **once**, so an engine starting after the host cannot
   become the person by calling the same function. Bindings are not durable: one that survived a
   restart would be a connection that outlived its socket.

   Why not `SO_PEERCRED`: its `pid` wraps, so a `pid → agent` table is racy by construction.
   `SO_PEERPIDFD` (Linux 6.5) closes that race and still cannot say *what* a process is. Flatpak,
   the Wayland compositors, and D-Bus all converged on the same answer instead — a per-client
   socket with the identity already attached, and no other way in.

2. **Grant request ≠ human grant draft.** An agent's `request_grant` wrote into the same draft
   the human's editor works on, so "Kestrel asked" and "the person chose" were one checkbox.
   `grant-request@1` is its own pending object carrying the asking actor; only a human-control
   action turns one into a grant.

3. **Three projections, not one.** `operator-projection@1` (the control room), `agent-projection@1`
   (one actor's own world), `runtime-status@1` (health, for a caller with no identity). The agent
   projection deliberately omits `authority_snapshot`: it is a digest over every grant on the
   machine, so watching it change is a side channel onto authority the caller cannot see.

4. **Consent binds to world lineage.** `approval-intent@1` carries `world_installation_id` and
   `world_generation`; `effect-intent@1` carries neither, because the external world deduplicates
   on it and an effect that survived a recovery is the same effect. A trusted recovery advances
   the generation and stales prior consent — the mark is the *explanation*, the lineage inside the
   digest is the *enforcement*, and the falsifier sabotages the mark to prove the second.

5. **Valid shape is not understood semantics.** `schema_version == CURRENT` is valid; below is
   `WORLD-META-MIGRATION-REQUIRED`, above is `WORLD-META-UNSUPPORTED`, and both seal. **Version is
   read before shape** — shape is versioned, so a v1 manifest checked shape-first reports as
   corrupt and sends an operator hunting for damage that is not there.

6. **Two live defects, both found by running the thing rather than reading it.** `world-meta-untrusted`
   was an unreachable refusal code — the seal-code mapping tested `contains?(reason, "UNTRUSTED")`
   first, so an invalid manifest reported itself as a damaged store. And `Effects.recover!/0` runs
   from `Application.start/2` without the seal guard the ordered mutations got, so **a sealed world
   could not boot at all**: the raise killed the supervisor, which killed the application, and the
   named refusal the seal exists to produce never got the chance to be produced.

7. **The conformance interface is quarantined.** `authorize/4`, `exercise/1`, `approve_last/0`, and
   `forge_pr_create/1` moved to `Ampd.Conformance`, unreachable from any channel. Four test-shaped
   functions beside three product ones were a second runtime API waiting for someone in a hurry.
   `recover_world` → `recovery_status`, not aliased; `inspect_refusal` implemented against a
   bounded ring, open to both channels so the dual projection is checkable from the other direction.

**Measured:** 39 conformance vectors, replayed on the BEAM at 110, 0 failures across seven seeds and seed 0; the browser battery at 60 assertions. Breakdown: 39 conformance vectors + 10 identity + 12 linearization + 13 control + 14 world + 4 crash + 5 lineage + 6 bootstrap + 7 effect.

**Also measured: `tools/sabotage.sh` — 9 falsified · 0 not.** Each probe stubs out one fix and
asserts the test goes red. A test that passes with its fix disabled is an invariant check, not a
falsifier.

**What is left before the badge may change:** still the transport, and now only the transport. Of
the ten acceptance criteria, the eight about semantics are falsified; the two remaining —
projection updates without reload, and reconnect truth — are *about* the socket rather than about
anything the socket carries.

---

## 24 · Rev F.5 / C1.1.2 — the transport's acceptance battery, built before the transport

C1.1.1 was accepted with a direction and a warning: **build the real transport, but close the
exact-grant identity, duration validation, transition-result truth, and hostile-input boundary
on the way in.** None of those needs a socket to close, and each was a live authority defect, so
they are closed here and the battery is green before the socket is written rather than after.

Five were reported from reading the source. Each was reproduced on the BEAM before it was
touched; four reproduced as described, and the fifth reproduced as something worse.

1. **A singular action names a singular object.** `revoke_grant` took a *capability* and revoked
   every active grant naming it, for every actor. With Kestrel and Mallory both holding
   `github.repo.read`, an operator revoking the row in front of them took the other one too —
   the identity mistake `approve_last/0` made, surviving in the revoke path. It takes a grant id
   now; bulk is `revoke_capability_domain`, which refuses an unbounded scope and refuses a count
   that no longer matches what the operator was shown.

2. **Duration is a closed enum.** `duration_ok` ended in `_ -> true`, so *any* string satisfied
   every scope check there is: a grant minted `"forever"` outlived its run, survived a workspace
   change, and never spent a use — measured. `once · run · agent · workspace`, and `agent` was
   already the intended fourth member; the frozen simulator's own comment said so. Unknown
   durations refuse `invalid-grant-duration` at mint, at the draft, and at the scope check.

3. **Approval may narrow a request, never widen it.** An agent asking for `once` could be
   resolved as `workspace`. A broader grant is one the person authors, not a side effect of
   clicking approve on something narrower.

4. **Installation confers zero authority — and so does discovery.** This is the one that
   reproduced as something worse than reported. The concern was that a grant for an undeclared
   capability lies dormant until its pack installs, at which point installation activates
   authority. True — but `postgres` ships at `installation: "available"` **already declaring its
   whole surface**, because that is what makes it browsable, and *nothing in either engine's
   authorize path ever read `installation`*. So the install was never needed: a grant against a
   merely discovered pack authorized immediately. The oldest law in the system was running
   backwards. Closed at both ends — such a grant cannot be minted, and one that arrives another
   way (an older store, a restored world) refuses `pack-not-installed` at the gateway.

5. **The response reports the transition, not the command.** `revoke_grant` answered `"revoked"`
   into a sealed registry, `request_grant` handed back a `grant_request` that was really a
   refusal tuple, and `approve_grant_request` crashed indexing one. C1.1.0 spent a round keeping
   a sealed registry *alive* so it could return a named refusal; three callers upstairs never
   looked at it. Every mutating dispatch goes through one `settled/2` now.

6. **Redaction moved out of the object and into the projection.** `public_code` was written at
   each call site, so one caller forgetting it silently widened disclosure and no test naming the
   visible code could catch it. There is one code, the true one, and
   `Ampd.Refusal.agent_code/1` is the entire policy — with a test that enumerates every canonical
   code and asserts exactly one is hidden.

7. **The decoder is security code.** `Ampd.Wire` decodes totally over arbitrary input: a fixed
   string→atom mapping built from the command tables themselves (**never `String.to_atom/1`** —
   the atom table has a hard ceiling and is never collected, so an interning decoder is a denial
   of service that outlives the connection), argument count, size and depth limits, and
   `invalid-command-arguments` where there used to be a `FunctionClauseError`.

**Measured:** <!--vectors-->42<!--/vectors--> conformance vectors, replayed on the BEAM at <!--tests-->220<!--/tests-->, 0 failures across seven seeds and seed 0; the browser battery at <!--assertions-->188<!--/assertions--> assertions. Breakdown: <!--breakdown-->42 conformance vectors + 10 identity + 10 incarnation + 12 command_spec + 12 linearization + 13 control + 14 world + 19 boundary + 20 cockpit + 27 transport + 4 crash + 5 lineage + 5 native_fd + 6 bootstrap + 6 multiplicity + 7 effect + 8 lifecycle<!--/breakdown-->.

The corpus grew for the first time in three rounds, and for a reason: the discovery hole was a
defect in the **frozen simulator too**, so it was fixed in both engines and three vectors now
hold the line in the language-neutral corpus rather than only on the BEAM.

**Also measured: `tools/sabotage.sh` — 18 falsified · 0 not.** One further check is deliberately
*excluded* and says so in both the script and the test: the `Peer` epoch cannot be falsified
today, because a crashed peer table comes back empty and the handle fails to resolve with or
without it. It is insurance against a persistence path that does not exist yet. Counting it
would be claiming evidence this round does not have.

**What is left before the badge may change:** the socket, and the privileged bridge that alone
may call `Ampd.Peer.attach_agent/2`.
