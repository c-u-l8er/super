defmodule Ampd.Carrier.Reaper do
  @moduledoc """
  The other half of "losing the runtime incarnation terminates the Carrier".

  ## The gap this closes

  `Ampd.Peer.drop/2` deletes the live incarnation the instant a channel dies.
  That is *semantic membership* ending, and it is immediate and correct. The
  source claimed it was also the process ending. It was not:

  ```text
  agent channel dies
      ↓
  Ampd.Peer drops the incarnation        ← membership over
      ↓
  the ampd ↔ host carrier channel is still open
      ↓
  serve_carrier's map still holds the child
      ↓
  the OS process is still running        ← nothing refers to it
  ```

  The existing `E13` asserted `Peer.carriers() == []` and passed, because that
  is true and is not the question. The two events are different events and the
  runtime had bound only one of them.

      semantic membership ended  ≠  process ended
      termination requested      ≠  termination established

  ## Why this is a process and not a function call

  `Ampd.Peer.drop/2` runs inside the `Ampd.Peer` GenServer, on the `:DOWN`
  path, and on `reset/0`. Submitting a machine request from there would put
  the carrier channel's 8-second deadline in front of every disconnect — and
  `Ampd.Peer` is the process every channel's liveness depends on. So the drop
  *announces* and this process *acts*.

  ## An unconfirmed reap is not a reap

  If the host cannot confirm the process is gone, that is recorded as an
  unresolved attempt against the Worker, exactly as an ambiguous start or stop
  is. It blocks a replacement until `Ampd.Carrier.reconcile/1` establishes
  absence. A reaper that logged a failure and moved on would be the
  duplicate-spawn hole reopened from a third direction.
  """
  use GenServer

  require Logger

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "A live Carrier has lost the Peer that owned it. Never blocks."
  def orphaned(inc) when is_map(inc), do: GenServer.cast(__MODULE__, {:orphaned, inc})

  @doc "For tests: wait until the queue is empty. Not used in production."
  def drain(timeout \\ 5_000), do: GenServer.call(__MODULE__, :drain, timeout)

  @doc "Carriers this incarnation could not confirm dead."
  def unconfirmed, do: GenServer.call(__MODULE__, :unconfirmed)

  @impl true
  def init(:ok), do: {:ok, %{unconfirmed: []}}

  @impl true
  def handle_cast({:orphaned, inc}, st) do
    case Ampd.Carrier.reap_orphans([inc]) do
      [{:ok, _ref}] ->
        {:noreply, st}

      [{:error, ref, why}] ->
        Logger.warning(
          "ampd: could not confirm the reap of carrier #{ref} whose peer is gone (#{why}) — " <>
            "a process may still exist; no replacement will be admitted until it is reconciled"
        )

        # **Only record it if the world is still the world it belonged to.**
        #
        # This arrives by cast, so it can land after a lineage advance or a
        # world reset — and an unresolved attempt written into a world that
        # replaced the one the Carrier belonged to would block a Worker that
        # has nothing to do with it. Found by a test whose next setup received
        # the previous test's orphan.
        #
        # The reap above still ran, because the *process* is real whatever the
        # world did. What a discontinuity removes is the meaning of the
        # record, not the existence of the process.
        if inc["world_ref"] == Ampd.World.lineage() do
          _ = record_unconfirmed(inc, why)
        else
          Logger.warning(
            "ampd: carrier #{ref}'s world advanced before its reap could be recorded — " <>
              "the attempt is not written into a world it does not belong to"
          )
        end

        {:noreply, %{st | unconfirmed: [inc["carrier_ref"] | st.unconfirmed]}}
    end
  end

  @impl true
  def handle_call(:drain, _f, st), do: {:reply, :ok, st}
  def handle_call(:unconfirmed, _f, st), do: {:reply, st.unconfirmed, st}

  # Same shape as an ambiguous stop, and deliberately a new attempt rather
  # than a mutation of the committed start: the start really did commit, and
  # rewriting that fact to describe a later event would lose both.
  defp record_unconfirmed(inc, why) do
    Ampd.AuthorityCoordinator.transact(fn ->
      Ampd.Loci.create_attempt(%{
        "schema" => "carrier-start-ticket@1",
        "ticket_id" => "ct_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)),
        "carrier_ref" => inc["carrier_ref"],
        "carrier_epoch" => inc["carrier_epoch"],
        "worker_ref" => inc["worker_ref"],
        "locus_ref" => inc["locus_ref"],
        "state" => "INDETERMINATE",
        "refused_as" => "the owning peer died and the reap was not confirmed: #{why}",
        "admitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)
  end
end
