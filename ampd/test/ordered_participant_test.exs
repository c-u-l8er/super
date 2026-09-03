defmodule Ampd.OrderedParticipantTest do
  @moduledoc """
  C1.0b·2 falsifiers — `P.1`..`P.18`.

  The proposition:

      Every participant failure crossing the total-order boundary has an
      explicit outcome class, and no layer converts an unknown execution
      multiplicity into success, refusal, or an automatic retry.

  The weaker proposition — *a registry crash does not crash the
  AuthorityCoordinator* — is deliberately not what is tested here. A
  coordinator that survives by calling every failure a refusal has made the
  system worse: it now reports "did not happen" about mutations that did.

  ## Why a probe participant, and where the real registries are used

  The mechanism's matrix needs a participant that will die at a chosen
  instant, mutate and then die, or answer too late. No registry in this tree
  will do any of that on request, so `Probe` does — and the ETS witness it
  writes to outlives it, which is the only way to tell "mutated then died"
  from "died before mutating".

  The integration cases use the real `Ampd.Peer` and `Ampd.Loci`, made absent
  through their own supervisor so the fault is deterministic rather than
  raced.
  """
  use ExUnit.Case, async: false

  alias Ampd.{AuthorityCoordinator, Loci, Participant, Peer}
  alias Ampd.Participant.Failure

  defmodule Probe do
    @moduledoc false
    use GenServer

    def start(tab), do: GenServer.start(__MODULE__, tab, name: __MODULE__)
    def init(tab), do: {:ok, tab}

    def handle_call(:read, _f, tab), do: {:reply, {:ok, :value}, tab}
    def handle_call(:slow, _f, tab), do: Process.sleep(3_000) && {:reply, :late, tab}
    def handle_call(:die_clean, _f, _tab), do: exit(:probe_boom)

    def handle_call(:mutate_then_die, _f, tab) do
      :ets.insert(tab, {:mutated, true})
      exit(:probe_boom)
    end

    def handle_call(:mutate_then_reply, _f, tab) do
      :ets.insert(tab, {:mutated, true})
      {:reply, :applied, tab}
    end

    def handle_call(:slow_mutate, _f, tab) do
      Process.sleep(1_500)
      :ets.insert(tab, {:mutated, true})
      {:reply, :applied, tab}
    end

    def handle_call(:reply_then_die, from, tab) do
      GenServer.reply(from, :answered)
      exit(:probe_boom)
    end
  end

  setup do
    tab = :ets.new(:witness, [:public, :set])
    on_exit(fn -> if p = Process.whereis(Probe), do: Process.exit(p, :kill) end)
    {:ok, tab: tab}
  end

  defp up(tab) do
    if p = Process.whereis(Probe), do: (Process.exit(p, :kill); Process.sleep(30))
    {:ok, p} = Probe.start(tab)
    p
  end

  defp down do
    if p = Process.whereis(Probe), do: (Process.exit(p, :kill); Process.sleep(30))
    :ok
  end

  defp mutated?(tab), do: :ets.lookup(tab, :mutated) != []

  # The whole point: this runs INSIDE the coordinator process.
  defp ordered(fun), do: AuthorityCoordinator.transact(fun)

  defp ask(op, class, opts \\ []),
    do: ordered(fn -> Participant.call(Probe, op, class, opts) end)

  defp coordinator, do: Process.whereis(AuthorityCoordinator)

  # ===================================================================== P.1
  describe "P.1 · a read that cannot be obtained is UNAVAILABLE, and nothing else" do
    test "participant absent before the read", %{tab: tab} do
      _ = tab
      down()
      before = coordinator()

      assert {:refused, r} = ask(:read, :read)
      assert r["code"] == "participant-unavailable"
      assert r["retryable"] == true, "a read mutated nothing and must be retryable"
      assert coordinator() == before, "an absent participant took the total order down"
    end

    test "participant dies during the read", %{tab: tab} do
      up(tab)
      before = coordinator()

      assert {:refused, r} = ask(:die_clean, :read)
      assert r["code"] == "participant-unavailable"
      assert coordinator() == before
    end

    test "participant times out during the read", %{tab: tab} do
      up(tab)
      before = coordinator()

      assert {:refused, r} = ask(:slow, :read, timeout: 200)
      assert r["code"] == "participant-unavailable"
      assert coordinator() == before
    end

    test "and a read that succeeds is unchanged", %{tab: tab} do
      up(tab)
      assert {:ok, :value} = ask(:read, :read)
    end
  end

  # ===================================================================== P.2
  describe "P.2 · a mutation that never arrived is NOT_APPLIED" do
    test "an absent participant crossed no mutation point", %{tab: tab} do
      down()

      assert {:refused, r} = ask(:mutate_then_reply, :mutate)
      assert r["code"] == "participant-not-applied"
      assert r["retryable"] == true

      # And the claim is true, not merely typed: the witness is untouched
      # because the request never left.
      refute mutated?(tab)
    end
  end

  # ===================================================================== P.3
  describe "P.3 · a mutation whose reply died is INDETERMINATE, never a refusal" do
    test "died before the mutation point", %{tab: tab} do
      up(tab)

      assert {:refused, r} = ask(:die_clean, :mutate)
      assert r["code"] == "participant-indeterminate"
      refute mutated?(tab)
    end

    test "died AFTER the mutation point, and reports the same thing", %{tab: tab} do
      up(tab)

      assert {:refused, r} = ask(:mutate_then_die, :mutate)
      assert r["code"] == "participant-indeterminate"

      # **The two cases above are indistinguishable from the reply.** This is
      # the measurement the whole slice rests on: the mutation happened, and
      # nothing in what the caller received says so.
      assert mutated?(tab), "the probe did apply its mutation"
    end

    test "an indeterminate mutation is never retryable and requires a human", %{tab: tab} do
      up(tab)

      assert {:refused, r} = ask(:mutate_then_die, :mutate)
      assert r["retryable"] == false, "a second attempt is a second execution"
      assert r["requires_human"] == true
    end

    test "replying and then dying is a success — the answer arrived", %{tab: tab} do
      up(tab)
      assert :answered = ask(:reply_then_die, :mutate)
    end
  end

  # ===================================================================== P.4
  describe "P.4 · a timed-out mutation is INDETERMINATE, and the witness is not consulted" do
    test "the work lands after the caller gave up", %{tab: tab} do
      up(tab)

      # A witness that would report NOT_APPLIED if anyone asked it now.
      witness = fn -> if mutated?(tab), do: :applied, else: :not_applied end

      assert {:refused, r} = ask(:slow_mutate, :mutate, timeout: 200, witness: witness)
      assert r["code"] == "participant-indeterminate"
      refute mutated?(tab), "not yet — which is exactly the trap"

      # `receive_response/2` abandons the request. It does not abandon the
      # WORK. A transaction that read this as a refusal would release the
      # total order and be overtaken by its own mutation.
      Process.sleep(2_000)
      assert mutated?(tab), "the abandoned request still landed"
    end

    test "the same witness DOES narrow a death", %{tab: tab} do
      up(tab)
      witness = fn -> if mutated?(tab), do: :applied, else: :not_applied end

      assert {:refused, r} = ask(:die_clean, :mutate, witness: witness)

      # Dead, so the world is settled and the witness is evidence.
      assert r["code"] == "participant-not-applied"
      refute mutated?(tab)
    end

    test "a witness that finds the mutation does NOT make it a success", %{tab: tab} do
      up(tab)
      witness = fn -> if mutated?(tab), do: :applied, else: :not_applied end

      assert {:refused, r} = ask(:mutate_then_die, :mutate, witness: witness)

      # It happened — and the caller never received the answer, so the value
      # is gone and the operation is still not repeatable.
      assert r["code"] == "participant-indeterminate"
      assert mutated?(tab)
    end

    test "a witness that itself fails leaves the class where it was", %{tab: tab} do
      up(tab)
      assert {:refused, r} = ask(:die_clean, :mutate, witness: fn -> raise "no" end)
      assert r["code"] == "participant-indeterminate"
    end
  end

  # ===================================================================== P.5
  test "P.5 · the projection does not move because a participant failed", %{tab: tab} do
    up(tab)

    ops_before = AuthorityCoordinator.ops()
    epoch_before = AuthorityCoordinator.epoch()

    assert {:refused, _} = ask(:die_clean, :mutate)

    assert AuthorityCoordinator.ops() == ops_before,
           "a failed participant advanced the ordered revision"

    assert AuthorityCoordinator.epoch() == epoch_before,
           "a failed participant re-minted the projection epoch"
  end

  # ===================================================================== P.6
  test "P.6 · an ordinary exit still takes the coordinator down", %{tab: tab} do
    _ = tab

    # **The survival is not blanket, and this is what says so.** A
    # coordinator that survived faults nobody had classified would be a
    # coordinator whose survival meant nothing; `classify/1` catches a struct
    # the boundary constructed and lets everything else through.
    before = coordinator()
    ref = Process.monitor(before)

    catch_exit(AuthorityCoordinator.transact(fn -> exit(:unclassified) end))
    assert_receive {:DOWN, ^ref, :process, _, _}, 3_000

    # The supervisor puts it back, with a fresh incarnation — which is the
    # honest consequence of an unclassified fault, not something to hide.
    Process.sleep(300)
    assert coordinator() != nil
    assert coordinator() != before
  end

  # ===================================================================== P.7
  describe "P.7 · outside the total order nothing changed" do
    test "a plain caller still gets GenServer.call semantics", %{tab: tab} do
      down()

      # Not a typed refusal — an exit, exactly as before. Every existing
      # caller in the tree keeps the contract it was written against.
      assert catch_exit(Participant.call(Probe, :read, :read)) |> elem(0) == :noproc

      up(tab)
      assert {:ok, :value} = Participant.call(Probe, :read, :read)
    end
  end

  # ===================================================================== P.8
  describe "P.8 · the real registries, made absent through their own supervisor" do
    setup do
      on_exit(fn ->
        for m <- [Ampd.Peer, Ampd.Loci] do
          if Process.whereis(m) == nil do
            _ = Supervisor.restart_child(Ampd.Supervisor, m)
          end
        end

        Process.sleep(200)
      end)

      :ok
    end

    test "Ampd.Peer absent during an ordered read" do
      :ok = Supervisor.terminate_child(Ampd.Supervisor, Ampd.Peer)
      before = coordinator()

      assert {:refused, r} = ordered(fn -> Peer.resolve("pr-nope") end)
      assert r["code"] == "participant-unavailable"
      assert coordinator() == before, "losing the peer registry took the total order down"
    end

    test "Ampd.Peer absent during an ordered mutation" do
      :ok = Supervisor.terminate_child(Ampd.Supervisor, Ampd.Peer)
      before = coordinator()

      assert {:refused, r} = ordered(fn -> Peer.detach_carrier("pr-nope") end)
      assert r["code"] == "participant-not-applied"
      assert coordinator() == before
    end

    test "Ampd.Loci absent during an ordered read" do
      :ok = Supervisor.terminate_child(Ampd.Supervisor, Ampd.Loci)
      before = coordinator()

      assert {:refused, r} = ordered(fn -> Loci.worker("wk_0001") end)
      assert r["code"] == "participant-unavailable"
      assert coordinator() == before
    end

    test "Ampd.Loci absent during an ordered durable mutation" do
      :ok = Supervisor.terminate_child(Ampd.Supervisor, Ampd.Loci)
      before = coordinator()

      assert {:refused, r} =
               ordered(fn -> Loci.create_attempt(%{"ticket_id" => "ct_nope"}) end)

      assert r["code"] == "participant-not-applied"
      assert coordinator() == before
    end
  end

  # ===================================================================== P.9
  test "P.9 · every client call in the converted registries declares its class" do
    # The classification is a list, so it can be read rather than inferred —
    # and a tag that is a mutation on the server side and a read on the client
    # side would be the two-lists drift this avoided by construction in
    # `Ampd.Loci`.
    for tag <- ~w(attach detach reset attach_carrier install_terminal
                  activate_terminal remove_terminal)a do
      assert Peer.class(tag) == :mutate, "#{tag} is a mutation"
    end

    for tag <- ~w(resolve list attachment carrier carriers owner_pid
                  terminal_attachment)a do
      assert Peer.class(tag) == :read, "#{tag} is a read"
    end

    assert Loci.class(:create) == :mutate
    assert Loci.class(:create_attempt) == :mutate
    assert Loci.class(:patch) == :mutate
    assert Loci.class(:worker) == :read
    assert Loci.class(:lane) == :read
  end

  # ==================================================================== P.11
  describe "P.11 · no layer acts on an unknown as though it were a decision" do
    setup do
      Application.put_env(:ampd, :carrier_machine, Ampd.Carrier.Machine.Harness)
      Ampd.Carrier.Machine.Harness.reset()
      on_exit(fn -> Application.delete_env(:ampd, :carrier_machine) end)

      ticket = %{
        "ticket_id" => "ct_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
        "carrier_ref" => "cr_settle",
        "carrier_epoch" => String.duplicate("a", 32)
      }

      {:ok, ticket: ticket}
    end

    test "an indeterminate commit does NOT reap the process it may have committed", ctx do
      before = Ampd.Carrier.Machine.Harness.terminated()
      r = Participant.refusal(%Failure{outcome: :indeterminate, server: Peer, op: :x, reason: :timeout})

      assert {:refused, ^r} = Ampd.Carrier.settle_commit(ctx.ticket, %{}, r)

      assert Ampd.Carrier.Machine.Harness.terminated() == before,
             "an indeterminate commit reaped a Carrier that may be a member"
    end

    test "and an ordinary refusal still reaps", ctx do
      before = length(Ampd.Carrier.Machine.Harness.terminated())
      r = %{"code" => "carrier-worker-generation-stale"}

      assert {:refused, ^r} = Ampd.Carrier.settle_commit(ctx.ticket, %{}, r)

      assert length(Ampd.Carrier.Machine.Harness.terminated()) == before + 1,
             "a decided refusal must still reap — otherwise this test proves nothing"
    end

    test "an unavailable commit reaps, because nothing was mutated", ctx do
      before = length(Ampd.Carrier.Machine.Harness.terminated())
      r = Participant.refusal(%Failure{outcome: :unavailable, server: Peer, op: :x, reason: :noproc})

      assert {:refused, _} = Ampd.Carrier.settle_commit(ctx.ticket, %{}, r)

      assert length(Ampd.Carrier.Machine.Harness.terminated()) == before + 1,
             "a read that never established the basis mutated nothing — the process is not a member"
    end
  end

  # ==================================================================== P.10
  test "P.10 · the failure carries which participant and which class", %{tab: tab} do
    up(tab)

    f =
      try do
        ordered(fn -> Participant.call(Probe, :die_clean, :mutate) end)
        nil
      rescue
        e in Failure -> e
      end

    # It does not escape the coordinator as an exception — it is converted
    # there. So the observable is the refusal's operator detail.
    assert f == nil

    # And the probe above died doing it, so it has to be back before the
    # second ask — otherwise this measures an absent participant and reports
    # `not-applied`, which is a different (and correct) answer to a different
    # question.
    up(tab)
    assert {:refused, r} = ask(:die_clean, :mutate)
    d = r["operator_detail"]
    assert d["participant"] =~ "Probe"
    assert d["outcome"] == "indeterminate"
    assert d["hint"] =~ "Do not retry"
  end
end
