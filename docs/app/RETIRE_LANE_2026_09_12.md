# Retiring a lane — 2026-09-12

**Status: a separate proposal, for a ruling. Nothing here is built, and it is
deliberately not bundled with the review-limits work.**

## The gap, from a real lane

On 2026-09-12 `tools/dogfood-setup.mjs` opened lane `ln_0016` against
`ProjectAmp2/computedriven.com` when the work was for `ProjectAmp2/super`. The
cause was the setup guessing (`?? repos[0]`), now fixed. What this proposal is
about is what happened next: **nothing in the world could take that lane out of
use.**

* There is no `close_lane`, `retire_lane` or `delete_lane` in `CommandSpec`.
* `delete_workspace` refuses a workspace holding a lane —
  `workspace-has-lanes`, *"Workspace deletion cannot remove established lanes or
  workers"* — and the comment above it says lanes retain their ancestry.

**That refusal is right and this proposal does not touch it.** A lane records
that a bot was once permitted to work in a repository under a goal; deleting it
would erase an authority decision that was really made. The gap is not that the
history is kept. It is that *keeping the history* and *still accepting new work*
are the same state.

So `ln_0016` remains open: it can still be named by a new worker, a new plan,
and a new worktree capability, and nothing on it says it was a mistake. The
recovery had to re-create five plans on a correct lane and cancel the
originals, and then leave the lane sitting there.

## What is proposed

One transition on a field the record already has. A lane today:

    %{"id" => "ln_0016", "schema" => "lane@1", "status" => "open",
      "actor" => …, "goal_ref" => …, "repository_ref" => …, "workspace_ref" => …}

`status` becomes `open | retired`. Two human-control mutations, following the
shape `close_worker` / `reopen_worker` already set:

    retire_lane   lane_ref, reason      open → retired
    reopen_lane   lane_ref, reason      retired → open

`reason` is required and kept in the lane's history, because a retired lane
with no reason is the same puzzle for the next reader that `ln_0016` is now.

## What a retired lane must refuse, each by its own name

Not one predicate. A person who is told "that lane is retired" while trying to
do four different things should be told which thing they were trying to do.

| refused | because |
|---|---|
| `open_worker` on it | new work in flight under a binding withdrawn on purpose |
| `create_development_task` on it | a new plan would inherit its `repository_ref` |
| `record_development_attempt` / `record_development_change_set` on a plan of its | review material would name a repository nobody means any more |
| `accept_development_attempt` on such a plan | acceptance writes to the repository the lane names — the one case where the binding is not merely descriptive |
| `attach_worker` / `establish_worktree` on it | a retired lane must not admit a **new worktree capability**; this is the authority-bearing one |

## What must keep working, and this is the point

* Reading the lane, its goal, its actor, its repository, its plans, its
  attempts, its history. Retirement is a state, not a disappearance.
* `close_worker` on a worker it already holds. Retiring a lane is a decision
  about the lane; closing a worker is a decision about work in flight.
* `update_development_task` to `cancelled` on its plans, so a lane can be tidied
  after it is retired as well as before.
* Existing active worktree capabilities keep whatever lifetime they already
  have. Retirement refuses **new** authority; it is not a revocation, and
  dressing it up as one would make it a second, quieter `revoke_grant`.

## Two things to rule on

1. **May a lane be retired while it still holds an open worker?** Recommended:
   **no** — refuse `lane-has-open-workers` and name them, the way
   `Workbench.choose` refuses while a command is running. Retiring under a live
   worker would leave the worker holding a binding the world has withdrawn, and
   the alternative (retire and close them for you) makes one command do two
   decisions.
2. **Does a retired lane still block `delete_workspace`?** Recommended:
   **yes, unchanged.** Retirement preserves ancestry; a workspace that held a
   lane still held it. Making retirement a route to deletion would reintroduce
   exactly what the existing refusal protects.

## Not proposed

* Deleting a lane, or making `delete_workspace` more permissive.
* Moving a lane to a different repository. A lane's repository is part of what
  the lane *is*; rebinding it would silently relabel every plan, attempt and
  capability already recorded against it. Retire it and open another.
* Retiring anything automatically. A wrong binding is a judgement, and the
  reason field exists because a person has to make it.

## Where this would be verified

`ampd/test/` for the transition and each refusal by name, plus a negative case
per row of the table above; `tools/sabotage-*.sh` shape for making each refusal
admit in turn, so a clause that stops refusing is caught rather than assumed.
The live check is `ln_0016` in Travis's own world: retired with a reason, still
readable, still counted, and refusing a new plan.
