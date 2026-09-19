# Shared replacement fence (laboratory)

This opt-in layer prevents participating managed bridges from starting another
Node process on a Lane until the prior attempt has an exact guardian exit receipt.
It is a physical-execution exclusion record, not an authority grant or a completed
production Carrier integration.

## Usage

Load reducer_bridge.exs, then explicitly start one fence service under a trusted
supervisor and keep its directory fixed across restarts:

```elixir
{:ok, fence} = HyperSurface.ExecutionFence.start_link("/private/fixed/execution-fence")
{:ok, bridge} = HyperSurface.ReducerBridge.start_link(
  {:managed_node, Map.put(managed_config, :fence, true)}, admission: :bounded)
```

Use the handle as described in ADMISSION.md. The bridge derives the fence key from
the validated Lane reference and overrides any config-supplied key. One Lane is
excluded across participating bridges regardless of which Peer or Worker currently
occupies it. All participants must use this service and directory; legacy callbacks
and managed executors without `fence: true` do not participate. No application
startup or public command is installed. Rebuild node-guardian after upgrading.

## Protocol

1. The fence serializes a claim and syncs `{lane, random_attempt}` to DETS before
   returning permission to launch. A timeout never means permission was granted.
2. The guardian receives the private receipt path and random attempt. After it
   waits/reaps its exact Node child, it writes that attempt to a new temporary file,
   syncs it, renames it into place, and syncs the receipt directory.
3. A live owner or a later replacement asks `ExecutionFence.reconcile(lane)`.
   Only an exact receipt for the pending attempt permits removal of the pending
   record. Its deletion is synced before deleting the receipt.
4. A new claim can then be synced and launched. Missing/partial/wrong proof,
   guardian death, and elapsed time do not clear the old claim.

The guardian can write proof after the BEAM executor owner dies, because it owns
Node independently. If the guardian itself dies, Linux still kills Node, but no
wait receipt exists: replacement remains blocked. That is uncertainty, not a
permission to guess from an old PID. Guardian exit 70 means it could not persist
its receipt after observing exit; it also leaves the attempt fenced.

The pending store opens with `repair: false`. An initialized directory missing its
store, an orphaned directory, an invalid initialization marker, or an unreadable
store refuses initialization instead of inventing an empty execution set. A crash
before the guardian starts can leave a claim with no receipt; this deliberately
requires recovery rather than assuming nothing started. No force-clear API exists.

## Tests

`replacement_test.exs` adds six tests:

- Pause a test-owned guardian, kill the bridge, and refuse replacement both before
  and after restarting the fence service. Resume it; replacement succeeds only
  after its exit receipt and then cancels with confirmed physical absence.
- Repeat with the BEAM executor owner killed, so no live owner can forward proof.
- Kill the guardian: Node dies but replacement remains blocked across restart.
- Reject a wrong receipt and refuse boot with a missing pending store.
- Run ten real checked-Wasm jobs through the fence; refuse if the fence is absent.
- Kill the fence owner abruptly; reopen its synced store and retain the pending claim.

Build the guardian as in MANAGED_NODE.md. From ampd, set HS_TRVM_HOST,
SUPER_HOST_BIN, REPLACEMENT_OUTPUT_DIR, ADMISSION_OUTPUT_DIR and MANAGED_OUTPUT_DIR
to existing private paths, then run:

```sh
MIX_ENV=test mix test test/replacement_test.exs test/admission_test.exs test/managed_node_test.exs test/reducer_bridge_test.exs
```

The replacement tests require HS_TRVM_HOST and REPLACEMENT_OUTPUT_DIR; otherwise
they skip. Never point test data or the fence at a live world.

## Limits

One registered service per BEAM VM, and **only one VM at a time may own this
DETS directory**. This is not a cross-VM lock or distributed consensus protocol.
Do not change/delete/restore the directory to bypass a pending record. Directory
identity, trusted guardian code and receipt integrity are installation assumptions.
The unconfined trusted Node driver can access its user's files; this is not a
cryptographic receipt or a defense against malicious host/same-VM code.

Tests establish bridge/service process-restart behavior. Full VM/host/power-loss,
filesystem durability faults, receipt-write failures and interrupted initialization
need a broader fault matrix. DETS may refuse an unclean store; automatic repair is
not enabled. Missing entire installation state cannot be distinguished from a new
installation without an external trust anchor.

Unknown attempts stay blocked. Receipt-based reconcile is implemented; recovery
when proof is permanently lost still needs the existing Carrier host's independently
confirmed-absence machinery and an admitted threaded execution profile. No automatic
retry, exactly-once effect guarantee or durable result replay is added. The old
bridge's result slot remains ephemeral. Physical exclusion does not decide whether
an old result is current; existing collection authority checks still do that.

The fsync cost and longer sustained managed throughput remain to be benchmarked.
