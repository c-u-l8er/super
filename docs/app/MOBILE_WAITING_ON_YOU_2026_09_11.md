# The companion carries what is waiting on you — 2026-09-11

The mobile companion could see seven projection collections and none of them was
the one a companion exists for. Every screen was built from `development_tasks`
and `development_attempts`, so "Needs me" meant *a plan needs review*. Meanwhile
the operator projection has carried, since long before the phone existed:

```elixir
"grant_requests"    => Enum.filter(GrantRegistry.requests(),  &(&1["status"] == "pending"))
"pending_approvals" => Enum.filter(Approvals.all(),           &(&1["status"] == "pending"))
```

Those two are the runtime *stopped*, waiting on a person — the desktop's own
first two sections are "Waiting on you · Consent for one effect". They were the
two collections not on the wire.

The visible symptom: with nothing to review, the Needs me screen printed
**"Nothing is waiting on a decision."** It had no basis for that sentence. On
Travis's own host, which has zero development tasks, it was the only sentence
the screen could produce — while a held effect there would have been invisible.

## What the phone now receives, and what it does not

Both queues are published, **narrowed to a named set of fields** in
`cockpit/src/mobile_gateway.rs`:

| | published |
|---|---|
| `pending_approvals` | `id · status · capability · actor · resource · placement` |
| `grant_requests` | `id · status · capability · actor · resource · requested_duration · created_at · reason` |

Every other collection in the snapshot goes out as the runtime wrote it, because
a workspace or a lane is an inventory record. These two are not. A pending
approval carries `envelope` — the arguments of the effect nobody has consented
to yet — and `held_ctx`, the caller's whole context; a grant request merges its
caller's fields into the stored record wholesale. So this is the one place in
the gateway where the allowlist is over **fields** rather than collections, and
a field the runtime adds later does not reach a phone until someone names it.

`cargo test mobile_gateway` puts a credential in `held_ctx` and a command line in
`envelope` and asserts neither appears anywhere in the serialised snapshot.

**The phone still cannot answer.** The gateway answers 405 to everything but
snapshot, pair and logout, and the cards say so: *"answered in desktop Super,
not here."* Whether a phone may ever consent is an authority question — gateway,
connector, cockpit and ampd — and is not opened here. Telling a person they are
being asked is worth doing on its own.

## The distinction the screen is built on

An empty list means **nobody is asking you**. A withheld list means **this app
does not know**. They are one character apart in JSON and opposite in meaning,
and a screen about being asked that prints the first when it means the second
has told the person the one thing they cannot check from the phone.

So:

- a collection that is not a list is published as `null`, never as `[]`;
- the app reads `null` as unavailable and draws `--` for the count, not `00`;
- the unavailable case gets its own card naming which queue was not published;
- a single unreadable record is counted and reported, not fatal — one bad row
  must not cost the person the rest of the queue.

A record without a `capability` is counted as unreadable rather than drawn: a
card saying somebody wants something without saying what sends the person to the
desktop to find out what they were told. An *empty* `actor` is a real value in
this runtime and draws as "No actor is named".

## Evidence

- `cargo test mobile_gateway` — **6 passed, 0 failed** (4 new: the field
  allowlist, the grant-request narrowing, a non-list withheld rather than
  emptied, an empty list not confused with a withheld one).
- `node --test mobile/test/gateway.test.mjs` — **11 passed, 0 failed**.
- `tools/gates.sh` — **8 held · 0 failed · 0 could not run**; webview ACL 35 held
  (no command changed), intent surface 6 held covering 25/25 mutations.
- `cargo build --release --offline` — clean. **The running desktop was not
  restarted**: a restart revokes every paired session, and Travis's phone has
  held one since 16:19. The new binary is on disk for the next launch.
- App side, `work/super-native`: `npx tsc --noEmit` clean, `npm test` **39
  passed, 0 failed** (6 new).
- Rendered on the Android emulator against `work/fixture-host.mjs`, which runs
  Super's real connector in front of its real gateway:
  - populated — **02 waiting on you**, a HELD ON CONSENT card
    (`github.repo.write`, asked by kestrel, over traaviis/trvm, placement local)
    and a GRANT REQUESTED card (`fs.read`, for the workspace, with its reason
    and its age), above the plan cards, with "1 request the host published could
    not be read on this phone" beneath them;
  - `--damaged` — **`--` waiting on you**, the readable request still drawn, and
    *"This app cannot see what is waiting on you."* naming held effects as the
    queue that was not published.

## Not done here

- **No push.** The app polls every 5 s while it is frontmost and nothing at all
  while it is backgrounded, so a held effect arriving while the phone is in a
  pocket is not noticed until the person opens the app. Every comparable product
  notifies on an approval gate. That needs a push transport and is a separate
  decision — a private tailnet has no relay to push through.
- **No "how long has this been held".** `Approvals.new_pending/1` writes no
  timestamp, so the phone has none and invents none. Grant requests carry
  `created_at` and it is shown.
- **No answer path.** See above; it is an authority question, not a UI one.
