# HyperSurface-0: fixed local Carrier profile

Implementation slice, 2026-09-13. No new backend, public command option or
confinement guarantee. `start_carrier(locus_ref)` resolves the runtime-owned
`super.local-carrier-terminal.v0` profile after existing occupancy checks.

`Ampd.SurfaceProfile` binds the contract vocabulary, current floor version and
digest, host profile digest and execution-basis digest into `surface_binding`.
The existing attempt persists that binding before machine submission. Commit
checks the binding alongside the existing currentness, payload correspondence
and confinement checks. The accepted incarnation retains the binding.

This profile means trusted-host Linux process confinement, mandatory physical
terminal (access separately authorized), no network, no hard resource quota
claim, host-selected payload, and fresh execution after confirmed absence.
Preflight is eligibility to attempt, not observed-instance acceptance.

The start command removes the internal binding from its response and returns
a bounded summary instead. Worker projections add `surface` with only `status`, `admission_profile` and
`evidence`. A live current member supplies accepted evidence, independently of
attempt bookkeeping. Pending/indeterminate attempts expose their existing
state without claiming accepted-instance evidence. Missing legacy bindings
remain readable and are marked `legacy-or-unrecorded`; they cannot commit new
membership under this profile. No migration rewrites old evidence. Physical
absence and no active membership remain different facts.

The new integration tests use the actual Control/Carrier/Worker path with the
explicit existing machine harness. The queued-start experiment suspends the
real Gate, waits its production caller timeout, resumes it, observes the late
harness submission, and reconciles the attempt. This establishes the queue
semantics, not the cost or cleanup latency of a real slow VM backend. Existing
native `super-host verify` remains the check against real confined processes.

The public profile-selection cases from the research catalog remain future
work: V0 deliberately exposes no new command fields. Unsupported requirements
are covered at the internal preflight seam. No Wasmtime integration, durable
external-completion owner, concurrent-start transport or VM backend is added.

Validation commands from an isolated checkout:

```sh
(cd host && cargo build --offline --release)
bash tools/build-payloads.sh --offline
(cd ampd && mix compile --warnings-as-errors && mix test)
host/target/release/super-host verify
```

The test runtime uses private scratch data. Do not substitute a product-world
path for its test data directory. Native verification also creates its own
worlds. Review the accompanying implementation receipt for measured results.
