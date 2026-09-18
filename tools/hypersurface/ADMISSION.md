# Bounded submission admission (laboratory API)

Construct an explicit handle:

```elixir
{:ok, handle} = HyperSurface.ReducerBridge.start_link(executor, admission: :bounded)
HyperSurface.ReducerBridge.submit(handle, peer, lane, input)
HyperSurface.ReducerBridge.cancel(handle, peer, operation)
HyperSurface.ReducerBridge.take(handle, peer, operation)
HyperSurface.ReducerBridge.stop(handle)
```

`executor` can be the existing callback or `{:managed_node, config}` documented
in MANAGED_NODE.md. The returned Handle contains a PID and admission table;
use the handle through the API. The original start_link/1 still returns a PID
and keeps its original behavior for comparisons. This is opt-in, not a new
public service or a production Carrier admission profile.

## Contract

One atomic ETS reservation permits one submission to enter an admission check.
Competing submissions return `{:refused, :overloaded}` before enqueueing their
payload or checking authority. This is a capacity refusal, not an authorization
verdict. A reserved request uses the unchanged authority → input → occupied-slot
checks. Result collection still revalidates authority. Taking and cancelling
need no submission permit, so they need not wait behind a burst of submissions.

The bridge owns the table. It releases the reservation after processing the
request; caller timeout never releases it early. A periodic server-handled sweep
reclaims a reservation whose caller died before enqueueing. Live reservations
are not reclaimed merely for being old. Stale tokens and tokens from another
caller are refused, and direct unreserved submissions to a bounded PID return
`admission_required`. Bridge death deletes the table automatically; a stale
handle's submit returns `bridge_unavailable` when the table is already gone.
Other process-death races retain normal GenServer.call exit semantics.

## Scope of the bound

This bounds live reservations through the supported submission API. It does not
bound every BEAM message or caller-side memory. Maintenance, result, take and
cancel messages also use the mailbox. A delayed request whose dead caller's
reservation was reclaimed may still arrive and is rejected by its stale token.
Trusted same-VM code can send arbitrary messages or edit a public ETS table;
this is not a defense against that code and creates no new authority boundary.

A slow current authority check can still delay cancellation. A live caller
suspended after reserving but before sending holds capacity until it resumes or
dies. Direct take/cancel floods, fairness across bridges, durable/global recovery
and production ingress limits remain outside this mechanism. There is no retry
loop: callers decide whether and when to retry overloaded work.

## Evidence and reproduction

The directed test suspends the bridge and starts 256 submitters: one reserved
submission reaches the mailbox and 255 receive overload refusals. The test counts
submission messages, not maintenance messages. It also exercises dead reservation
recovery, stale tokens, bypass refusal, a dead handle, authority/input refusals
and one-time result consumption.

Five paired 256-request bursts against an occupied bridge compare the legacy and
bounded APIs. A separate bounded managed-Node burst checks physical cancellation
and absence of the reaped Node PID. These are bounded bursts on an active desktop,
not an arrival-rate capacity model or a guaranteed cancellation latency.

Build node-guardian as described in MANAGED_NODE.md. From ampd, set HS_TRVM_HOST,
SUPER_HOST_BIN, ADMISSION_OUTPUT_DIR and MANAGED_OUTPUT_DIR to private local paths,
then run:

```sh
MIX_ENV=test mix test test/admission_test.exs test/managed_node_test.exs test/reducer_bridge_test.exs
```

Admission tests require both HS_TRVM_HOST and ADMISSION_OUTPUT_DIR; otherwise they
are skipped. Output directories must exist. Full managed steady-state throughput
and long-running overload testing remain to be measured.
