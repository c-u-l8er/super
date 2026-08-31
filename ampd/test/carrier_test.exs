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

    # The resets above minted a fresh peer epoch, which fences the Gate until
    # it has established the physical carrier set empty under the new one.
    # Convergence is asynchronous in production — it is a recovery, not a
    # request path — so a test that wants to observe the settled state needs
    # the barrier, exactly as it needs `Reaper.drain/1`.
    Ampd.Carrier.Machine.Gate.sync()

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

      # **This used to be `carrier-start-indeterminate`, and the change is the
      # property getting stronger rather than moving.**
      #
      # Before D.1.3b·2c the admission had nothing to bind, so it succeeded,
      # wrote a durable attempt, asked a machine that had no channel, and came
      # back INDETERMINATE — which wedges the Worker until a person
      # reconciles it, over a runtime that was never able to start anything.
      # Now the basis is a term of the admission, so a runtime that cannot say
      # which Carrier implementation it is admitting does not admit one.
      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-execution-basis-unavailable"
      assert Peer.carriers() == []

      # And no wedge: refusing before the ticket means there is nothing to
      # reconcile. This is the `E1` property — a refusal reaches no machine —
      # holding for a new refusal reason.
      assert Loci.attempts() == []
      assert Harness.started() == []
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

  # =================================================================== E26
  #
  # The defect this closes, in review's words:
  #
  #     `payload_digest` appears only in the host's post-spawn attestation.
  #     Therefore this claim is currently false: an implementation admitted
  #     as A cannot silently become B before commit.
  #
  # The ticket bound `profile_basis` and `floor_basis` and nothing that said
  # *what would be run*. The floor's `payload_is_the_attested_bytes` row read
  # like the missing check and established only that the host had produced a
  # SHA-shaped string — a fact about the host's output format.
  describe "E26 · the Carrier execution identity is bound at admission" do
    test "a payload that changed between admission and commit cannot join", ctx do
      # Admitted under basis A; the machine runs something whose execution
      # basis is B. Everything else — profile, floor, occupancy, epochs — is
      # untouched, so this is the payload swap in isolation.
      b = %{Harness.default_basis() | "payload_digest" => "sha256:" <> String.duplicate("cd", 32)}

      Harness.put_policy(fn t ->
        obs = Harness.observation(t)
        {:ok, put_in(obs, ["attested", "execution_basis"], b)}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-execution-basis-changed"

      # Refused, and reaped: the process may well have started — that is the
      # whole reason the machine phase is outside the order — and the point is
      # that it does not become a Carrier, not that it never ran.
      assert Peer.carriers() == []
      assert length(Harness.terminated()) == 1, "the swapped payload was not reaped"

      # And the refusal names which field moved, not merely that something did.
      assert r["operator_detail"]["basis_moved"] == ["payload_digest"]
    end

    test "restoring the admitted payload lets a fresh admission succeed", ctx do
      b = %{Harness.default_basis() | "payload_digest" => "sha256:" <> String.duplicate("cd", 32)}
      Harness.put_policy(fn t -> {:ok, put_in(Harness.observation(t), ["attested", "execution_basis"], b)} end)
      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])

      # The refused attempt is terminal — STALE, not INDETERMINATE — because
      # the commit *knows* what happened. So it does not wedge the Worker and
      # a re-admission under the restored payload is admitted normally.
      Harness.put_policy(fn t -> {:ok, Harness.observation(t)} end)
      assert {:ok, inc} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert inc["status"] == "RUNNING"
    end

    test "a protocol version change is a discontinuity too", ctx do
      b = %{Harness.default_basis() | "carrier_protocol_version" => 2}
      Harness.put_policy(fn t -> {:ok, put_in(Harness.observation(t), ["attested", "execution_basis"], b)} end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-execution-basis-changed"
      assert r["operator_detail"]["basis_moved"] == ["carrier_protocol_version"]
    end

    test "an observation carrying no execution basis at all is refused", ctx do
      # The direction that matters: absent must never read as agreement. A
      # comparison that skipped when one side was missing would be a
      # comparison a host could opt out of by omitting a field.
      Harness.put_policy(fn t ->
        obs = Harness.observation(t)
        {:ok, put_in(obs, ["attested"], Map.delete(obs["attested"], "execution_basis"))}
      end)

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-execution-basis-changed"
      assert r["operator_detail"]["basis_moved"] == ["actual-basis-absent"]
      assert Peer.carriers() == []
    end

    test "the basis question submits nothing to the machine", _ctx do
      # It reads channel metadata. If it took a machine round trip it would be
      # machine latency inside the total order, which is the one thing the
      # admit/machine/commit shape exists to keep out — and `Ampd.Carrier`
      # calls it from inside `AuthorityCoordinator.transact/1`.
      assert {:ok, _} = Harness.execution_basis()
      assert Harness.started() == []
      assert Harness.terminated() == []
    end

    test "a machine that cannot state a basis admits nothing", ctx do
      Harness.put_basis({:error, "the host has not said what it would run"})

      assert {:refused, r} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert r["code"] == "carrier-execution-basis-unavailable"
      assert Loci.attempts() == [], "an admission was recorded with nothing bound"
      assert Harness.started() == []
    end
  end

  # =================================================================== E27
  #
  # The TCB race review found in the new reaper architecture: every caller
  # announces under `if Process.whereis(Reaper)`, so a Peer lost while the
  # supervisor is between restarts removes the membership and loses the
  # announcement — a live process with nothing referring to it.
  describe "E27 · a lost reap announcement survives a Reaper restart" do
    test "a Carrier orphaned while the Reaper is down is still reaped", ctx do
      assert {:ok, inc} = Carrier.start(ctx.agent, ctx.lane["id"])

      # Deterministically down, rather than killed and raced against the
      # supervisor: `Process.whereis` must be nil at the instant the Peer is
      # lost, and a `Process.exit` would be restarted in microseconds.
      :ok = Supervisor.terminate_child(Ampd.Supervisor, Ampd.Carrier.Reaper)
      assert Process.whereis(Ampd.Carrier.Reaper) == nil

      Peer.detach(ctx.agent)

      # The hole is real: membership ended and nothing reaped it.
      assert Peer.carriers() == []
      assert Harness.terminated() == [], "something reaped it while the reaper was down"

      # But the debt was recorded where a restart can find it.
      assert Enum.any?(Peer.pending_reaps(), &(&1["carrier_ref"] == inc["carrier_ref"]))

      {:ok, _} = Supervisor.restart_child(Ampd.Supervisor, Ampd.Carrier.Reaper)
      :ok = Ampd.Carrier.Reaper.drain()

      assert inc["carrier_ref"] in Harness.terminated(),
             "the restarted reaper did not converge a Carrier orphaned during its downtime"

      # And the debt is discharged, so a second restart does not re-reap it.
      assert Peer.pending_reaps() == []
    end

    test "an orphan the Reaper could not confirm is settled, not swept forever", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      Harness.stop_returns({:error, "the host did not answer"})

      Peer.detach(ctx.agent)
      :ok = Ampd.Carrier.Reaper.drain()

      # An unresolved attempt exists — that is what blocks replacement — and
      # the pending entry is gone, because the announcement was heard. The
      # debt exists to survive a *lost* announcement and not to outlive a
      # delivered one.
      assert Enum.any?(Loci.attempts(), &(&1["state"] == "INDETERMINATE"))
      assert Peer.pending_reaps() == []
    end

    test "an unconfirmed orphan reap blocks the replacement it should block", ctx do
      # E23 proved the attempt gets recorded and stopped there. The
      # load-bearing consequence is the refusal of a second process for the
      # same Worker, which nothing asserted.
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      Harness.stop_returns({:error, "the host did not answer"})

      Peer.detach(ctx.agent)
      :ok = Ampd.Carrier.Reaper.drain()

      {:ok, agent2} = Peer.attach_agent("kestrel")
      ok!(Control.command(agent2, :attach_worker, [ctx.worker["id"]]), "worker")

      Harness.stop_returns(:ok)
      assert {:refused, r} = Carrier.start(agent2, ctx.lane["id"])
      assert r["code"] == "carrier-start-unreconciled"
    end
  end

  # =================================================================== E28
  #
  # A public schema vocabulary that disagrees with the durable records is a
  # reader being told to trust the wrong list. `reconcile/1` has always
  # written RESOLVED and `attempt_states/0` has never named it.
  describe "E28 · the declared vocabularies match what is written" do
    test "every state the module writes is in the declared vocabulary", ctx do
      # Driven, not asserted against a literal list: a list checked against
      # itself proves the list is spelled the way it is spelled. These four
      # scenarios are the ones that write a state to disk.
      Harness.put_policy(fn _t -> {:error, "no answer"} end)
      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      [ind] = Loci.attempts()
      assert ind["state"] == "INDETERMINATE"

      Harness.put_policy(fn t -> {:ok, Harness.observation(t)} end)
      Carrier.reconcile(ind["ticket_id"])
      assert attempt_state(ind["ticket_id"]) == "RESOLVED"

      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert Carrier.stop(ctx.agent) == :ok

      Harness.put_policy(fn t ->
        {:ok, put_in(Harness.observation(t), ["observed", "no_new_privs"], false)}
      end)

      assert {:refused, _} = Carrier.start(ctx.agent, ctx.lane["id"])

      written = Loci.attempts() |> Enum.map(& &1["state"]) |> Enum.uniq() |> Enum.sort()
      assert written != []

      for s <- written do
        assert s in Carrier.attempt_states(),
               "#{s} is written to durable records and is not in attempt_states/0"
      end

      # Both directions. RESOLVED and FAILED are the two this run must have
      # produced, and RESOLVED is the one that was missing from the list.
      assert "RESOLVED" in written
      assert "FAILED" in written
      assert "RESOLVED" in Carrier.attempt_states()
    end

    test "reconcile's terminal set and the vocabulary do not disagree", _ctx do
      # `reconcile/1` short-circuits on a state it considers already settled.
      # Every name in that guard must be a name the vocabulary declares, or
      # the guard is matching on a state that cannot occur.
      for s <- ~w(COMMITTED STALE FAILED RESOLVED) do
        assert s in Carrier.attempt_states()
      end
    end

    test "the confinement floor version is an exact constant", _ctx do
      # The digest derives from the version and the row NAMES and cannot see a
      # function body, so a row rewritten in place would keep its digest and
      # an in-flight admission would commit under a rule it was not admitted
      # under. The version is the only thing that can carry that — so this
      # asserts it exactly, and changing a row's meaning has to come here.
      assert Ampd.Carrier.Floor.version() == 2
      assert Ampd.Carrier.Floor.schema() == "carrier-confinement-floor@1"

      names =
        (Ampd.Carrier.Floor.rows() ++
           Ampd.Carrier.Floor.attested_rows() ++ Ampd.Carrier.Floor.correspondence_rows())
        |> Enum.map(fn {_, n, _} -> n end)

      assert length(names) == 20
      assert length(Enum.uniq(names)) == 20, "two floor rows share a name, so one cannot be reported"

      # v2's exercise of the rule: the row that claimed to bind the payload
      # and did not is gone, and the one that replaced it is attested rather
      # than correspondence, because it reads only the attestation.
      refute "payload_is_the_attested_bytes" in names
      assert "execution_basis_is_well_formed" in names

      att = Enum.map(Ampd.Carrier.Floor.attested_rows(), fn {_, n, _} -> n end)
      assert "execution_basis_is_well_formed" in att
    end

    test "the declared basis field set is what the comparison actually uses", _ctx do
      assert Carrier.basis_fields() ==
               ~w(schema payload_digest carrier_protocol carrier_protocol_version)

      # Every declared field must be one a discontinuity can move, or the
      # comparison is wider on paper than in fact. Driven, not asserted.
      for f <- Carrier.basis_fields() do
        moved = Map.put(Harness.default_basis(), f, "moved")
        obs = put_in(Harness.observation(%{}), ["attested", "execution_basis"], moved)

        assert Carrier.basis_moved(%{"carrier_basis" => Harness.default_basis()}, obs) == [f],
               "#{f} is declared bound and moving it changes nothing"
      end
    end

    test "the floor refuses a basis-shaped placeholder", _ctx do
      # What the old row accepted: 32-plus bytes after an optional prefix. The
      # replacement requires the full object and 64 hex characters, so the
      # value a hand-written attestation reaches for no longer passes.
      for bad <- [
            %{"schema" => "carrier-execution-basis@1", "payload_digest" => String.duplicate("a", 40)},
            %{"schema" => "carrier-execution-basis@1", "payload_digest" => "sha256:" <> String.duplicate("z", 64),
              "carrier_protocol" => "carrier-lifecycle", "carrier_protocol_version" => 1},
            %{"payload_digest" => "sha256:" <> String.duplicate("ab", 32)},
            "sha256:" <> String.duplicate("ab", 32)
          ] do
        obs = put_in(Harness.observation(%{}), ["attested", "execution_basis"], bad)

        assert {:error, rows} = Ampd.Carrier.Floor.verify(obs)

        assert "attested:execution_basis_is_well_formed" in rows,
               "the floor accepted #{inspect(bad)} as an execution basis"
      end
    end
  end

  # =================================================================== E29
  #
  # **This falsifier was written the other way up one round ago.**
  #
  # It recorded the seam: `Ampd.Carrier`'s moduledoc claimed a supervisor
  # restart made the host reap, measurement said it did not, and E29 asserted
  # the leak so the docstring could not quietly re-acquire the claim. Review
  # ruled that a BLOCKER — a Carrier may not physically outlive the runtime
  # incarnation whose semantic membership admitted it, and a PTY turns the
  # three-word fixture into exactly the process that must not become
  # semantically ownerless.
  #
  # So it is flipped, not deleted. What was `refute` is now the invariant.
  describe "E29 · a Peer incarnation cannot leave a Carrier behind" do
    test "killing the peer registry fences the machine and drains the set", ctx do
      assert {:ok, _inc} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert length(Peer.carriers()) == 1
      before = length(Harness.drained())

      old_epoch = Peer.epoch()
      kill_peer!()

      # **Converges on its own.** No `Gate.sync()` here: the recovery is
      # asynchronous by design, and a test that forced it would be proving
      # the barrier works rather than the recovery.
      assert {:ready, new_epoch} = await_ready(old_epoch)

      refute new_epoch == old_epoch,
             "the peer registry came back with the epoch that died, so nothing was invalidated"

      assert length(Harness.drained()) > before,
             "the machine was never asked to establish an empty physical carrier set"

      assert new_epoch in Harness.drained(),
             "the drain did not name the incarnation it was synchronizing to"

      # Membership is gone, and so is the physical set — which is the half
      # that was missing.
      assert Peer.carriers() == []

      # And the position is untouched. This is a control-plane incarnation
      # discontinuity, not a World reboot: the Worker and the Locus are in
      # dets and Ampd.Peer has never been able to reach them.
      assert Loci.worker(ctx.worker["id"])["status"] == "open"
      assert Loci.lane(ctx.lane["id"]) != nil
    end

    test "a fresh epoch with no death fences too", ctx do
      # `Peer.reset/0` re-mints identity in place — a world reset, a lineage
      # advance — so no `:DOWN` fires and a monitor cannot see it. The Gate
      # would otherwise stay bound to an epoch no handle carries.
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      before = length(Harness.drained())
      old = Peer.epoch()

      Peer.reset()

      assert {:ready, new} = await_ready(old)
      refute new == old
      assert length(Harness.drained()) > before
    end

    test "a start during the fence is refused before any ticket exists", ctx do
      # J4. The window is a recovery, not an outage to be papered over: an
      # admission that wrote START_ADMITTED and then met a fenced Gate would
      # come back INDETERMINATE and wedge its Worker — a reconciliation
      # requirement manufactured by the runtime's own restart.
      Harness.drain_fails(50)
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      attempts_before = length(Loci.attempts())
      started_before = length(Harness.started())

      kill_peer!()
      await_peer!()

      # Still fenced — the drain cannot confirm.
      assert {:fenced, _} = Ampd.Carrier.Machine.Gate.readiness()

      {:ok, agent2} = Peer.attach_agent("kestrel")
      r2 = Control.command(agent2, :attach_worker, [ctx.worker["id"]])
      assert r2["allow"] == true

      assert {:refused, r} = Carrier.start(agent2, ctx.lane["id"])
      assert r["code"] == "carrier-runtime-incarnation-unready"

      assert length(Loci.attempts()) == attempts_before,
             "a durable attempt was written while the machine was fenced"

      assert length(Harness.started()) == started_before,
             "a start reached the machine while it was fenced"
    end

    test "a lost drain confirmation keeps the fence up and is retried", ctx do
      # J3. The host really emptied its set and the answer went missing. From
      # the runtime's side that is indistinguishable from a refusal, so the
      # fence stays up — and unlike a start, this request may be retried,
      # because it carries no actor, Locus, Worker or grant and can only
      # subtract.
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      Harness.drain_fails(2)
      before = length(Harness.drained())

      old = Peer.epoch()
      kill_peer!()

      assert {:ready, _} = await_ready(old),
             "the fence never lifted, so a lost confirmation is a permanent outage"

      assert length(Harness.drained()) >= before + 3,
             "the drain was not retried after its confirmation was lost"
    end

    test "one drain answers for every Carrier the registry was holding", ctx do
      # J5. `Ampd.Peer` dying loses every semantic membership at once, so
      # there are no victims left to name. `terminate_all` is not a blunt
      # instrument here — reconstructing victim IDs from records that
      # deliberately no longer exist is the thing that cannot be done.
      lane2 = ok!(Control.command(ctx.control, :open_lane, [ctx.goal["id"], "kestrel", ctx.repo_ref, nil]), "lane")
      {:ok, agent2} = Peer.attach_agent("kestrel")
      w2 = ok!(Control.command(ctx.control, :open_worker, [lane2["id"], "second"]), "worker")
      ok!(Control.command(agent2, :attach_worker, [w2["id"]]), "worker")

      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      assert {:ok, _} = Carrier.start(agent2, lane2["id"])
      assert length(Peer.carriers()) == 2

      before = length(Harness.drained())
      old = Peer.epoch()
      kill_peer!()
      assert {:ready, _} = await_ready(old)

      assert Peer.carriers() == []

      # ONE drain, not one per Carrier. The request names no carrier_ref.
      assert length(Harness.drained()) == before + 1,
             "the fence issued a drain per Carrier rather than emptying the set"
    end
  end

  # =================================================================== E30
  #
  # **The epoch is a token; the transition is a fact. E29 proves the fact
  # follows from the token, and that is the weaker direction.**
  #
  # Every assertion in E29 above turns on `refute new_epoch == old_epoch` —
  # it establishes that a *randomly different* identifier produces a drain.
  # Review's objection: `Ampd.Peer.new_epoch/0` minted thirty-two random
  # bits, and `converge/1` decided drainage by comparing them, so an actual
  # discontinuity could be represented as equality:
  #
  #     P1 epoch = X · P1 dies · P2 mints X  ⟹  identifier says P1 == P2
  #
  # while the `:DOWN` said otherwise. The published claim — "a Carrier's
  # physical lifetime cannot outlive the current runtime/Peer incarnation" —
  # is absolute, so a *small* probability of misrepresenting the fence is a
  # defect in it rather than an acceptable rate.
  #
  # Two repairs shipped, and these tests separate them on purpose:
  #
  #   · the epoch widened to 128 bits, which shrinks the residue that has no
  #     witness (a Gate restarted across the transition) to nothing;
  #   · `converge/1` reads `witnessed` *before* the published term, so a
  #     transition this process was told about is never re-derived from the
  #     accidental inequality of a random number.
  #
  # These falsify the second. A test that waited for a natural collision
  # would not be a test, so minting is pinned — `Ampd.Peer.mint_epoch/0` has
  # a `:test`-only clause, compiled out everywhere else and asserted absent
  # by `tools/verify.sh`.
  describe "E30 · a witnessed discontinuity fences even when the token collides" do
    setup do
      on_exit(fn -> :persistent_term.erase({Ampd.Peer, :forced_epoch}) end)
      :ok
    end

    test "a Peer death whose replacement mints the epoch that died still drains", ctx do
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      before = length(Harness.drained())

      old = Peer.epoch()
      :persistent_term.put({Ampd.Peer, :forced_epoch}, old)

      # **Suspended so that the `:DOWN` is processed against a Peer that is
      # back**, which is what makes this a falsifier rather than a coin
      # toss. Without the suspend the Gate races the supervisor: if it
      # converges while `Ampd.Peer` is still down it takes the
      # `Process.whereis/1 == nil` branch, publishes `{:fenced, nil}` for
      # boot-ordering reasons, and reaches the drain on the retry *whether
      # or not* the repair is present. The probe would then score NOT A
      # FALSIFIER on some runs and `falsified` on others, which is worse
      # than either.
      :sys.suspend(Ampd.Carrier.Machine.Gate)
      kill_peer!()
      await_peer!()

      # **The test is vacuous unless the collision actually happened**, so
      # this is asserted rather than assumed. It is the exact inverse of
      # E29's `refute` — same event, the identifier landing the other way.
      assert Peer.epoch() == old,
             "the collision was not reproduced, so this proves only what E29 already proves"

      # The queued `:DOWN` is delivered now, into a world where the registry
      # is alive and answering with the epoch that died. Nothing but the
      # published record of the transition distinguishes this from normality.
      :sys.resume(Ampd.Carrier.Machine.Gate)

      await_drained(before)
      assert {:ready, ^old} = await_readiness({:ready, old})
      assert old in Harness.drained()
      assert Peer.carriers() == []
    end

    test "an in-place reset to the same epoch still drains", ctx do
      # The `Peer.reset/0` half. No `:DOWN` fires here — the notification is
      # the only evidence there is — so this is the path where discarding it
      # in favour of the token leaves nothing at all.
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      before = length(Harness.drained())

      old = Peer.epoch()
      :persistent_term.put({Ampd.Peer, :forced_epoch}, old)

      Peer.reset()
      assert Peer.epoch() == old, "the collision was not reproduced"

      await_drained(before)
      assert {:ready, ^old} = await_readiness({:ready, old})
    end

    test "no start reaches the old physical set before it is drained", ctx do
      # The consequence the fence exists for, under collision. The drain is
      # held open so the window is observable rather than raced for.
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      Harness.drain_fails(50)
      attempts_before = length(Loci.attempts())
      started_before = length(Harness.started())

      old = Peer.epoch()
      :persistent_term.put({Ampd.Peer, :forced_epoch}, old)
      kill_peer!()
      await_peer!()
      assert Peer.epoch() == old, "the collision was not reproduced"

      # Without the fix this reads `{:ready, old}`: the published term and the
      # replacement's epoch are the same string, so nothing looked changed.
      assert {:fenced, _} = Ampd.Carrier.Machine.Gate.readiness()

      {:ok, agent2} = Peer.attach_agent("kestrel")
      assert Control.command(agent2, :attach_worker, [ctx.worker["id"]])["allow"] == true

      assert {:refused, r} = Carrier.start(agent2, ctx.lane["id"])
      assert r["code"] == "carrier-runtime-incarnation-unready"

      assert length(Loci.attempts()) == attempts_before,
             "a durable attempt was written into an incarnation that is being left"

      assert length(Harness.started()) == started_before,
             "a start reached the old physical set before it was established empty"
    end

    test "the fence is not manufactured out of this process's own restart", ctx do
      # The other side of the same edit, and the regression it could
      # reintroduce. `witnessed` must be false in a fresh Gate: a `:fenced`
      # starting state cost a whole `verify` run once, because this process
      # boots before `Ampd.Bridge` and no drain can succeed with no channel
      # possessed. A Gate restart under an unchanged Peer must go straight to
      # ready and ask the machine for nothing.
      assert {:ok, _} = Carrier.start(ctx.agent, ctx.lane["id"])
      epoch = Peer.epoch()
      before = length(Harness.drained())

      pid = Process.whereis(Ampd.Carrier.Machine.Gate)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}, 2_000

      # `sync/0` and not a poll on `readiness/0`: the published term outlives
      # the process, so polling it would return the pre-kill value and
      # measure nothing.
      assert {:ready, ^epoch} = await_gate_sync()

      assert length(Harness.drained()) == before,
             "a Gate restart drained a set that no discontinuity had left behind"
    end
  end

  # ------------------------------------------------------------- fence helpers
  defp kill_peer! do
    pid = Process.whereis(Ampd.Peer)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      2_000 -> flunk("Ampd.Peer did not die")
    end
  end

  defp await_peer!(n \\ 200) do
    Enum.reduce_while(1..n, nil, fn _, _ ->
      if is_pid(Process.whereis(Ampd.Peer)), do: {:halt, :ok}, else: (Process.sleep(20); {:cont, nil})
    end) || flunk("Ampd.Peer never came back")

    Process.sleep(50)
  end

  # **Waits for readiness under a DIFFERENT incarnation.**
  #
  # Polling for `{:ready, _}` returns instantly on the state published before
  # the kill — the Gate has not processed the `:DOWN` yet — so the first
  # version of this helper measured nothing and three tests failed for that
  # reason rather than for the reason they name. Convergence is a transition,
  # so the barrier has to be one too.
  defp await_ready(was, n \\ 400) do
    Enum.reduce_while(1..n, nil, fn _, _ ->
      case Ampd.Carrier.Machine.Gate.readiness() do
        {:ready, e} when e != was -> {:halt, {:ready, e}}
        _ -> Process.sleep(25); {:cont, nil}
      end
    end) ||
      flunk(
        "the gate never unfenced under a new incarnation " <>
          "(was #{inspect(was)}, now #{inspect(Ampd.Carrier.Machine.Gate.readiness())})"
      )
  end

  # **The barrier E30 needs, and why `await_ready/2` cannot be it.**
  #
  # Every barrier above is spelled "wait until the epoch is not the one that
  # died". Under a collision the epoch converged to is spelled exactly like
  # the one that died, so that helper returns on the state published *before*
  # the kill and measures nothing — the same trap its own docstring records,
  # arriving by a different road. The drain count is monotone, is incremented
  # by the harness before it decides whether to answer, and does not mention
  # the identifier under test.
  defp await_drained(before, n \\ 400) do
    Enum.reduce_while(1..n, nil, fn _, _ ->
      if length(Harness.drained()) > before do
        {:halt, :ok}
      else
        Process.sleep(25)
        {:cont, nil}
      end
    end) ||
      flunk(
        "the machine was never asked to empty the physical set — the fence was decided by " <>
          "comparing epochs and the replacement minted the one that died (drains still #{before})"
      )
  end

  defp await_readiness(target, n \\ 400) do
    Enum.reduce_while(1..n, nil, fn _, _ ->
      case Ampd.Carrier.Machine.Gate.readiness() do
        ^target -> {:halt, target}
        _ -> Process.sleep(25); {:cont, nil}
      end
    end) ||
      flunk(
        "the gate never reached #{inspect(target)} " <>
          "(now #{inspect(Ampd.Carrier.Machine.Gate.readiness())})"
      )
  end

  defp await_gate_sync(n \\ 200) do
    Enum.reduce_while(1..n, nil, fn _, _ ->
      case Process.whereis(Ampd.Carrier.Machine.Gate) do
        nil -> Process.sleep(20); {:cont, nil}
        _ -> {:halt, Ampd.Carrier.Machine.Gate.sync()}
      end
    end) || flunk("the carrier machine gate never came back")
  end
end
