# Managed Node lifecycle experiment

This opt-in path replaces the unrestricted callback with an independently owned
Node process. It is **not a production Carrier backend or an admitted profile**.
The current Carrier seccomp policy denies clone/clone3; Node needs threads.
That policy was not widened. No application service or public command is added.

## Build and test

From the Super root, on Linux with Rust, Node and the existing test prerequisites:

```sh
rustc -D warnings -O tools/hypersurface/node_guardian.rs -o tools/hypersurface/node-guardian
mkdir -p /tmp/managed-node-results
cd ampd
HS_TRVM_HOST=/absolute/path/TRVM/runtime/wasm/experimental/host.mjs \
SUPER_HOST_BIN=/absolute/path/super-host \
MANAGED_OUTPUT_DIR=/tmp/managed-node-results \
MIX_ENV=test mix test test/managed_node_test.exs test/reducer_bridge_test.exs
```

The managed tests require both HS_TRVM_HOST and MANAGED_OUTPUT_DIR; otherwise
they are skipped. The existing callback tests still require only HS_TRVM_HOST.
Use private test data. The guardian binary is generated and ignored by Git.

A trusted operator loads `reducer_bridge.exs` and constructs:

```elixir
{:ok, bridge} = HyperSurface.ReducerBridge.start_link({:managed_node, %{
  guardian: "/absolute/path/node-guardian",
  node: "/absolute/path/node",
  driver: "/absolute/path/super/tools/hypersurface/reduce-file.mjs",
  host: "/absolute/path/TRVM/runtime/wasm/experimental/host.mjs",
  scratch: "/private/scratch",
  timeout_ms: 2000
}})
```

Request callers still supply only their existing Peer/Lane references and input,
not executable paths or configuration. The legacy function constructor remains
available for comparison; its cancellation is still logical only.

## Ownership and acknowledgement

- A separate BEAM NodeExecutor monitors the bridge and owns a Port to the guardian.
- The Rust guardian directly owns the Node child. It installs Linux PDEATHSIG
  before Node starts and checks the captured parent, as the Carrier path does.
- Cancellation, deadline or bridge death sends the guardian a stop byte. Node owner
  or VM death closes the pipe. Either causes SIGKILL and `Child.wait` on the exact
  owned child. No PID lookup or process-group kill is used for normal stopping.
- Guardian death causes the kernel to kill Node. Loss of its acknowledgement is
  still unconfirmed: the surviving bridge retains its slot and refuses reuse.
- A managed cancel answers `:ok` only after a guardian exit status proving Node
  was reaped, or after the bridge already observed a managed owner carrying an explicit reaped-child witness. A signalling error or lost reply is never promoted to confirmed absence.
- Output is bounded at 2 MiB in both guardian and BEAM owner. Only a successful
  child exit and a candidate with `workerExited: true` are forwarded. Existing
  ownership revalidation and once-only collection remain in the bridge.
- Private input files are owned by the guardian after launch and normally removed
  on exit. A killed guardian can leave scratch evidence until owner cleanup.

Guardian status 0 is successful reaped output; 42 is a reaped stop; 67–69 are
reaped execution/output failures. Other exits lack confirmation and fence the
slot. A deadline currently collects as `executor_failed`, not a separate timeout
code. A cancel call can time out after five seconds while cleanup remains pending.

## What the tests establish

A real checked Wasm computation completes 20 times, with expected output and
once-only consumption. A completed managed result is rejected after occupancy
changes. Invalid JSON, unchecked candidates, nonzero exits and oversized output
are refused. A missing guardian refuses submission without killing the bridge.

A separate trusted Node heartbeat fixture is stopped on cancellation, deadline,
bridge death, abrupt/normal owner death and guardian death, before its independent ten-second
watchdog. Tests check that it is no longer running and its heartbeat stops.
Owner/guardian death retain an unconfirmed slot even when the test harness can
independently observe Node's death. Normal cleanup removes the private input.
These failure probes use synthetic Node work, not an interrupted real Wasm job.

## Limits and next gate

This owns one trusted Node process and its threads. It does not confine arbitrary
OS descendants, provide hard CPU/RSS quotas, bind the complete execution basis to
an admitted profile, or defend against malicious same-VM code or a substituted
trusted guardian. The configured driver must not spawn subprocesses. Carrier's
Landlock/seccomp and channel possession guarantees are **not** inherited merely
by using the same parent-death primitive.

Without the optional shared fence in REPLACEMENT.md, the blocked slot belongs to
one bridge incarnation. Bridge replacement loses it;
this base adapter alone provides no shared recovery fence or automatic retry.
REPLACEMENT.md adds a disk-backed attempt record and receipt-based reconciliation
for participating bridges, with its own explicit limits.
Bridge death triggers cleanup but a replacement is not yet prevented from starting
before that cleanup finishes. An owner with a lost guardian acknowledgement can
remain alive awaiting operator recovery. A permanently suspended BEAM can delay
its deadline/control handling; no independent guardian runtime limit is claimed.
The legacy PID constructor still checks authority before busy refusal. The opt-in
bounded handle in ADMISSION.md limits submission admission and keeps bursts out
of that queue; it does not bound all messages or eliminate current-check latency. These remain promotion gates, not completed features.

Next: an admitted threaded executor profile, integration with existing Carrier
possession and confirmed-absence reconciliation, then bounded admission/control
responsiveness. Preserve this lab path as evidence; do not promote it to a public
reducer command based on the physical-cleanup tests alone.
