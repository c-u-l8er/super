defmodule Ampd.Participant do
  @moduledoc """
  C1.0b·2 — the one way an ordered transaction crosses a process boundary,
  and the four outcomes it may report.

  ## The defect this exists for

  `Ampd.AuthorityCoordinator.transact/1` runs its closure **inside the
  coordinator process**, and that closure calls registries with
  `GenServer.call`. Measured on OTP 28 (`probes/ordered_participant.exs`):

      participant absent     caller EXITS :noproc
      participant dies       caller EXITS with the reason
      participant times out  caller EXITS :timeout

  The caller there is the total order. So a fault in any one registry becomes
  a control-plane discontinuity: `seq` back to zero, the projection epoch
  re-minted, every subscriber resnapshotting. The tree has 17 reachable
  participant processes and no `try` anywhere in `run/2`.

  ## Two questions, and the API only answers one

  `:gen_server.send_request/2` with `:gen_server.receive_response/2` keeps the
  caller alive and returns a value instead:

      absent      {:error, {:noproc, ServerRef}}
      dies        {:error, {Reason, Pid}}
      times out   :timeout
      replies     {:reply, Value}

  That closes **process isolation** and leaves **outcome ambiguity** exactly
  where it was. A participant that applied its mutation and then died is
  reported *identically* to one that died before applying it — measured, both
  `{:error, {:boom, pid}}`, distinguishable only by state that outlived the
  participant. A design that treats the first question as the second is the
  defect this module exists to avoid.

  ## The four classes

      APPLIED         the participant replied. The outcome is known.
      NOT_APPLIED     evidence establishes the mutation point was never
                      crossed — either the request was never delivered, or a
                      witness read a settled world and found nothing.
      INDETERMINATE   it may have happened, or may be ABOUT to. Never a
                      refusal, never retried.
      UNAVAILABLE     a read could not be obtained. Nothing was mutated, so
                      this is retryable in a way no mutation failure is.

  `UNAVAILABLE` exists because reads and mutations fail differently and
  collapsing them is how an unknown becomes a refusal. A read that could not
  be obtained says *the basis could not be established*; that is a different
  sentence from *the basis is absent*, and only the second is a refusal about
  the world.

  ## Why INDETERMINATE has a direction

  The sharpest measurement in the probe, and it is not visible from any
  return value. `receive_response/2` **abandons** the request on timeout —
  the OTP 28 documentation says no response will be received afterwards — but
  abandoning the request does not abandon the **work**:

      caller gives up after 300ms      witness: not mutated
      2.5 seconds later                witness: mutated

  So an ordered transaction that read a timeout as a refusal would release
  the total order and then be overtaken by its own mutation. INDETERMINATE
  after a timeout therefore means *may already have happened, or may be about
  to* — which is why a retry of it is a second execution and not a repeat of
  the first.

  ## When a witness may be consulted, and when it may not

  A **witness** is a caller-supplied re-derivation of "did my mutation land".
  It is sound after a death and unsound after a timeout, measured:

      death   + witness   the participant will never run again, so whatever
                          it did is final and the witness reads a settled
                          world                       → APPLIED / NOT_APPLIED

      timeout + witness   the participant is alive and still holds the
                          request. A witness here can report NOT_APPLIED
                          about a mutation that is merely pending, and a
                          false NOT_APPLIED is worse than an honest unknown
                                                      → INDETERMINATE

  So the witness is **not consulted at all** on a timeout. That asymmetry is
  the design constraint, and nothing in the return values shows it.

  ## Why this raises rather than returns

  Roughly sixty transaction call sites reach a participant, and the failures
  above are rare. Returning a new tuple shape would mean rewriting every one
  of those call sites' pattern matches to carry a case that almost never
  happens — which is how a case that almost never happens gets handled
  wrongly. So the success path keeps its existing contract exactly, and a
  failure raises `Ampd.Participant.Failure`, which
  `Ampd.AuthorityCoordinator.run/2` catches **by struct**.

  That is not "wrapping `fun.()`". A bare `catch :exit` around the closure
  would convert every failure — including one whose mutation had already
  landed — into an ordinary refusal, which is precisely what must not happen.
  This catches an exception the mechanism itself constructed, carrying the
  class it measured.

  ## Two participants in one operation — the standing rule

  **This module classifies ONE crossing. It does not make a transaction
  atomic, and nothing in this tree does.**

  A transaction that mutates participant A and then fails while mutating
  participant B leaves A mutated. There is no saga layer, no compensation
  framework, and building one is deliberately not this slice — it is a major
  new semantic mechanism and it should be forced by a real application rather
  than anticipated.

  What is required instead, and is enforced by review rather than by code:

  > Until ComputeDriven has explicit multi-participant transaction /
  > reconciliation semantics, **every ordered operation that mutates more
  > than one independently failing participant must prove its failure cuts
  > individually.** It either has a mechanical reconciliation for each cut,
  > or it represents the result as indeterminate. It may not claim atomicity
  > merely because the operations occur under one coordinator.

  The tree has exactly one such path today and it is worked through in
  `Ampd.Carrier.Terminal.finalise_stream/4`: `Ampd.Peer` then
  `Ampd.TerminalAttachment`, with a stated cut for *replied*, *never
  delivered*, *died* and *did not answer* — and no compensation on the last
  one, because compensating an INDETERMINATE mutation is how a live
  possession gets destroyed by a participant that was merely busy.

  ## Outside the total order, nothing changes

  A caller that is not the coordinator gets a plain `GenServer.call`, byte
  for byte. The isolation is only needed where an exit takes down something
  larger than the caller, and giving every caller in the tree a new failure
  mode to handle would be a much larger change than the defect warrants.

  ## `Ampd.Ordered`'s proof survives — measured, not assumed

  `Ampd.Ordered.from_coordinator?/1` compares `handle_call`'s `from` pid
  against the coordinator's. That is the *mechanical* proof that an authority
  mutation happened inside the total order, and a boundary change that
  altered the apparent caller would silently void it. Measured: both
  `GenServer.call` and `send_request` report the sending process, because
  `send_request` uses an alias for the reply and leaves `from`'s pid alone.
  """

  defmodule Failure do
    @moduledoc """
    A participant did not answer, and the class says what may be concluded.

    `outcome` is `:not_applied`, `:indeterminate` or `:unavailable`. There is
    no `:applied` — that path returns a value rather than raising.
    """
    defexception [:outcome, :server, :op, :reason, :message]

    def new(outcome, server, op, reason) do
      %__MODULE__{
        outcome: outcome,
        server: server,
        op: op,
        reason: reason,
        message:
          "#{inspect(server)} #{outcome} for #{inspect(op)}: #{inspect(reason)}"
      }
    end
  end

  @doc """
  The coordinator process, or `nil` before it starts.

  Read through `Ampd.Ordered` rather than re-derived, because "which process
  is the total order" is a fact that module owns.
  """
  def coordinator, do: Ampd.Ordered.coordinator()

  @doc "Are we executing inside the total order right now?"
  def inside?, do: Ampd.Ordered.inside?()

  @doc """
  Ask a participant, with the failure semantics its class deserves.

  `class` is `:read` or `:mutate` and is not optional — a boundary crossing
  whose class the caller has not decided is a boundary crossing whose failure
  cannot be classified either.

  Options:

    * `:timeout` — default 5_000, the `GenServer` default this replaces
    * `:witness` — a zero-arity function returning `:applied`, `:not_applied`
      or `:unknown`. **Consulted only after a death**, never after a timeout.
      Ignored entirely for `:read`.

  Outside the coordinator this is `GenServer.call/3` and nothing else.
  """
  def call(server, op, class, opts \\ []) when class in [:read, :mutate] do
    timeout = Keyword.get(opts, :timeout, 5_000)

    if inside?() do
      guarded(server, op, class, timeout, Keyword.get(opts, :witness))
    else
      GenServer.call(server, op, timeout)
    end
  end

  defp guarded(server, op, class, timeout, witness) do
    case ask(server, op, timeout) do
      {:reply, value} ->
        value

      # **Never delivered, and that is provable.** `send_request` resolves the
      # name and monitors before sending; a name that resolves to nothing
      # yields `:noproc` without a message ever leaving. So the mutation point
      # was not merely probably not crossed — the request did not arrive.
      {:error, {:noproc, _}} ->
        raise Failure.new(none_class(class), server, op, :noproc)

      # The request could not even be constructed. Same conclusion, arrived
      # at one step earlier.
      {:never_sent, why} ->
        raise Failure.new(none_class(class), server, op, {:request_not_sent, why})

      # Dead. Whatever it did is final, because it will not run again — which
      # is exactly the condition that makes a witness sound.
      {:error, {reason, _}} ->
        raise Failure.new(after_death(class, witness), server, op, reason)

      # **The witness is not consulted here**, and the reason is the whole
      # asymmetry: the participant is alive and still holds the request.
      :timeout ->
        raise Failure.new(after_timeout(class), server, op, :timeout)
    end
  end

  defp ask(server, op, timeout) do
    # **Split, because the two halves fail differently.** `send_request`
    # throwing means the request provably never left — a malformed server
    # reference, not a participant that may have acted. Folding it into the
    # `{:error, {reason, _}}` arm below classified it under "dead, whatever
    # it did is final", which for a mutation is `:indeterminate`: not
    # retryable, requires a human, about an operation that certainly did not
    # happen.
    case send_or_not(server, op) do
      {:sent, id} -> :gen_server.receive_response(id, timeout)
      {:never_sent, why} -> {:never_sent, why}
    end
  end

  defp send_or_not(server, op) do
    {:sent, :gen_server.send_request(server, op)}
  catch
    kind, why -> {:never_sent, {kind, why}}
  end

  # A read mutates nothing, so a read that never arrived and a read that
  # arrived and died are the same fact: the basis could not be established.
  defp none_class(:read), do: :unavailable
  defp none_class(:mutate), do: :not_applied

  defp after_timeout(:read), do: :unavailable
  defp after_timeout(:mutate), do: :indeterminate

  defp after_death(:read, _), do: :unavailable
  defp after_death(:mutate, nil), do: :indeterminate

  defp after_death(:mutate, witness) when is_function(witness, 0) do
    case run_witness(witness) do
      :applied -> :indeterminate
      :not_applied -> :not_applied
      _ -> :indeterminate
    end
  end

  @doc "How long a witness has to answer before it stops being evidence."
  def witness_deadline_ms, do: 1_000

  # A witness that says APPLIED does not make the operation a success: the
  # caller still never received the participant's answer, and the value it
  # would have returned is gone. It makes the operation *not repeatable*,
  # which is what INDETERMINATE already forbids. Only a witness that
  # establishes the mutation point was never crossed narrows anything.
  #
  # A witness that itself fails leaves the class where it was. It is
  # evidence, and evidence that could not be obtained is not evidence to the
  # contrary.
  #
  # **It runs in another process, on a deadline, and the first version did
  # not.** `rescue`/`catch` bound a witness that *fails*; nothing bounded one
  # that simply does not return. Run inline on the coordinator, such a
  # witness is worse than a crash: the process stays alive, so the supervisor
  # never restarts it, `budget_ms/0` never applies because that is the
  # *client's* deadline, and every later transaction and observation queues
  # behind it permanently. Measured — a later `ops/0` timed out and the
  # coordinator was still alive and still stuck.
  #
  # `:witness` is caller-supplied and this function is reachable from a public
  # API, so the bound is not a courtesy.
  #
  # **`spawn_monitor`, deliberately not `Task.async`.** A `Task` LINKS to its
  # caller, and the caller here is the total order: an abnormal exit in the
  # witness process propagates through that link and kills the coordinator
  # unless it traps exits, which it does not. The body below catches
  # everything a witness can raise, throw or exit with — but a witness is
  # caller-supplied code and "nothing can make this process die abnormally"
  # is not a claim to rest the control plane on when the alternative is one
  # primitive with no link at all.
  #
  # So: no link, a monitor for the death, and a kill on the deadline. The
  # coordinator cannot be taken down by a witness under any reason.
  defp run_witness(witness) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        verdict =
          try do
            witness.()
          rescue
            _ -> :unknown
          catch
            _, _ -> :unknown
          end

        send(me, {:witness, self(), verdict})
      end)

    receive do
      {:witness, ^pid, verdict} ->
        Process.demonitor(ref, [:flush])
        verdict

      {:DOWN, ^ref, :process, ^pid, _} ->
        :unknown
    after
      witness_deadline_ms() ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        :unknown
    end
  end

  @doc """
  The refusal a caught `Failure` becomes.

  Graded by what the operator can actually do:

      unavailable     retryable. Nothing was mutated.
      not_applied     retryable. The mutation point was never crossed.
      indeterminate   NOT retryable, and requires a human — the operation may
                      have been applied, or may still be about to be, and a
                      second attempt is a second execution.
  """
  def refusal(%Failure{} = f) do
    # Kebab, like every other code in the tree. The atoms are snake_case
    # because they are Elixir; the codes are a public vocabulary and are not.
    Ampd.Refusal.new("participant-" <> String.replace(to_string(f.outcome), "_", "-"),
      component: "Ampd.Participant",
      retryable: f.outcome in [:unavailable, :not_applied],
      requires_human: f.outcome == :indeterminate,
      operator_detail: %{
        "participant" => inspect(f.server),
        "outcome" => to_string(f.outcome),
        "reason" => inspect(f.reason),
        "hint" => hint(f.outcome)
      }
    )
  end

  defp hint(:unavailable),
    do:
      "a read could not be obtained from this participant, so the basis was not established — " <>
        "nothing was mutated and the operation may be attempted again"

  defp hint(:not_applied),
    do:
      "the request never reached this participant, so the mutation point was not crossed — " <>
        "the operation may be attempted again"

  defp hint(:indeterminate),
    do:
      "this participant may have applied the mutation, or may still be about to: a timed-out " <>
        "request is abandoned but its work is not. Do not retry — establish the outcome first"
end
