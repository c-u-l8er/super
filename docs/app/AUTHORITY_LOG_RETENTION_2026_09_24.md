# Authority log retention — candidate 3 (2026-09-24)

Branch `authority-log-3`, on `b68e6da` (`authority-log-closure`: candidate 2
`91a080f` + the checkpoint timings `a088896` + the ordered-closure fix).
Human-authored infrastructure; no bot credit.

## The ruling this implements

Travis, 2026-09-24, adopting an outside reviewer's recommendation
(ProjectAmp2 `SUPER_BUILDS_LANE.md` §5, root commit `547effd`):

> Retire completed items from the in-memory working lists, while preserving
> durable history. Keep whatever compact indexes are necessary for receipt
> lookup, recovery, deduplication, and preventing used grants from becoming
> usable again. Retirement must not remove anything an unfinished operation
> still needs. Verify the performance benefit after this change; bounded
> lists alone do not establish flat cost.

Same day, same ruling: no install yet; a rehearsed full-world restore, not a
downgrade, before any install.

## What was growing (measured on candidate 2 before this change)

Real growth to 10,000 effects (foundation lane, `3879947`): tmpfs perform p50
3.9 → 6.1 ms, **p95 5.3 → 34.1 ms**; the effects store handed 183 KB of state to
each save at an empty journal and grew with history; every consumed one-shot
grant stayed in the grant list (10,000 at the last cell). The per-save cost was
the lists: `Delta` walks the old and new list together, appends copy the list
(`++`), the grant view is refreshed against the whole list, the effects list is
rebuilt up to the changed cell, and the log's own image holds every row too.

## The shape

**The archive.** `<data_dir>/authority.archive`, append-only, the log's frame
format after its own header (`AMPD-AUTHORITY-ARCHIVE/1\n`), one frame per
retirement batch: `%{"b" => n, "rows" => %{store => [row]}}`, `n` gapless from 1.
`Ampd.AuthorityLog` appends and syncs a batch BEFORE the record that removes the
rows from the working lists. Checkpoints never cover or delete it. Boot reads
frame headers only (the last frame is verified, because a torn write can only be
the last one).

**The compact indexes**, in each store's own state, so they are carried by the
log and its checkpoints:

| store | field | entry |
|---|---|---|
| effects | `retired` | id → `[final_state, batch]` |
| effects | `retired_count` | `"*"` and each actor → n |
| receipts | `retired_refs` | effect_ref → `[receipt_id, batch]` |
| receipts | `retired_count` | kind → (`"*"` and each actor → n) |
| grant_registry | `retired` | id → `[status, batch, consumptions]` |
| approvals | `retired` | id → `[status, batch, consumed_by]` |
| effects | `retired_batches` | batch → `[lowest key, highest key, rows, %{actor => rows}]` |
| receipts | `retired_batches` | batch → kind → the same, keyed by `seq` |

The `retired` maps only ever gain keys, so `Delta` writes them as
`{:merge, store, field, added}` — a new op, used for any map field that only
gained keys with every old value the same term. Without it each retirement
would rewrite the whole index.

**What each index answers** (the ruling's four):

* *receipt lookup* — `Receipts.for_effect/1` falls back to `retired_refs` and
  reads the row from the archive; `Effects.get/1` and `GrantRegistry.get/1` do
  the same by id. The archive is read by the CALLER at an offset the log hands
  out, never inside the registry or the log writer.
* *recovery* — nothing retired is ever in flight (see below), so
  `Effects.recover!/0`, the recovery listing and the reconcile queue read only
  the working list, and lose nothing.
* *deduplication* — a second receipt for a retired effect is `write-duplicate`
  (`retired_refs`); claiming a retired effect is `effect-settled`; moving one is
  `journal-transition-illegal` from its final state.
* *a used grant never usable again* — a retired grant is not in the list the
  decision reads, so nothing can select it; a ticket naming it is refused:
  `write-duplicate` when the ticket's effect is in the recorded consumptions
  (exactly what the live row would have said), `write-unscoped` otherwise.

## What is retired, and only together

A **settled bundle** (`Ampd.Retention`): an effect that is terminal
(`COMMITTED`/`FAILED`), holds no live lease, is not among the newest
`keep_recent` terminal effects, and whose recovery row — computed by
`Ampd.Effects.Contract.classify/3`, the verdict an operator's listing shows — is
`COMPLETE`, `NOT_REQUIRED`, `NOT_OWED` or `NOT_YET_OWED` for every participant.
With it: every receipt naming it; its grant iff no longer active and every
consumer is retired or in the batch; its approval iff consumed by it. A row that
reads `MISSING`, `CONFLICT(…)`, `LEGACY_UNWITNESSED` or `INDETERMINATE` is never
retired — that is what an operator has to see.

**One pass is one ordered transaction and one log record**
(`Ampd.Authority.retire_settled/1` → coordinator → `AuthorityLog.group/1`): archive
and sync the rows, then Effects, Receipts, Approvals, GrantRegistry drop and
index them. That order means a refusal part-way (which the group would still
commit) never leaves a live row pointing at a gone one.

**Leases.** Retiring an effect moves its (retired) leases out of the table the
per-effect paths walk into a `settled` map of reason only, so a late ticket for
one is still refused by its exact name (`write-lease-retired` / `-closed`).

## Decisions taken as defaults (reversible; each is a setting or a line)

1. **Settings** (`config :ampd, authority_retention:`): `keep_recent` 256,
   `min_batch` 256, `max_batch` 2048, `interval_ms` 30,000, `check_every` 64,
   `enabled` true. The history windows show 50, so `keep_recent` ≥ 50 keeps every
   window's `recent` served from memory.
2. **COMMITTED may still move** to FAILED/UNKNOWN under the contract (the
   gateway's rescue after the receipt). Retirement forecloses that move; it is
   safe because a live lease excludes the effect, its receipt must be COMPLETE,
   and the newest `keep_recent` are never retired — so the move can only be
   refused for an effect whose own perform finished long ago.
3. **Archive damage does not seal authority.** Decisions read the indexes, not
   the archive. A batch that does not verify on read is named in the reader's
   answer (`archive-unreadable · …`); a torn LAST batch is truncated at boot and
   named by a durable `recovered` record, like a torn log tail.
4. **No witness event** for a retirement: `wek-r3-trace@3` is WEK's format and is
   unchanged. The retirement is the log record's ops.
5. **World `schema_version` stays 3.** No version-3 world exists outside test
   directories (candidate 2 was never installed); version 3 now means "the log,
   and possibly an archive". An installed world is version 2 and is migrated
   exactly as candidate 2 migrates it.
6. **The trigger** is `Ampd.Retention`, a supervised process that holds no
   authority: poked after each `Gateway.perform`, looking every `check_every`
   pokes and every `interval_ms`; a full batch looks again at once.

## Known costs and open items

* **Paging reads only the batches a page can reach.** The paged commands
  (`list_effect_history`, `list_receipts`) run inside the coordinator's
  ordered observation, so reading the whole archive there would be unbounded
  work in the total order. Each retired batch is indexed with its lowest and
  highest key and its rows per actor (`retired_batches`), and
  `Projection.history_page/4` reads the eligible batches newest-first,
  stopping once no unread batch can enter the page. A page served from the
  working rows reads none (tested, with the log's `archive_batch_reads`
  counter). A sparse actor's page can still read several batches — the
  per-actor counts skip batches with none of its rows, not batches with few.
* **A pass holds the total order** for its duration (one archive sync and one
  log record of the shrunk working lists, measured below).
* **The compact indexes still grow with history** — ~one small entry per
  retired effect, grant and receipt, held in each registry's heap and in the
  log's image (and so in every checkpoint). Far smaller than the rows, but
  not flat: a major GC of `Ampd.Effects` copies its live heap, index
  included. If a p95 tail survives retention, this is the first suspect,
  and the fix is to hold the index off-heap (ETS) rather than to drop it.
  Per incarnation, `Ampd.Effects` also keeps the ticket ids of terminals and
  the settled leases' reasons — both compact, both reset by a restart.
* **Closure.** The ordered-closure gate reads CLOSED on this branch (rebased
  onto `b68e6da`, which closed the 15 items candidates 1 and 2 had left open
  and which the suite's Q.4 could not see because it reads the committed
  census). The archive calls cross through `Ampd.Participant` like every other
  `AuthorityLog` call; the regenerated census has the same crossings, opaque
  set and totals.
* **`approve_effect/2` on a retired approval** answers `approval-unknown`
  rather than `approval-not-pending` (it reads the working list). Both refuse.
* **The archive grows without bound** — by design: the ruling is to keep
  history. Its size and a policy for it are Travis's.
* **Directory fsync.** The archive's creation, like the log's rotation, does
  not sync the directory entry; a power loss (not a process kill) right after
  the first batch could lose the file's name. Same gap as the log; not
  exercised by the kill battery, which kills processes.

## Evidence

(Filled in as each run completes: the new tests, the full suite against
candidate 2's failing names, the kill battery with retention active, and the
foundation lane's timing on this build.)
