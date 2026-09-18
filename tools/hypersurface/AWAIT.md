# Completion notifications for the laboratory reducer bridge

`ReducerBridge.await(server_or_handle, peer, operation, readiness_timeout_ms \\ 5000)` first tries the existing `take/3` fast path. If the operation is pending, it registers one bounded waiter, sleeps until a readiness notification, then calls the same `take/3` authority check. It does not poll on a timer.

A result message alone does not wake the waiter. Executor exit, or a named unconfirmed-stop outcome, makes the operation ready to inspect. Managed execution still requires the existing reaped-child evidence before successful collection. Notification grants no authority and carries no candidate result.

The timeout bounds the readiness receive, not the initial/final GenServer calls. `{:error, :await_timeout}` does not cancel work or consume its result. A later caller can collect it. Only one waiter can register per pending operation; another gets `{:refused, :await_in_progress}`. Caller death and timeout remove the waiter. A monitor alias drops late notifications when deactivated. The bridge remains free to handle cancellation while a client waits. Existing `take/3` remains available.

This is an opt-in laboratory API, not a new public Super command or a production Carrier integration. Tiny jobs already ready at the first `take` avoid subscription overhead. Batching remains a separate workload decision; the bridge does not silently combine independently authorized effects.
