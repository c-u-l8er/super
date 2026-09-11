# Review test recovery after a runtime restart

New native test starts retain their runtime projection epoch. When a saved review is opened, the host asks the runtime to reconcile unfinished starts from earlier epochs. Those runs receive a durable `failed` outcome with reason `interrupted`, a null verdict, zero test count, and no inferred snapshot identity. Completed results and current-epoch starts remain unchanged; review notes and plan status are preserved.

The host bridge checks the current full world tuple before admitting start, finish or recovery requests. Recovery obtains the current epoch outside the ordered receiver; the receiver never calls back into the coordinator. The saved-world host lock prevents two host processes from opening the same world. Recovery uses the existing ordered attempt patch and reserved completion capacity.

The native panel requests reconciliation once per review/world tuple per host session, retrying on error. Interrupted runtime results take precedence over stale device output in presentation. Recovery never executes tests or accepts a plan. A late conflicting final report refuses.

Legacy starts created before runtime epochs were recorded remain unconfirmed; their origin is not guessed. Recovery happens when the review is opened, not by a startup-wide background scan. The device runner may exist until its existing timeout if it escapes a crashed process group; its later output is not imported as success. Host-only crashes while the same runtime survives are not separately covered by epoch reconciliation.

Validation includes runtime tests for current/old epochs, immutable completed outcomes, no passing verdict, note preservation, idempotence, late-report refusal, legacy records and store restart. The native crash fixture uses a disposable saved world under explicit XDG state/data roots, creates real plans and runs, kills only its own process group, and reopens that same world. Provider responses are deterministic fixtures. This is not yet explicit acceptance or a real-model Super-on-Super development cycle.
