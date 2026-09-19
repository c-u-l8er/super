Code.require_file("../../tools/hypersurface/node_executor.exs", __DIR__)
Code.require_file("../../tools/hypersurface/reducer_bridge.exs", __DIR__)
Code.require_file("../../tools/hypersurface/resident_executor.exs", __DIR__)

defmodule Ampd.B2TrvmReduceTest do
  @moduledoc """
  The vertical witness — one supported WRL computation carried through the B2
  write boundary on the REAL substrate: the `trvm.reduce` capability, a one-shot
  grant, the managed-Node executor over the checked Wasm host, the journal, the
  lease, the ticketed receipt, and an INDEPENDENT reference comparison
  (`wek/b2/NEXT_COMPUTATION_PROPOSAL.md`, revision 2).

  The computation is epoch 1 of the sealed world `pulser → 30 relays → door`
  (`sem-ffe90cdd…`, 8,850 B term, 476 interactions). Its reference identities
  are read from `wek/b2/compute/nf_identities.json` (the exact payload bytes and
  their sha256, measured by `ic32`, `ic_ref` and the checked host agreeing) and
  Forge's Film v0.7 for the receipted payload is computed by
  `wek/b2/compute/film_of_payload.py` against the frozen `08d6318a…f3f`.

  Every case asserts the substrate directly, declares the HARNESS's expectation
  of the trace as a literal, and exports `<case>.trace.json` + `<case>.case.json`
  for the unmodified WEK verifier, exactly as `b2_write_boundary_test.exs` does.
  Result honesty is owned by the reference comparison and by nothing else:
  under the `no-reference-assert` control (`B2_NO_REFERENCE_ASSERT=1`) the
  comparison accepts everything and falsifier F-D is the ONE case that changes
  verdict.

  Requires HS_TRVM_HOST and MANAGED_OUTPUT_DIR, like the managed-node tests.
  """
  use ExUnit.Case, async: false

  alias Ampd.{
    Authority,
    Bridge,
    Control,
    Effects,
    Gateway,
    GrantRegistry,
    Loci,
    Peer,
    Receipts,
    TrvmReduce
  }

  alias Ampd.Carrier.Machine.Harness
  alias Ampd.Effects.Witness
  alias HyperSurface.ReducerBridge, as: Reducer

  @moduletag skip:
               is_nil(System.get_env("HS_TRVM_HOST")) or
                 is_nil(System.get_env("MANAGED_OUTPUT_DIR"))

  @cap "trvm.reduce"
  @resource "trvm/chain30"
  @world "chain30-epoch-1"
  @control_world "corpus-exp_2p16"
  @sem "sem-ffe90cdd6e75d6f692053fbfbe6c7139dd7496bc0aa6e278e9e5bd05fe911127"
  @scenario_digest "scen-2be578f63401d0a424be78f069cc81278efcb3469ae405ec66a2a340c26b8842"
  @film_epoch1 "08d6318a20c4c830c4670730bb66cab1190452dfa3dc6385e75f3ff54f317f3f"
  @compute System.get_env("B2_COMPUTE_DIR") || "/home/travis/ProjectAmp2/wek/b2/compute"

  # --------------------------------------------------------- reference identities
  defp identities, do: JSON.decode!(File.read!(Path.join(@compute, "nf_identities.json")))
  defp term(name), do: File.read!(Path.join([@compute, "terms", name <> ".ic"]))
  defp reference(name), do: identities()[name]

  defp params(name) do
    ref = reference(name)

    %{
      "sem" => @sem,
      "scenario_digest" => @scenario_digest,
      "epoch" => 1,
      "term_sha256" => ref["term_sha256"],
      "term_bytes" => ref["term_bytes"]
    }
  end

  defp req(name), do: %{"er" => "er-trvm.reduce", "rev" => 1, "params" => params(name)}

  # ------------------------------------------------------------- evidence
  setup_all do
    dir =
      System.get_env("B2_EVIDENCE_DIR") ||
        Path.join(System.tmp_dir!(), "ampd-b2-trvm-evidence-#{System.pid()}")

    File.mkdir_p!(dir)
    rev = System.get_env("B2_SUBSTRATE_REVISION") || "unpinned"
    src = System.get_env("B2_SUBSTRATE_SOURCE") || File.cwd!()

    on_exit(fn ->
      cases =
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".case.json"))
        |> Enum.sort()
        |> Enum.map(&JSON.decode!(File.read!(Path.join(dir, &1))))

      manifest = %{
        "schema" => "wek-r3-case-manifest@1",
        "note" =>
          "HARNESS-OWNED. Case kinds, expected codes and event counts come from test/b2_trvm_reduce_test.exs, " <>
            "never from the traces. Provenance is substrate: these traces were emitted by the running runtime " <>
            "carrying the trvm.reduce computation.",
        "provenance" => "substrate",
        "substrate" => %{"revision" => rev, "source" => src},
        "cases" => cases
      }

      File.write!(Path.join(dir, "manifest.json"), JSON.encode!(manifest))
    end)

    {:ok, dir: dir, rev: rev}
  end

  # ------------------------------------------------------------- the world
  # The managed-node scaffolding (a Lane a Worker occupies, so the bridge
  # accepts a submit) plus the B2 world (a fresh journal incarnation, N
  # one-shot grants for trvm.reduce minted before the first snapshot).
  setup do
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.reset_demo()
    Bridge.reset()
    Peer.reset()
    Harness.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
    Application.put_env(:ampd, :carrier_machine, Harness)
    Ampd.Carrier.Machine.Gate.sync()

    on_exit(fn ->
      Application.delete_env(:ampd, :carrier_machine)
      Application.put_env(:ampd, :witness_snapshots, false)
      Harness.reset()
    end)

    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)
    Process.sleep(120)
    Authority.install_worktree()
    Authority.install_trvm()
    Application.put_env(:ampd, :witness_snapshots, false)

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)
    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "reduce a world"]), "goal")

    lane =
      ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")

    worker = ok!(Control.command(control, :open_worker, [lane["id"], "work"]), "worker")
    ok!(Control.command(agent, :attach_worker, [worker["id"]]), "worker")

    %{control: control, agent: agent, lane: lane, worker: worker}
  end

  defp grants!(n) do
    Authority.revoke_domain(@cap)
    # one-shot grants SCOPED to the world resource, not the demo's repository
    grants =
      for _ <- 1..n,
          do:
            Ampd.AuthorityCoordinator.transact(fn ->
              GrantRegistry.mint(%{
                "capability" => @cap,
                "resource" => @resource,
                "duration" => "once",
                "uses_remaining" => 1
              })
            end)

    [_] = Witness.files()
    Application.put_env(:ampd, :witness_snapshots, true)
    grants
  end

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key}: #{inspect(Map.take(result, ["allow", "reason", "refusal"]))}"

    result[key]
  end

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-trvm")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "trvm\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "trvm@example.invalid"],
          ["config", "user.name", "TRVM"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo: git #{Enum.join(args, " ")} -> #{out}"
    end

    dir
  end

  # ------------------------------------------------------------ the executor
  defp config(timeout_ms \\ 3000) do
    %{
      guardian: Path.expand("../../tools/hypersurface/node-guardian", __DIR__),
      node: System.find_executable("node"),
      driver: Path.expand("../../tools/hypersurface/reduce-file.mjs", __DIR__),
      host: System.fetch_env!("HS_TRVM_HOST"),
      scratch: Ampd.Store.data_dir(),
      timeout_ms: timeout_ms
    }
  end

  # B2_TRVM_EXECUTOR=resident runs the same cases through the RESIDENT checked host (TRVM runtime/wasm/resident):
  # one daemon per test, owned by the same guardian, jobs as frames; the warm-path barrier is `jobRetired`, not a
  # worker exit (README §6's forward rule). Unset, the one-shot managed-Node executor of the witness.
  defp resident?, do: System.get_env("B2_TRVM_EXECUTOR") == "resident"
  defp remote?, do: System.get_env("B2_TRVM_EXECUTOR") == "remote"

  # B2_TRVM_EXECUTOR=remote runs the same cases through a residentd on a TCP endpoint this runtime does not own
  # (T3): B2_REMOTE_RESIDENT=host:port names one started out of band (a lab host); unset, the test starts TRVM's
  # residentd on a loopback port of the kernel's choosing and reads the port from its announce line. No guardian
  # either way -- that is the kind.
  defp remote_endpoint do
    case System.get_env("B2_REMOTE_RESIDENT") do
      nil ->
        c = config()
        residentd = Path.join(Path.dirname(c.host), "../resident/residentd.mjs") |> Path.expand()

        port =
          Port.open({:spawn_executable, c.node}, [
            :binary,
            :exit_status,
            {:line, 4096},
            args: [
              residentd,
              "--port",
              "0",
              "--bind",
              "127.0.0.1",
              "--pool",
              "2",
              "--max-queue",
              "4"
            ]
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)

        announce =
          receive do
            {^port, {:data, {:eol, line}}} -> JSON.decode!(line)
          after
            15_000 -> flunk("residentd did not announce")
          end

        [host, p] = String.split(announce["residentd"], ":")
        Process.put(:remote_daemon, {port, os_pid})
        {host, String.to_integer(p), announce["module_sha256"]}

      hp ->
        [host, p] = String.split(hp, ":")
        {host, String.to_integer(p), nil}
    end
  end

  defp start_bridge(timeout_ms \\ 3000) do
    if remote?() do
      {host, port, _} = remote_endpoint()
      {:ok, ex} = HyperSurface.RemoteResident.start_link(%{host: host, port: port})

      {:ok, server} =
        Reducer.start_link({:remote_resident, %{executor: ex, timeout_ms: timeout_ms}})

      Process.put(:resident_executor, {HyperSurface.RemoteResident, ex})
      {:ok, server}
    else
      start_bridge_local(timeout_ms)
    end
  end

  defp start_bridge_local(timeout_ms) do
    if resident?() do
      c = config(timeout_ms)

      {:ok, ex} =
        HyperSurface.ResidentExecutor.start_link(%{
          guardian: c.guardian,
          node: c.node,
          driver: Path.expand("../../tools/hypersurface/resident-serve.mjs", __DIR__),
          host: Path.join(Path.dirname(c.host), "../resident/resident.mjs") |> Path.expand(),
          scratch: c.scratch,
          pool: 2
        })

      {:ok, server} =
        Reducer.start_link({:managed_resident, %{executor: ex, timeout_ms: timeout_ms}})

      Process.put(:resident_executor, {HyperSurface.ResidentExecutor, ex})
      {:ok, server}
    else
      Reducer.start_link({:managed_node, config(timeout_ms)})
    end
  end

  defp stop_bridge(server) do
    GenServer.stop(server)

    case Process.delete(:resident_executor) do
      nil -> :ok
      {mod, ex} -> mod.stop(ex)
    end

    case Process.delete(:remote_daemon) do
      nil ->
        :ok

      {port, os_pid} ->
        System.cmd("kill", ["-TERM", to_string(os_pid)])
        Port.close(port)
    end
  end

  defp await_take(server, peer, op, n \\ 0) do
    if n > 1_000_000, do: raise("poll budget exceeded")

    case Reducer.take(server, peer, op) do
      :pending ->
        Process.sleep(1)
        await_take(server, peer, op, n + 1)

      result ->
        result
    end
  end

  # The reduce function the adapter wraps: submit to the managed bridge, poll,
  # and STASH the host's output bytes in the test process so the harness can
  # bind receipt → bytes → film. The adapter itself only ever sees digests.
  defp reducer(ctx, server, me) do
    fn term ->
      t0 = System.monotonic_time(:nanosecond)

      {outcome, t1, t2} =
        case Reducer.submit(server, ctx.agent, ctx.lane["id"], term) do
          {:ok, op} ->
            t1 = System.monotonic_time(:nanosecond)
            {await_take(server, ctx.agent, op), t1, System.monotonic_time(:nanosecond)}

          # the bridge refused at submit (its own input bound): a refusal, reported as one
          {:refused, why} ->
            t1 = System.monotonic_time(:nanosecond)
            {{:refused, {:submit, why}}, t1, t1}
        end

      case outcome do
        {:ok, %{candidate: c}} -> send(me, {:host_output, c["output"], c["interactions"]})
        _ -> :ok
      end

      send(me, {:executor_span, (t1 - t0) / 1.0e6, (t2 - t1) / 1.0e6})
      outcome
    end
  end

  defp host_output do
    receive do
      {:host_output, out, itr} -> {out, itr}
    after
      0 -> nil
    end
  end

  defp executor_span do
    receive do
      {:executor_span, submit_ms, wait_ms} -> {submit_ms, wait_ms}
    after
      0 -> nil
    end
  end

  # ------------------------------------------------------ the reference gate
  # THE ONLY place result honesty is decided. Returns :ok or {:mismatch, why}.
  # Under the control the gate accepts everything (and says so).
  defp reference_check(rc, output, name) do
    if System.get_env("B2_NO_REFERENCE_ASSERT") == "1" do
      # the control: the gate ACCEPTS everything. It must not annotate its
      # acceptance, or the golden cases would change verdict too and the
      # control would flip four cases instead of the one it is about (measured
      # 2026-09-18: an annotated :ok made G1, F-I and S fail beside F-D).
      :ok
    else
      ref = reference(name)
      bound = output && TrvmReduce.sha256(output)

      cond do
        rc["nf_sha256"] != ref["payload_sha256"] ->
          {:mismatch, "nf_sha256 #{rc["nf_sha256"]} != reference #{ref["payload_sha256"]}"}

        rc["nf_bytes"] != ref["payload_bytes"] ->
          {:mismatch, "nf_bytes #{rc["nf_bytes"]} != reference #{ref["payload_bytes"]}"}

        rc["term_sha256"] != ref["term_sha256"] ->
          {:mismatch, "term_sha256 differs from the reference term"}

        bound != rc["nf_sha256"] ->
          {:mismatch,
           "the bytes the harness saw the host emit do not hash to the receipt's nf_sha256"}

        true ->
          :ok
      end
    end
  end

  defp film_of(output) do
    path = Path.join(Ampd.Store.data_dir(), "receipted.payload")
    File.write!(path, output)

    {out, 0} =
      System.cmd("python3", ["-B", Path.join(@compute, "film_of_payload.py"), path],
        env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
        cd: Path.join(@compute, "..")
      )

    JSON.decode!(String.trim(out))
  end

  # -------------------------------------------------------------- export
  defp export(ctx, id, kind, shape, expect \\ %{}) do
    files = Witness.files()
    trace = Witness.assemble(files, shape, ctx.rev)
    File.write!(Path.join(ctx.dir, "#{id}.trace.json"), JSON.encode!(trace))

    File.write!(
      Path.join(ctx.dir, "#{id}.case.json"),
      JSON.encode!(%{
        "case" => id,
        "kind" => kind,
        "trace" => "#{id}.trace.json",
        "expect" => expect,
        "must_fail" => false
      })
    )

    trace
  end

  defp events(trace),
    do: trace["segments"] |> Enum.flat_map(& &1["events"]) |> Enum.map(& &1["type"])

  defp close_with_state_and_listing do
    :ok = Effects.witness_state("state")
    Effects.witness_listing()
  end

  defp perform(ctx, server, name) do
    t = term(name)

    Gateway.perform(
      @cap,
      @resource,
      Gateway.ctx(),
      req(name),
      TrvmReduce.adapter(reducer(ctx, server, self()), params(name), t)
    )
  end

  # ================================================================ golden
  test "G1 · the 30-relay world, epoch 1: one effect, one receipt, the reference payload, Forge's film",
       ctx do
    [g] = grants!(1)
    {:ok, server} = start_bridge()
    r = perform(ctx, server, @world)
    stop_bridge(server)
    assert r["allow"], inspect(r)

    e = Effects.get(r["effect_id"])
    assert e["state"] == "COMMITTED" and e["branch"] == "B2" and e["grant_ref"] == g["id"]

    assert Enum.map(e["history"], & &1["state"]) ==
             ~w(PROPOSED AUTHORIZED CLAIMED ATTEMPTED COMMITTED)

    [rc] = Receipts.of_kind("capability-effect-receipt@1")
    assert rc["effect_ref"] == e["id"] and r["receipt"]["id"] == rc["id"]
    assert rc["capability"] == @cap and rc["pack"] == "trvm@0.1" and rc["actor"] == "kestrel"
    assert rc["idempotency_key"] == e["idempotency_key"]
    assert rc["guardian_status"] == 0

    cond do
      remote?() ->
        assert rc["job_retired"] == true and rc["worker_exited"] == false

        # the receipt names the executor that produced it: which kind, where, and the module the daemon reports
        assert rc["executor"] == "remote" and is_binary(rc["host"]) and is_integer(rc["port"])
        assert rc["module_sha256"] =~ ~r/^[0-9a-f]{64}$/

      resident?() ->
        assert rc["job_retired"] == true and rc["worker_exited"] == false
        assert rc["executor"] == "resident" and rc["module_sha256"] =~ ~r/^[0-9a-f]{64}$/
        refute Map.has_key?(rc, "host")

      true ->
        assert rc["worker_exited"] == true and rc["job_retired"] == false
        assert rc["executor"] == "managed" and not Map.has_key?(rc, "module_sha256")
    end

    assert rc["sem"] == @sem and rc["scenario_digest"] == @scenario_digest and rc["epoch"] == 1
    assert rc["interactions"] == reference(@world)["wasm_interactions"]

    # the fixed fields are still the receipt's, not the adapter's
    assert rc["secret_material_exposed_to_engine"] == false and rc["grant_ref"] == g["id"]

    {output, _itr} = host_output()
    assert reference_check(rc, output, @world) == :ok

    film = film_of(output)
    assert film["sem"] == @sem and film["scenario_digest"] == @scenario_digest
    assert film["film"] == @film_epoch1 and film["agrees"] == true

    listing = close_with_state_and_listing()

    assert listing[e["id"]] == %{
             "crash_phase" => nil,
             "approvals" => "NOT_REQUIRED",
             "grant_registry" => "COMPLETE",
             "receipts" => "COMPLETE"
           }

    assert Effects.recovery_listing() == listing
    trace = export(ctx, "G1-trvm-reduce-golden", "enforcement", {:run, 17})
    assert length(events(trace)) == 17
  end

  # ================================================================ F-K
  test "F-K · managed deadline while reducing: adapter raises, UNKNOWN with crash_phase nil, no receipt",
       ctx do
    [g] = grants!(1)
    {:ok, server} = start_bridge(1)
    r = perform(ctx, server, @world)
    stop_bridge(server)

    refute r["allow"]
    assert r["reason"] =~ "effect-unknown"
    e = Effects.get(r["effect_id"])
    assert e["state"] == "UNKNOWN"
    assert e["reason"] =~ "adapter raised: trvm.reduce: executor refused"
    assert Receipts.count() == 0
    assert Enum.find(GrantRegistry.list(), &(&1["id"] == g["id"]))["status"] == "consumed"

    listing = close_with_state_and_listing()

    assert listing[e["id"]] == %{
             "crash_phase" => nil,
             "approvals" => "NOT_REQUIRED",
             "grant_registry" => "COMPLETE",
             "receipts" => "INDETERMINATE"
           }

    export(ctx, "FK-trvm-managed-deadline", "enforcement", {:run, 13})
  end

  # ================================================================ F-R
  test "F-R · owner restart before commit: the reduction completes, the commit is stale, recovers UNKNOWN at ATTEMPTED",
       ctx do
    grants!(1)
    {:ok, server} = start_bridge()
    me = self()
    real = TrvmReduce.adapter(reducer(ctx, server, me), params(@world), term(@world))

    adapter = fn attempt ->
      send(me, {:in_adapter, self()})

      receive do
        :go -> real.(attempt)
      end
    end

    task =
      Task.async(fn -> Gateway.perform(@cap, @resource, Gateway.ctx(), req(@world), adapter) end)

    assert_receive {:in_adapter, pid}, 5_000
    e = Enum.find(Effects.all(), &(&1["state"] == "ATTEMPTED"))
    assert e
    old = Process.whereis(Effects)
    Process.exit(old, :kill)

    wait_up(Effects, fn ->
      if Process.whereis(Effects) == old, do: exit(:same), else: Effects.all()
    end)

    send(pid, :go)
    r = Task.await(task, 20_000)
    stop_bridge(server)

    refute r["allow"]
    assert r["reason"] =~ "effect-commit-refused · write-lease-stale"
    assert Effects.get(e["id"])["state"] == "ATTEMPTED"
    assert Receipts.count() == 0

    # the reduction itself DID complete with the reference payload — the boundary, not the host, refused
    {output, _} = host_output()
    assert TrvmReduce.sha256(output) == reference(@world)["payload_sha256"]

    :ok = Effects.witness_state("post_crash_state")
    assert Effects.recover!() == [e["id"]]
    listing = Effects.witness_listing()

    assert listing[e["id"]] == %{
             "crash_phase" => "ATTEMPTED",
             "approvals" => "NOT_REQUIRED",
             "grant_registry" => "COMPLETE",
             "receipts" => "INDETERMINATE"
           }

    export(ctx, "FR-trvm-owner-restart-before-commit", "recovery", {:crash, 9})
  end

  defp wait_up(mod, probe, n \\ 200)
  defp wait_up(_mod, _probe, 0), do: flunk("registry did not come back")

  defp wait_up(mod, probe, n) do
    ok =
      Process.whereis(mod) != nil and
        try do
          probe.()
          true
        catch
          :exit, _ -> false
        end

    if ok,
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_up(mod, probe, n - 1)
        )
  end

  # ================================================================ F-D
  test "F-D · a fabricated, well-shaped result is COMMITTED and receipted — and the reference gate is what rejects it",
       ctx do
    grants!(1)
    fake_output = "λa.λb.(a b)"

    fake =
      TrvmReduce.validate!(
        %{
          "term_sha256" => reference(@world)["term_sha256"],
          "nf_sha256" => TrvmReduce.sha256(fake_output),
          "nf_bytes" => byte_size(fake_output),
          "interactions" => 1,
          "worker_exited" => true,
          "job_retired" => false,
          "executor" => "managed",
          "guardian_status" => 0,
          "sem" => @sem,
          "scenario_digest" => @scenario_digest,
          "epoch" => 1
        },
        params(@world)
      )

    r = Gateway.perform(@cap, @resource, Gateway.ctx(), req(@world), fn _ -> fake end)
    assert r["allow"]
    e = Effects.get(r["effect_id"])
    assert e["state"] == "COMMITTED"
    [rc] = Receipts.of_kind("capability-effect-receipt@1")

    assert rc["nf_sha256"] == fake["nf_sha256"],
           "the journal cannot know; the receipt carries the wrong digest"

    # the detector fires — and under B2_NO_REFERENCE_ASSERT=1 it does not, which
    # makes THIS case the one that changes verdict under that control
    assert {:mismatch, why} = reference_check(rc, fake_output, @world)
    assert why =~ "nf_sha256"
    assert film_of(fake_output)["agrees"] == false

    close_with_state_and_listing()
    export(ctx, "FD-trvm-fabricated-result", "enforcement", {:run, 17})
  end

  # ================================================================ F-Z
  test "F-Z · size refusals: a 0-byte term and a 65,537-byte term are refused by the host, UNKNOWN, no receipt",
       ctx do
    [g1, g2] = grants!(2)
    {:ok, server} = start_bridge()

    for {label, t, g} <- [{"empty", "", g1}, {"oversize", String.duplicate("x", 65_537), g2}] do
      p = %{
        "sem" => @sem,
        "scenario_digest" => @scenario_digest,
        "epoch" => 1,
        "term_sha256" => TrvmReduce.sha256(t),
        "term_bytes" => byte_size(t)
      }

      req = %{"er" => "er-trvm.reduce", "rev" => 1, "params" => p}

      r =
        Gateway.perform(
          @cap,
          @resource,
          Gateway.ctx(),
          req,
          TrvmReduce.adapter(reducer(ctx, server, self()), p, t)
        )

      refute r["allow"], label
      e = Effects.get(r["effect_id"])
      assert e["state"] == "UNKNOWN", label
      assert e["reason"] =~ "adapter raised: trvm.reduce", label

      assert Enum.find(GrantRegistry.list(), &(&1["id"] == g["id"]))["status"] == "consumed",
             label <>
               " grants: " <>
               inspect(
                 Enum.map(GrantRegistry.list(), &{&1["id"], &1["status"], &1["consumptions"]})
               ) <>
               " effect: " <> inspect(Map.take(e, ["id", "grant_ref", "state"]))
    end

    stop_bridge(server)
    assert Receipts.count() == 0
    listing = close_with_state_and_listing()

    for e <- Effects.all() do
      assert listing[e["id"]]["crash_phase"] == nil and
               listing[e["id"]]["receipts"] == "INDETERMINATE"
    end

    export(ctx, "FZ-trvm-size-refusals", "enforcement", {:run, 24})
  end

  # ================================================================ F-I
  test "F-I · the same request under two one-shot grants: two effects, one idempotency key, two receipts",
       ctx do
    [g1, g2] = grants!(2)
    {:ok, server} = start_bridge()
    r1 = perform(ctx, server, @world)
    {out1, _} = host_output()
    r2 = perform(ctx, server, @world)
    {out2, _} = host_output()
    stop_bridge(server)
    assert r1["allow"] and r2["allow"]
    e1 = Effects.get(r1["effect_id"])
    e2 = Effects.get(r2["effect_id"])
    assert e1["id"] != e2["id"]
    assert e1["state"] == "COMMITTED" and e2["state"] == "COMMITTED"
    assert e1["idempotency_key"] == e2["idempotency_key"] and e1["effect_key"] == nil

    assert Enum.map([g1, g2], fn g ->
             Enum.find(GrantRegistry.list(), &(&1["id"] == g["id"]))["status"]
           end) == ["consumed", "consumed"]

    rcs = Receipts.of_kind("capability-effect-receipt@1")
    assert Enum.map(rcs, & &1["effect_ref"]) |> Enum.sort() == Enum.sort([e1["id"], e2["id"]])

    assert Enum.all?(
             rcs,
             &(reference_check(&1, if(&1["effect_ref"] == e1["id"], do: out1, else: out2), @world) ==
                 :ok)
           )

    close_with_state_and_listing()
    export(ctx, "FI-trvm-idempotency-two-grants", "enforcement", {:run, 32})
  end

  # ================================================================ spans
  @spans_runs 30
  test "S · the six spans over #{@spans_runs} sequential golden runs, exp 2^16 as the reduction control",
       ctx do
    grants!(@spans_runs)
    {:ok, server} = start_bridge()

    rows =
      for i <- 1..@spans_runs do
        t0 = System.monotonic_time(:nanosecond)
        r = perform(ctx, server, @world)
        t1 = System.monotonic_time(:nanosecond)
        assert r["allow"], "run #{i}: #{inspect(r["reason"])}"
        {out, itr} = host_output()
        {submit_ms, wait_ms} = executor_span()

        rc =
          Enum.find(
            Receipts.of_kind("capability-effect-receipt@1"),
            &(&1["id"] == r["receipt"]["id"])
          )

        assert reference_check(rc, out, @world) == :ok

        %{
          "run" => i,
          "perform_ms" => (t1 - t0) / 1.0e6,
          "submit_ms" => submit_ms,
          "executor_wait_ms" => wait_ms,
          "interactions" => itr
        }
      end

    # the reduction-span control: a longer term through the same executor, no effect
    control =
      for _ <- 1..10 do
        t0 = System.monotonic_time(:nanosecond)
        {:ok, op} = Reducer.submit(server, ctx.agent, ctx.lane["id"], term(@control_world))
        {:ok, %{candidate: c}} = await_take(server, ctx.agent, op)
        t1 = System.monotonic_time(:nanosecond)
        assert TrvmReduce.sha256(c["output"]) == reference(@control_world)["payload_sha256"]
        %{"executor_ms" => (t1 - t0) / 1.0e6, "interactions" => c["interactions"]}
      end

    stop_bridge(server)

    # the floor: bare node, the driver and the host, no bridge, no guardian, no effect
    floor =
      for _ <- 1..10 do
        t0 = System.monotonic_time(:nanosecond)

        {out, 0} =
          System.cmd("node", [
            config().driver,
            config().host,
            Path.join([@compute, "terms", @world <> ".ic"])
          ])

        t1 = System.monotonic_time(:nanosecond)
        %{"node_ms" => (t1 - t0) / 1.0e6, "status" => JSON.decode!(out)["status"]}
      end

    pct = fn xs, q -> xs |> Enum.sort() |> Enum.at(min(length(xs) - 1, trunc(q * length(xs)))) end
    take = fn key -> Enum.map(rows, & &1[key]) end

    summary = %{
      "runs" => @spans_runs,
      "perform_ms" => %{
        "p50" => pct.(take.("perform_ms"), 0.5),
        "p99" => pct.(take.("perform_ms"), 0.99)
      },
      "submit_ms" => %{
        "p50" => pct.(take.("submit_ms"), 0.5),
        "p99" => pct.(take.("submit_ms"), 0.99)
      },
      "executor_wait_ms" => %{
        "p50" => pct.(take.("executor_wait_ms"), 0.5),
        "p99" => pct.(take.("executor_wait_ms"), 0.99)
      },
      "boundary_ms_derived" => %{
        "note" =>
          "perform minus (submit + executor wait): admission + attempt + commit + ticketed receipt + reply, on this host",
        "p50" =>
          pct.(
            Enum.map(rows, &(&1["perform_ms"] - &1["submit_ms"] - &1["executor_wait_ms"])),
            0.5
          )
      },
      "control_exp_2p16_executor_ms" => %{
        "p50" => pct.(Enum.map(control, & &1["executor_ms"]), 0.5),
        "interactions" => hd(control)["interactions"]
      },
      "floor_bare_node_ms" => %{"p50" => pct.(Enum.map(floor, & &1["node_ms"]), 0.5)},
      "not_measured" =>
        "startup (guardian → Node started) and the host's own reduction time are not exposed by the bridge or the host; " <>
          "transfer and cleanup are inside executor_wait; persistence is inside the derived boundary figure",
      "rows" => rows,
      "control" => control,
      "floor" => floor
    }

    File.write!(Path.join(ctx.dir, "spans.json"), JSON.encode!(summary))
    assert Receipts.count() == @spans_runs
  end
end
