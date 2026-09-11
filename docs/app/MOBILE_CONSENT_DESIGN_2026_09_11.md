# How a phone would fit Super's consent model — 2026-09-11

**Status: design. No write path is enabled by this document and none is built.**
It records what the runtime already does, where a phone would attach, and what
must pass before any of it is switched on.

## 1. What the consent model already is

Read from source, not inferred. Four things matter and all four already exist.

### 1.1 Consent is bound to a digest, and the digest is already the right one

`Ampd.Gateway.decide/4` builds an `approval-intent@1` envelope and hashes it:

```elixir
env = %{"schema" => "approval-intent@1",
        "effect_key" => ek,                     # what should happen
        "pack" => pack <> "@" <> pk["version"], # which pack, which version
        "capability" => cap, "actor" => ctx["actor"], "resource" => resource,
        "grant" => g["id"], "authority_snapshot" => snapshot,
        "placement" => pl["site"],
        "world_installation_id" => lin["installation_id"],
        "world_generation" => lin["generation"],
        "request_id" => er, "request_revision" => rev,
        "request" => request["params"]}

h = Core.intent_digest(env)          # "sha256:" <> sha256_hex(canon(env))
```

Every element of *“bind consent to the exact action, arguments, requesting agent,
and version reviewed”* is already inside `h`:

| asked for | field in the envelope |
|---|---|
| exact action | `capability`, `effect_key` |
| arguments | `request` (the params), `resource` |
| requesting agent | `actor` |
| version reviewed | `request_revision`, `pack@version` |
| the authority it was judged under | `authority_snapshot`, `grant` |
| the world it was judged in | `world_installation_id`, `world_generation` |

**So the binding is not something to invent.** A phone consent is bound correctly
exactly when it names `request_hash` and the host re-derives the same `h` at the
moment of decision. `Core.intent_digest/1` is canonical-JSON over the whole
envelope, so any change to any field produces a different `h`.

### 1.2 Revision already invalidates prior consent

When a proposal is revised, `decide/4` finds granted approvals with the same
grant, capability and request id but a **different** `request_hash`, and marks
each `stale` with *“proposal revised since consent.”* Nothing about a phone
changes this; a phone must simply not be able to escape it.

### 1.3 A world-lineage advance already expires consent

`Authority.stale_prior_consent/2` marks every `pending` or `granted` approval
`stale` when `world_generation` or `world_installation_id` moves, with the reason
*“the authority state this consent was given under can no longer be re-derived.”*
The lineage is **inside the digest too**, so this falls out of the exact match
rather than being a second rule that could be forgotten.

### 1.4 The decision command is `:human_control`, and that is the real obstacle

```elixir
"approve_effect" => %{cmd: :approve_effect, channel: :human_control,
  kind: :mutation,
  fields: [%{name: "request_id",  type: {:id, "er_"}, required: true},
           %{name: "approval_id", type: {:id, "ap_"}, required: true}]}
```

`tools/check-intent-surface.mjs` holds three properties, one of which is **“every
intent is exclusive to the human control channel.”** A phone that issued
`approve_effect` over a second channel would break that gate, and the gate is
right: the point of the channel is that there is exactly one way a person's
decision enters the world.

## 2. Where a phone attaches today, and what is missing

The chain is `phone → Tailscale HTTPS → connector (4320) → gateway (4318) → host`.

| layer | what it checks | strength |
|---|---|---|
| connector | `tailscale-user-login` equals the configured owner, else **403**; Host and Origin must match, else 403 | a real identity, from the tailnet |
| connector | a **closed route map** — three entries, snapshot/pair/logout | additions are explicit |
| gateway | session cookie, HttpOnly, same-site, 8 hours, else **401** | device authentication |
| gateway | one-use pairing code, rate-limited, `0600`, never logged | device enrolment |
| gateway | **405** for every other method and path | no write surface exists |

**What is missing is not authentication. It is authorization at the host.** The
gateway is a Node child with no notion of Super's authority model; a session
cookie is a bearer token that says *a device paired*, and nothing in ampd has
ever been asked whether that device may decide anything. Read-only never needed
it to be.

## 3. The proposal

### 3.1 On-demand detail, never ambient

The ambient snapshot keeps today's narrow field allowlist — `id · status ·
capability · actor · resource · placement`, no `envelope`, no `held_ctx`. It
polls every five seconds and a phone is lost more often than a laptop, so the
arguments of an unconsented effect must not sit in it.

A **detail read** is a separate, explicit request for **one** approval:

```
GET /api/observer/approval/<ap_id>      →  connector route map (a 4th entry)
GET /api/approval/<ap_id>               →  gateway
```

It returns the narrowed record **plus** the rendered intent — the fields of
`approval-intent@1` a person needs in order to know what they are consenting to —
**plus** the binding:

```json
{ "approval_id": "ap_0001",
  "request_hash": "sha256:…",          // what a later consent must name
  "world": {"installation_id":"…","generation":3},
  "presented_at": "2026-09-11T23:40:00Z",
  "presentation_digest": "sha256:…",   // over the exact bytes rendered
  "intent": { "capability":"…", "actor":"…", "resource":"…",
              "placement":"…", "request_revision":2, "request":{…} } }
```

`presentation_digest` is hashed over **the object the phone was sent**, so a
later consent can assert *“this is what I was shown”* and the host can check that
claim rather than take it. It is not a substitute for `request_hash`; it is the
second half of the pair. `request_hash` says *what the runtime will do*;
`presentation_digest` says *what the person read*. Both must match at decision
time or the decision is refused.

**This is an analogy to WYSIWYS, not a citation of it.** What-you-see-is-what-you-
sign is a digital-signature property (Landrock and Pedersen, Cryptomathic, 1998):
the data-to-be-signed is rendered accurately by a trusted viewer before signing.
A phone screen is not a trusted viewer and this is not a signature scheme. The
useful part that does carry over is the requirement that the thing displayed and
the thing authorised are provably the same object.

### 3.2 The phone does not issue the command

The channel stays exclusive. The phone produces a **consent assertion** —
approval id, `request_hash`, `presentation_digest`, decision, device id, a nonce
and a timestamp — and the host verifies it and issues `approve_effect` itself,
inside the total order, on the one human-control channel that already exists.

Consequences, and they are the reason to prefer this shape:

- `check-intent-surface.mjs` keeps holding unchanged. No second command channel.
- The phone is an **authenticated authorizer**, not a new command issuer. The
  distinction is what keeps the 14-command allowlist meaningful.
- The host is where fail-closed is enforced, so a compromised or buggy phone
  cannot skip a check by not performing it.

### 3.3 Fail closed, and on what

Admission is a **pure predicate over an approval record and what the phone
claims**, so it can be tested exhaustively without a runtime. It refuses unless
*all* hold:

| refusal | condition |
|---|---|
| `approval-not-found` | no record with that id |
| `approval-not-pending` | status is anything but `pending` — `granted`, `denied` and `stale` all refuse, so a resolved request cannot be re-decided |
| `intent-changed` | the record's `request_hash` differs from the one the phone names |
| `presentation-mismatch` | the recomputed presentation digest differs from the one the phone names |
| `world-moved` | the record's lineage differs from the world's now |
| `presentation-expired` | the presentation is older than its window |
| `consent-replayed` | this `(approval_id, nonce)` was seen before |

Every one is a **refusal by name**. There is no default-allow branch: the
predicate returns `{:refused, reason}` for anything it was not built to admit.

### 3.4 Diagnostics and logs

The detail response is the only place the arguments travel, and it must not be
retained anywhere a diagnostic bundle reaches. The app's exported diagnostics
already record method, path, status and elapsed — never bodies — and the
connector's access log never carries a cookie, a body, a pairing code or the
identity itself. **A detail response must not be added to either**, and the
phone's screenshot path for support must not capture a detail screen.

## 4. What must pass before any write is enabled

Not one of these is satisfied today, and the list is the gate:

1. **Authorization at the host.** A rule in ampd that says which device may
   decide what, distinct from the session cookie that says a device paired.
   *Not designed here* — it is the open question, and it is Travis's and GPT's,
   not a session's.
2. **Replay tests.** A consent assertion replayed after a decision, after a
   revision, after a lineage advance, and twice in a row, each refused by name.
3. **Staleness tests.** Presentation older than its window; record moved between
   presentation and decision; approval resolved in between.
4. **A falsifier battery.** Each check stubbed out in turn, the suite required to
   go red for each — the `sabotage-validation.sh` discipline. A check nothing can
   falsify is not a check.
5. **The ordered-boundary classification.** Any new ampd operation must declare
   `:mutate` or `:read`; `:bind_basis` was mis-classified for five months because
   nobody declared it, and the gate that would have said so was not being run.

## 5. What was built alongside this document

Only the predicate, and only as a pure function with its tests — items 2 and 3
above, so that the gate has something to hold. `Ampd.Approvals.admit_consent/2`
takes an approval record and a claim and returns `:ok` or `{:refused, reason}`.
It is called by nothing. No endpoint, no route, no command, no channel.

Enabling any of this needs item 1 answered first.
