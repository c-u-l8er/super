defmodule Ampd.CarrierTest do
  @moduledoc """
  D.1.3b·2 falsifiers — `E1`..`E16`.

  The proposition:

      A confined OS process becomes the execution Carrier of a Worker only by
      an admission that is re-derived at commit time against a world that may
      have moved while the machine was busy. A successful spawn is not
      membership.

  ## What makes these falsifiers rather than assertions

  Each negative case proves three things, the rule inherited unchanged from
  D.1.1, D.1.2 and D.1.3a:

      1  it was refused
      2  it was refused **by the expected name**
      3  the world is unchanged — no live Carrier, no committed attempt

  and, new here because the machine phase can physically start something:

      4  the process that was started is **reaped**, and is not left running
         with no membership

  ## Why a harness drives the fault matrix

  Same division D.1.3a made. Fault injection needs a machine that can be told
  to return an observation belonging to a different start, or to fail, which a
  real host is not. `super-host verify`'s D.1.3b section keeps the positive
  path against the real confined process; this file keeps the faults.

  The harness is selected explicitly per test and `E12` asserts that the
  *unconfigured* default is the channel, so the selection cannot become the
  rule.
  """
  use ExUnit.Case, async: false

  alias Ampd.{Authority, Bridge, Carrier, Control, Loci, Peer, Worker, World}
  alias Ampd.Carrier.Machine.Harness

  # ==================================================================== setup
  setup do
    # **Drain first, then reset.**
    #
    # The reaper is a cast by design — nothing about a channel closing should
    # wait on machine latency — so the previous test's `Peer.reset/0` may have
    # announced an orphan that has not been processed yet. Draining *after*
    # `Ampd.reset()` writes that orphan's unresolved attempt into the freshly
    # reset world, where it blocks a Worker it has nothing to do with. Draining
    # first flushes it into the world it belongs to, which the reset then
    # clears.
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()

    Ampd.reset()
    Bridge.reset()
    Peer.reset()
    Harness.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
    Application.put_env(:ampd, :carrier_machine, Harness)

    on_exit(fn ->
      Application.delete_env(:ampd, :carrier_machine)
      Harness.reset()
    end)

    # And once more after the resets, since `Peer.reset/0` above announces the
    # carriers it just dropped.
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)

    Process.sleep(120)
    Authority.install_worktree()

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "run a carrier"]), "goal")
    lane = ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")
    worker = occupy!(control, agent, lane["id"])

    %{control: control, agent: agent, goal: goal, lane: lane, worker: worker, repo_ref: r["ref"]}
  end

  defp occupy!(control, agent, lane_id, purpose \\ "work") do
    w = ok!(Control.command(control, :open_worker, [lane_id, purpose]), "worker")
    ok!(Control.command(agent, :attach_worker, [w["id"]]), "worker")
    w
  end

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key} to be allowed, got: #{inspect(Map.take(result, ["allow", "reason", "refusal"]))}"

    result[key]
  end

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-d13b2")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "d13b2\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "d13b2@example.invalid"],
          ["config", "user.name", "D13B2"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo setup failed: git #{Enum.join(args, " ")} -> #{out}"
    end

    dir
  end

  defp footprint do
    %{carriers: length(Peer.carriers()), attempts: length(Loci.attempts())}
  end

  defp committed?(t), do: Loci.attempt(t)["state"] == "COMMITTED"
  defp attempt_state(t), do: Loci.attempt(t)["state"]

  # ==================================================================== E1
  describe "E1 · admission is what reaches the machine, not a request" do
    test "a Peer that occupies nothing never causes a spawn", ctx do
      # A second live channel for the same actor, occupying nothing. Identity
      # is necessary and not sufficient — the D.1.2 result, now load-bearing
      # one layer up: this Peer IS `kestrel` and still may not start a Carrier.
      {:ok, stranger} = Peer.attach_agent("kestrel")

      before = footprint()
      assert {:refused, r} = Carrier.start(stranger, ctx.lane["id"])
      assert r["code"] == "carrier-not-attached"

      # **Not "asked and refused".** The machine never saw it.
      assert Harness.started() == [], "an unadmitted start reached the machine"
      assert footprint() == before
    end

    test "an unknown Locus never causes a spawn", ctx do
      assert {:refused, r} = Carrier.start(ctx.agent, "ln_9999")
      assert r["code"] == "locus-unknown"
      assert Harness.started() == []
    end
  end

  # ==================================================================== E2
  describe "E2 · a successful admission and machine start commits a Carrier" do
    test "the live incarnation names the Worker, the Locus and the Peer", ctx do
      assert {:ok, inc} = Carrier.start(ctx.agent, ctx.lane["id"])

      assert inc["schema"] == "carrier-incarnation@1"
      assert inc["worker_ref"] == ctx.worker["id"]
      assert inc["locus_ref"] == ctx.lane["id"]
      assert inc["peer_ref"] == ctx.agent
      assert inc["status"] == "RUNNING"

      assert [^inc] = Peer.carriers()
      assert length(Harness.started()) == 1
      assert Carrier.status_of(ctx.worker) == "RUNNING"
    end

    test "the incarnation carries no authority-shaped key", ctx do
      assert {:ok, inc} = Carrier.start(ctx.agent, ctx.lane["id"])

      # The D.1.2 denylist discipline, applied to the new record. A nested
      # object inherits every disclosure rule of the record it is in, so the
      # walk is recursive — the `F19f` lesson.
      forbidden =
        ~w(grant grant_ref cap_ref capability capabilities rights delegation
           command executable path pty shell worktree_root pid resource_ref)

      walk = fn walk, v ->
        case v do
          m when is_map(m) ->
            for {k, sub} <- m do
              refute k in forbidden, "authority-shaped key #{k} in carrier-incarnation@1"
              walk.(walk, sub)
            end

          l when is_list(l) ->
            Enum.each(l, &walk.(walk, &1))

          _ ->
            :ok
        end
      end

      walk.(walk, inc)
    end
  end

  # ==================================================================== E3
  describe "E3 · the Worker closes during the machine phase" do
    test "the process started but cannot commit, and is reaped", ctx do
      Harness.put_policy(fn ticket ->
        # The world moves while the machine is busy. This is the whole point
        # of the phase being outside the total order — and the whole reason
        # the commit may not trust the ticket.
        Ampd.AuthorityCoordinator.transact(fn -> Worker.close(ctx.worker["id"]) end)
        {:ok, Harness.observation(ticket)}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] in ~w(carrier-worker-generation-stale worker-not-open)

      assert Peer.carriers() == [], "a stale start installed a live Carrier"
      assert length(Harness.started()) == 1, "the machine should have started"
      assert length(Harness.terminated()) == 1, "the refused process was not reaped"
    end
  end

  # ==================================================================== E4
  describe "E4 · the Worker generation advances during the machine phase" do
    test "a close/reopen cycle refuses the commit", ctx do
      Harness.put_policy(fn ticket ->
        Ampd.AuthorityCoordinator.transact(fn ->
          Worker.close(ctx.worker["id"])
          Worker.reopen(ctx.worker["id"])
        end)

        {:ok, Harness.observation(ticket)}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])

      # The Worker is open again and looks exactly as it did. Only the
      # generation says otherwise — which is why the ticket binds it.
      assert Loci.worker(ctx.worker["id"])["status"] == "open"
      assert r["code"] == "carrier-worker-generation-stale"
      assert Peer.carriers() == []
      assert length(Harness.terminated()) == 1
    end
  end

  # ==================================================================== E5
  describe "E5 · the world lineage advances during the machine phase" do
    test "a new incarnation refuses the commit", ctx do
      Harness.put_policy(fn ticket ->
        World.bump_generation!("carrier test", %{})
        {:ok, Harness.observation(ticket)}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] in ~w(carrier-world-generation-stale carrier-peer-gone carrier-not-attached)
      assert Peer.carriers() == []
    end
  end

  # ==================================================================== E6
  describe "E6 · the occupancy attachment detaches during the machine phase" do
    test "a detached Peer cannot commit a Carrier", ctx do
      Harness.put_policy(fn ticket ->
        Peer.detach_worker(ctx.agent)
        {:ok, Harness.observation(ticket)}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-not-attached"
      assert Peer.carriers() == []
      assert length(Harness.terminated()) == 1
    end
  end

  # ==================================================================== E7
  describe "E7 · an observation cannot cross a Carrier incarnation" do
    test "an observation stamped with another start is never accepted", ctx do
      Harness.put_policy(fn ticket ->
        {:ok, Harness.observation(ticket, %{"carrier_epoch" => "0000000000000000"})}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-observation-cross-incarnation"

      # It was received. This is not a test that the message never arrived.
      assert length(Harness.started()) == 1
      assert Peer.carriers() == []
      assert length(Harness.terminated()) == 1
    end

    test "a different carrier_ref is refused too", ctx do
      Harness.put_policy(fn ticket ->
        {:ok, Harness.observation(ticket, %{"carrier_ref" => "cr_deadbeef"})}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-observation-cross-incarnation"
    end
  end

  # ==================================================================== E8
  describe "E8 · the observed confinement floor is required, not assumed" do
    test "a process without no_new_privs cannot commit", ctx do
      Harness.put_policy(fn ticket ->
        obs = Harness.observation(ticket)
        {:ok, put_in(obs, ["observed", "no_new_privs"], false)}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-confinement-unacceptable"
      assert Peer.carriers() == []
      assert length(Harness.terminated()) == 1
    end

    test "a process with a descriptor outside the allowlist cannot commit", ctx do
      Harness.put_policy(fn ticket ->
        obs = Harness.observation(ticket)
        {:ok, put_in(obs, ["observed", "fds"], Map.put(obs["observed"]["fds"], "9", "/etc/passwd"))}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-confinement-unacceptable"
      assert Peer.carriers() == []
    end

    test "a process with no seccomp filter cannot commit", ctx do
      Harness.put_policy(fn ticket ->
        obs = Harness.observation(ticket)
        {:ok, put_in(obs, ["observed", "seccomp_mode"], 0)}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-confinement-unacceptable"
    end
  end

  # ==================================================================== E9
  describe "E9 · a failed machine phase is INDETERMINATE and never retried" do
    test "one machine failure produces one attempt and no second start", ctx do
      Harness.put_policy(fn _t -> {:error, "the carrier channel did not answer in time"} end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-start-indeterminate"

      assert length(Harness.started()) == 1, "an indeterminate start was retried"
      assert Peer.carriers() == []

      [a] = Loci.attempts()
      assert a["state"] == "INDETERMINATE"
    end

    test "an unreconciled attempt blocks a second admission for that Worker", ctx do
      Harness.put_policy(fn _t -> {:error, "no answer"} end)
      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])

      # The attempt is INDETERMINATE, which is terminal-for-recovery but not
      # a licence to start another. It is `in_flight/0` that gates, and an
      # INDETERMINATE attempt is deliberately not in flight — so this second
      # start IS admitted. The falsifier records which way it goes rather
      # than asserting the behaviour we would prefer.
      Harness.put_policy(fn t -> {:ok, Harness.observation(t)} end)
      result = Carrier.start(ctx.agent, ctx.lane["id"])

      case result do
        {:ok, _} ->
          assert length(Loci.attempts()) == 2,
                 "a second admission must be its own attempt, never a reuse of the first"

        {:refused, r} ->
          assert r["code"] == "carrier-start-unreconciled"
      end
    end
  end

  # =================================================================== E10
  describe "E10 · exactly one live Carrier per Peer" do
    test "a second start is refused while the first is live", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-already-live"
      assert length(Peer.carriers()) == 1
      assert length(Harness.started()) == 1, "a refused second start reached the machine"
    end
  end

  # =================================================================== E11
  describe "E11 · Carrier death leaves the Worker and the Locus standing" do
    test "stopping a Carrier removes only the incarnation", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      :ok = Carrier.stop(ctx.agent)

      assert Peer.carriers() == []
      assert Loci.worker(ctx.worker["id"])["status"] == "open"
      assert Loci.lane(ctx.lane["id"]) != nil

      # Occupancy is a Peer property and survives its Carrier dying, which is
      # the OCCUPIED/OFFLINE state the cockpit must be able to render.
      assert Peer.attachment(ctx.agent) != nil
      assert Worker.occupancy(Peer.resolve(ctx.agent), ctx.lane) == :ok
      assert Carrier.status_of(ctx.worker) == "OFFLINE"
    end

    test "a replacement gets a fresh ref and epoch and a fresh admission", ctx do
      assert {:ok, a} = Carrier.start(ctx.agent, ctx.lane["id"])
      :ok = Carrier.stop(ctx.agent)
      assert {:ok, b} = Carrier.start(ctx.agent, ctx.lane["id"])

      refute a["carrier_ref"] == b["carrier_ref"]
      refute a["carrier_epoch"] == b["carrier_epoch"]
      assert length(Loci.attempts()) == 2
      assert length(Harness.started()) == 2
    end
  end

  # =================================================================== E12
  describe "E12 · there is no ambient machine fallback" do
    test "the unconfigured default is the possessed channel", _ctx do
      Application.delete_env(:ampd, :carrier_machine)
      assert Carrier.machine() == Ampd.Carrier.Machine.Channel
    end

    test "with no channel possessed the machine refuses by name rather than execing", ctx do
      Application.delete_env(:ampd, :carrier_machine)
      Bridge.drop_carrier_endpoint()

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-start-indeterminate"
      assert Peer.carriers() == []
    end
  end

  # =================================================================== E13
  describe "E13 · losing the runtime incarnation ends Carrier membership" do
    test "a Peer reset drops every live Carrier", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert length(Peer.carriers()) == 1

      Peer.reset()

      assert Peer.carriers() == [],
             "a Carrier survived the Peer incarnation that admitted it"
    end

    test "losing the channel drops the Carrier with the attachment", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      Peer.detach(ctx.agent)

      assert Peer.carriers() == []
      assert Peer.attachments() == []
    end
  end

  # =================================================================== E14
  describe "E14 · the durable attempt records what happened and confers nothing" do
    test "a committed start leaves exactly one COMMITTED attempt", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      [a] = Loci.attempts()
      assert a["schema"] == "carrier-start-ticket@1"
      assert committed?(a["ticket_id"])
    end

    test "a refused commit leaves a terminal attempt and no membership", ctx do
      Harness.put_policy(fn ticket ->
        {:ok, Harness.observation(ticket, %{"carrier_epoch" => "0000000000000000"})}
      end)

      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      [a] = Loci.attempts()
      assert attempt_state(a["ticket_id"]) == "STALE"
      assert Peer.carriers() == []
    end

    test "an attempt on disk does not make a process current", ctx do
      # Write a COMMITTED attempt directly and prove the projection still
      # says OFFLINE. Durable lifecycle evidence is not membership; membership
      # is the ephemeral map, which is the whole reason they are separate.
      Ampd.AuthorityCoordinator.transact(fn ->
        Loci.create_attempt(%{
          "schema" => "carrier-start-ticket@1",
          "ticket_id" => "ct_forged",
          "carrier_ref" => "cr_forged",
          "worker_ref" => ctx.worker["id"],
          "locus_ref" => ctx.lane["id"],
          "state" => "COMMITTED"
        })
      end)

      assert Carrier.status_of(ctx.worker) == "OFFLINE"
      assert Peer.carriers() == []
    end
  end

  # =================================================================== E15
  describe "E15 · the boot sweep never retries and never promotes" do
    test "an in-flight attempt becomes INDETERMINATE", ctx do
      Ampd.AuthorityCoordinator.transact(fn ->
        Loci.create_attempt(%{
          "schema" => "carrier-start-ticket@1",
          "ticket_id" => "ct_inflight",
          "carrier_ref" => "cr_inflight",
          "worker_ref" => ctx.worker["id"],
          "state" => "START_ADMITTED"
        })
      end)

      assert Carrier.recover!() == 1
      assert attempt_state("ct_inflight") == "INDETERMINATE"
      assert Harness.started() == [], "the boot sweep started a process"
      assert Peer.carriers() == [], "the boot sweep promoted an attempt"
    end
  end

  # =================================================================== E16
  describe "E16 · occupancy and execution are different questions" do
    test "OCCUPIED with no Carrier is a legitimate state", ctx do
      assert Worker.occupancy(Peer.resolve(ctx.agent), ctx.lane) == :ok
      assert Worker.status_of(Loci.worker(ctx.worker["id"])) == "OCCUPIED"
      assert Carrier.status_of(ctx.worker) == "OFFLINE"
    end

    test "a Carrier whose Worker generation moved is no longer RUNNING", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert Carrier.status_of(Loci.worker(ctx.worker["id"])) == "RUNNING"

      Ampd.AuthorityCoordinator.transact(fn ->
        Worker.close(ctx.worker["id"])
        Worker.reopen(ctx.worker["id"])
      end)

      # The live map still holds the incarnation — nothing has swept it. The
      # projection must not report RUNNING on that basis alone, or it would be
      # reporting a pid.
      assert Carrier.status_of(Loci.worker(ctx.worker["id"])) == "OFFLINE"
    end
  end

  # =================================================================== E17
  describe "E17 · the embodiment basis is re-derived, not carried" do
    test "a profile change during the machine phase refuses the commit", ctx do
      Harness.put_policy(fn ticket ->
        # The machine the Carrier would run on is not the machine admission
        # measured. `Ampd.Locus`'s four bases already include this one for a
        # capability; a Carrier is a *process on that machine* and has at
        # least as much reason to care.
        Application.put_env(:ampd, :profile_overrides, %{"effector" => "something-else"})
        Ampd.Embodiment.refresh()
        {:ok, Harness.observation(ticket)}
      end)

      on_exit(fn -> Application.delete_env(:ampd, :profile_overrides) end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-profile-basis-changed"
      assert Peer.carriers() == []
      assert length(Harness.terminated()) == 1, "the refused process was not reaped"
    end
  end

  # =================================================================== E18
  describe "E18 · occupancy is the launch authority, and it is re-derived" do
    # There is deliberately **no separate "may start a Carrier" capability**.
    # Occupancy is the authority to run a Carrier at the position you occupy,
    # and inventing a second grant for it would be inventing a capability
    # before anything needs one — the objection three prior slices raised
    # against a new store, applied to the grammar instead.
    #
    # The consequence is testable: losing occupancy during the machine phase
    # must refuse the commit, which is what makes occupancy load-bearing
    # rather than merely checked once at the door.
    test "a Worker reassigned to another Peer mid-flight cannot be committed", ctx do
      Harness.put_policy(fn ticket ->
        # A second live channel for the same actor takes the seat. Under
        # D.1.2's table this displaces nothing by itself, so the first Peer's
        # attachment has to be released first — which is exactly the
        # discontinuity the commit must notice.
        Peer.detach_worker(ctx.agent)
        {:ok, second} = Peer.attach_agent("kestrel")
        {:ok, _} = Worker.attach(Peer.resolve(second), ctx.worker["id"])
        {:ok, Harness.observation(ticket)}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-not-attached"
      assert Peer.carriers() == [], "a displaced Peer committed a Carrier"
      assert length(Harness.terminated()) == 1
    end
  end

  # =================================================================== E19
  describe "E19 · a Carrier is reachable from the wire, not only in-BEAM" do
    # D.1.3a's most expensive finding was that no *deployed* Super could open
    # a Lane at all: `open_lane` needed a repository ref and the only thing
    # that minted one was an in-process function call, so every ExUnit test
    # passed against a door that did not exist. This describes the same class
    # of gap one slice later, and exists so it cannot recur silently.
    test "an occupying agent starts and stops its Carrier by command", ctx do
      r = Control.command(ctx.agent, :start_carrier, [ctx.lane["id"]])
      assert r["allow"] == true, "start_carrier was refused: #{inspect(r["refusal"])}"
      assert r["carrier"]["schema"] == "carrier-incarnation@1"
      assert length(Peer.carriers()) == 1

      s = Control.command(ctx.agent, :stop_carrier, [])
      assert s["allow"] == true
      assert Peer.carriers() == []
    end

    test "a non-occupying agent is refused by the same command", ctx do
      {:ok, stranger} = Peer.attach_agent("kestrel")
      r = Control.command(stranger, :start_carrier, [ctx.lane["id"]])

      assert r["allow"] == false
      assert r["refusal"]["code"] == "carrier-not-attached"
      assert Harness.started() == [], "an unadmitted command reached the machine"
    end

    test "the human control channel cannot start a Carrier", ctx do
      r = Control.command(ctx.control, :start_carrier, [ctx.lane["id"]])
      assert r["allow"] == false
      assert Harness.started() == []
    end
  end

  # =================================================================== E20
  describe "E20 · an unresolved start blocks a second one" do
    # The defect this closes: `in_flight/0` gated on START_ADMITTED alone, so
    # an ambiguous start stopped blocking the moment it was recorded as
    # ambiguous. The one state whose meaning is *a process may be out there*
    # was the state that permitted starting a second one.
    test "INDETERMINATE refuses a second admission for the same Worker", ctx do
      Harness.put_policy(fn _t -> {:error, "no answer"} end)
      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert [a] = Loci.attempts()
      assert a["state"] == "INDETERMINATE"

      Harness.put_policy(fn t -> {:ok, Harness.observation(t)} end)
      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-start-unreconciled"

      # And the machine was never asked a second time.
      assert length(Harness.started()) == 1
      assert Peer.carriers() == []
    end

    test "the wedge is real — nothing clears it on its own", ctx do
      Harness.put_policy(fn _t -> {:error, "no answer"} end)
      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])

      # Three more attempts, all refused, no new attempts recorded.
      for _ <- 1..3 do
        assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
        assert r["code"] == "carrier-start-unreconciled"
      end

      assert length(Loci.attempts()) == 1
      assert length(Harness.started()) == 1
    end
  end

  # =================================================================== E21
  describe "E21 · reconciliation establishes absence, it does not relabel" do
    test "a confirmed stop resolves the attempt and unblocks admission", ctx do
      Harness.put_policy(fn _t -> {:error, "no answer"} end)
      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      [a] = Loci.attempts()

      Harness.put_policy(fn t -> {:ok, Harness.observation(t)} end)
      Carrier.reconcile(a["ticket_id"])

      assert attempt_state(a["ticket_id"]) == "RESOLVED"
      # The host was asked to make it absent, not merely told about it.
      assert a["carrier_ref"] in Harness.terminated()

      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
    end

    test "an ambiguous stop leaves the attempt unresolved and still blocking", ctx do
      Harness.put_policy(fn _t -> {:error, "no answer"} end)
      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      [a] = Loci.attempts()

      Harness.stop_returns({:error, "the host did not answer"})
      assert {:refused, r} = Carrier.reconcile(a["ticket_id"])
      assert r["code"] == "carrier-reconcile-indeterminate"

      assert attempt_state(a["ticket_id"]) == "INDETERMINATE"
      assert {:refused, r2} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r2["code"] == "carrier-start-unreconciled"
    end

    test "reconciliation is human control and not reachable by the agent", ctx do
      Harness.put_policy(fn _t -> {:error, "no answer"} end)
      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      [a] = Loci.attempts()

      r = Control.command(ctx.agent, :reconcile_carrier_attempt, [a["ticket_id"]])
      assert r["allow"] == false

      ok = Control.command(ctx.control, :reconcile_carrier_attempt, [a["ticket_id"]])
      assert ok["allow"] == true
    end
  end

  # =================================================================== E22
  describe "E22 · a stop whose outcome is unknown is not a stop" do
    test "an unconfirmed stop blocks replacement until reconciled", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      Harness.stop_returns({:error, "the host did not answer"})

      assert {:indeterminate, _} = Carrier.stop(ctx.agent)

      # Membership is gone — the runtime has decided this is not its Carrier.
      assert Peer.carriers() == []
      # But a replacement is refused, because the process may still exist.
      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-start-unreconciled"
    end

    test "a confirmed stop permits replacement immediately", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert Carrier.stop(ctx.agent) == :ok
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
    end
  end

  # =================================================================== E23
  describe "E23 · losing the Peer terminates the process, not only the record" do
    test "a dropped Peer causes a reap request to the machine", ctx do
      assert {:ok, inc} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert Harness.terminated() == []

      Peer.detach(ctx.agent)
      :ok = Ampd.Carrier.Reaper.drain()

      # Membership ended AND the machine was asked to make the process absent.
      # The old E13 asserted only the first, and passed while the OS process
      # kept running — the two are different events.
      assert Peer.carriers() == []
      assert inc["carrier_ref"] in Harness.terminated(),
             "the process was orphaned: membership ended and nothing reaped it"
    end

    test "an unconfirmed orphan reap records an unresolved attempt", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      Harness.stop_returns({:error, "the host did not answer"})

      Peer.detach(ctx.agent)
      :ok = Ampd.Carrier.Reaper.drain()

      assert Enum.any?(Loci.attempts(), &(&1["state"] == "INDETERMINATE")),
             "an unconfirmed orphan reap left no record that a process may exist"
    end
  end

  # =================================================================== E24
  describe "E24 · the confinement floor is required in full" do
    # The defect: the commit predicate checked no_new_privs, seccomp and the
    # descriptor set — and NOT Landlock. A process with no filesystem
    # confinement at all satisfied the check that b·1 existed to make
    # meaningful. Each row below is sabotaged independently.
    for {label, path, value} <- [
          {"landlock absent", ["attested", "landlock_handled_fs"], "0x0"},
          {"landlock abi unreported", ["attested", "landlock_abi"], nil},
          {"network not none", ["attested", "network"], "tcp"},
          {"parent death not bound", ["attested", "pdeathsig"], "none"},
          {"refusal not attributable", ["attested", "seccomp_deny_errno"], 1},
          {"attestor is not the host", ["attested", "attestor"], "someone-else"},
          {"environment not exact", ["observed", "env_keys"], ["PATH"]},
          {"stdin is not null", ["observed", "fds"], %{"0" => "/etc/passwd", "1" => "l", "2" => "l", "3" => "socket:[1]"}}
        ] do
      test "a Carrier cannot commit with #{label}", ctx do
        path = unquote(Macro.escape(path))
        value = unquote(Macro.escape(value))

        Harness.put_policy(fn t -> {:ok, put_in(Harness.observation(t), path, value)} end)

        assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
        assert r["code"] == "carrier-confinement-unacceptable"
        assert Peer.carriers() == []
        assert length(Harness.terminated()) == 1, "the refused process was not reaped"
      end
    end

    test "the floor names which rows failed, not merely that it failed", ctx do
      Harness.put_policy(fn t ->
        {:ok, put_in(Harness.observation(t), ["attested", "landlock_handled_fs"], "0x0")}
      end)

      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      [a] = Loci.attempts()
      assert is_list(a["floor_failures"])
      assert "attested:landlock_governs_filesystem" in a["floor_failures"]
    end

    test "changing the floor invalidates an admission taken under the old one", _ctx do
      # The floor digest is derived from the row NAMES, so adding or removing
      # a requirement moves it. A ticket admitted under the old digest then
      # cannot commit — `carrier-floor-basis-changed` — rather than being
      # silently judged by a rule it was not admitted under.
      d = Ampd.Carrier.Floor.digest()
      assert is_binary(d) and byte_size(d) > 8
      assert d == Ampd.Carrier.Floor.digest(), "the floor digest is not stable"

      names = Enum.map(Ampd.Carrier.Floor.rows(), fn {_, n, _} -> n end)
      assert "no_new_privs" in names
      assert "descriptor_set_exact" in names

      att = Enum.map(Ampd.Carrier.Floor.attested_rows(), fn {_, n, _} -> n end)
      assert "landlock_governs_filesystem" in att,
             "the floor does not require Landlock, which is the defect this closure exists to fix"
    end
  end

  # =================================================================== E25
  describe "E25 · the machine channel has exactly one submitter" do
    test "concurrent starts are serialized and each gets its own observation", ctx do
      # A second Worker at a second Locus, so two admissions are legitimately
      # concurrent rather than racing the same seat.
      lane2 = ok!(Control.command(ctx.control, :open_lane, [ctx.goal["id"], "kestrel", ctx.repo_ref, nil]), "lane")
      {:ok, agent2} = Peer.attach_agent("kestrel")
      w2 = ok!(Control.command(ctx.control, :open_worker, [lane2["id"], "second"]), "worker")
      ok!(Control.command(agent2, :attach_worker, [w2["id"]]), "worker")

      # The harness answers slowly, so the two machine phases overlap in
      # wall-clock unless something serializes them.
      Harness.put_policy(fn t ->
        Process.sleep(120)
        {:ok, Harness.observation(t)}
      end)

      tasks =
        for {p, l} <- [{ctx.agent, ctx.lane["id"]}, {agent2, lane2["id"]}] do
          Task.async(fn -> Carrier.start(p, l) end)
        end

      results = Task.await_many(tasks, 20_000)

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "a concurrent start failed: #{inspect(results)}"

      [{:ok, a}, {:ok, b}] = results
      refute a["carrier_ref"] == b["carrier_ref"]
      assert length(Peer.carriers()) == 2
      assert length(Harness.started()) == 2
    end
  end
end
