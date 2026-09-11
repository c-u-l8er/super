# Review acceptance across test profiles — 9 September 2026

For a saved review, each test profile that has been used must have its latest runtime-confirmed passing result on the same captured source snapshot. Unused profiles are not required. The latest overall run remains the acceptance anchor. Unfinished runs block acceptance, including an older unfinished run superseded by a later run of that profile.

The runtime enforces this during native acceptance preparation and again during the human acceptance decision. A later passing Rust result cannot hide an earlier JavaScript failure. A newly passing profile on changed source requires other used profiles to be rerun on that snapshot. A new failure after preflight invalidates acceptance. Reruns can supersede historical failures once all used profiles agree; earlier records remain retained.

New immutable acceptance records add profile_run_refs, mapping each covered profile to its exact latest test run. Those runs retain their individual source and toolchain identities. Existing acceptance records remain readable; this is not retroactive recertification. Native saved-file verification and explicit human Save/acceptance remain required. This does not require every available profile, make test execution mandatory for unopened reviews, or complete plans automatically.

The review panel shows a summary of used profiles, failed/incomplete results and differing snapshots. The acceptance action is available when current coverage agrees. Host-reported test results remain bounded evidence, not independent attestation or full application coverage.

Validation: 42 runtime tests, 57 JavaScript behavior tests, release build and intent/boundary/closure checks passed. A native disposable-world flow passed 28 assertions with 19 real screenshots: deliberate JavaScript failure, later Rust pass without acceptance, changed source requiring a rerun, matching passing profiles, explicit source Save and human acceptance, and immutable profile references after restart. The provider was a deterministic local fixture, with no new real-provider upload.
