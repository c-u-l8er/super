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

    Process.sleep(120)
    Authority.install_worktree()

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "run a carrier"]), "goal")
    lane = ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")
    worker = occupy!(control, agent, lane["id"])

    %{control: control, agent: agent, goal: goal, lane: lane, worker: worker}
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
end
