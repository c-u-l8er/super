# HyperSurface Worker/reducer integration experiment

This is a laboratory bridge, not a public command, installed service, Carrier
backend, or new authority registry. Load it explicitly; the application does
not start it. A trusted operator installs one executor when constructing it.

## What it exercises

Submission uses existing AuthorityCoordinator, Peer, Worker.occupancy, Loci,
and World lineage. The bridge binds the operation to the input digest, lane,
Worker generation, Peer epoch, and a fresh occupancy_epoch minted by Peer on
every successful Worker attachment. The field is an additive internal field
of carrier-attachment@1; existing attachments without it fail closed here.
It is distinct from terminal attachment_epoch.

The bridge retains one in-memory outcome, with no queue. It waits for its
executor process to exit before allowing collection, then checks the current
ownership basis under AuthorityCoordinator. Collection consumes the slot once.
Another Peer cannot collect or cancel by naming the operation reference.
This is a point-in-time collection check, not authority for later effects.

The real test executor invokes TRVM's pinned ABI-v2 experimental Wasm host in
Node. Its candidate result reports workerExited; System.cmd waits for Node
exit, and the bridge also observes the BEAM executor exit. The tests hold a
real completed computation before delivery to make ownership changes
deterministic. Carrier machinery uses the existing test harness; this is not
an end-to-end confined Carrier execution.

## Explicit limits

- Cancellation suppresses acceptance; it does not physically interrupt Node.
- Detachment is checked at collection, not an automatic compute interrupt.
- Bridge death loses all state and does not guarantee descendant cleanup.
- An abandoned result occupies the single slot until collected or bridge death.
- The installed callback and all BEAM code are trusted. This is not protection
  against malicious code inside the same VM. Peer references use the existing
  runtime trust model; there is no new authenticated external endpoint.
- Wasm artifact pinning is provided by the TRVM host, but no admitted Super
  execution profile binds the Node executable, driver, and their dependencies.
- There is no hard process memory/CPU confinement, durable replay, distributed
  conformance claim, or integration into scheduling, Validation, or CommandSpec.

These limits prevent promotion of this bridge as a production reducer service.

## Reproduce

From super/ampd with the native host and standard test prerequisites installed:

    HS_TRVM_HOST=/absolute/path/TRVM/runtime/wasm/experimental/host.mjs       mix test test/reducer_bridge_test.exs

Without HS_TRVM_HOST the laboratory tests are skipped. It is trusted test
configuration, not a caller-selected execution path. Node must be on PATH.
The driver reads a bounded test input file; production input admission is not
provided by this driver.

## Next implementation gate

Choose an executor that Super can actually possess and confine, then demonstrate
physical cleanup on timeout, cancellation, and owner/service death. Bind that
executor's complete execution basis to an admitted profile. Only after those
checks should a public reducer command or durable operation lifecycle be added.
Keep the current source-hygiene Validation ledger specific to its existing job.

## Opt-in managed Node experiment (2026-09-15)

[MANAGED_NODE.md](MANAGED_NODE.md) documents the new `{:managed_node, config}`
constructor, Linux guardian, physical-stop probes and remaining promotion gates.
The callback behavior and limits above still describe the legacy constructor.
The managed path does not weaken or replace the current Carrier profile.

## Bounded submission handle (2026-09-15)

[ADMISSION.md](ADMISSION.md) documents the opt-in `admission: :bounded` constructor,
one-reservation submission path, overload refusals and control-message behavior.
It composes with the managed Node executor; the original PID constructor remains
available for baseline comparisons.

## Shared replacement fence (2026-09-15)

[REPLACEMENT.md](REPLACEMENT.md) documents opt-in disk-backed Lane exclusion and
guardian exit receipts across bridge replacement. It composes with the managed
executor and bounded handle; its single-VM ownership and recovery limits remain
explicit.
