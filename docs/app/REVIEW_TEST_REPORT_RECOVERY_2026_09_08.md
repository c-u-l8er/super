# Review test completion report recovery

Implemented 8 September 2026. The native host retains an exact completion payload in memory before attempting to finish its admitted runtime test run. If that report fails, the review panel offers **Retry saving outcome**. Retry submits the retained payload and never launches a test process.

The existing `review_tests` native command accepts `retry` with only world and run id. It accepts no outcome from the page. Pending payloads are not rebuilt from the device cache; cache contents cannot advertise a trusted retry. A native host restart loses this retry capability. Full crash reconciliation of runtime starts remains open; missing outcomes are never promoted to passing results.

Retries must match the captured full world tuple. The runtime's existing exact-outcome idempotence handles an acknowledgement lost after a successful write. Repeated reporting errors retain the pending completion. Listing overlays native memory so deleting the local cache does not hide a pending result; successful retry recreates its small local index. A maximum of 32 pending completions bounds retained memory.

Validation: native Rust tests cover exact replay, lost acknowledgements, repeated failure, cache tampering/loss, session/world refusal and rejection of page-supplied outcomes. The native plan/file workflow covers real successful completion, cancellation, cache removal and rejection of an unknown retry. Separate, visibly labeled UI component fixtures exercise a reporting failure, retry and success through the production panel in the native window. These fixtures simulate the reporting transport; they do not prove a live runtime-disconnect-and-reconnect sequence.

No runtime schema, acceptance rules, test profile or repository file writing behavior changes in this increment. Full app-process restart reconciliation and explicit acceptance bound to the tested result are the next MVP gaps.
