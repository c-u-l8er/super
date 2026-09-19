Code.require_file("../../tools/hypersurface/reducer_bridge.exs", __DIR__)

defmodule Ampd.B2TrvmCompiledKindTest do
  @moduledoc """
  T8 -- the compiled step as a `trvm.reduce` executor kind, under the witness's UNCHANGED reference gate
  (`wek/b2/trvm/COMPILED_EXECUTOR_PROPOSAL.md`; ruled by Travis 2026-09-19: *one-shot now, resident later*).

  The substrate half lives in TRVM (`compiled/executor.py`, `executor_test.py`, 20/20) and is not re-tested here:
  what these cases are about is the Super side -- that a guardian-owned one-shot child of a different language is
  the same kind of thing to the bridge as the Node one, that its refusals arrive with their REASONS rather than as
  one undifferentiated `executor_failed`, and that `Ampd.TrvmReduce` admits its result shape without touching
  `nf_sha256` or the film oracle.

  Two facts these cases pin, because they are the reason the kind exists:

    * **`nf_sha256` is the calculus's.** The 30-relay world's epoch 1 renders to the same 3,260 bytes whose sha256
      `2318bd82…` the vertical witness's golden receipt carries -- produced here without reducing a term.
    * **The bundle is not the term.** The Golden demo's epoch-1 TERM is 9.5 MB and the checked Wasm host refuses it
      at 64 KiB before parsing; the same epoch's BUNDLE is ~7.5 KB, because the step is not unrolled into it. That
      is the computation the calculus kind cannot run at all.

  Fixtures are built at test time by `TRVM/compiled/make_bundle.py` from the world's CURRENT sealed plan, so an
  emitter change cannot leave a stale file agreeing with itself.

  Requires B2_TRVM_COMPILED (the path to `TRVM/compiled/executor.py`) and python3; skips otherwise.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Bridge, Control, Loci, Peer, TrvmReduce}
  alias Ampd.Carrier.Machine.Harness
  alias HyperSurface.ReducerBridge, as: Reducer

  @moduletag skip: is_nil(System.get_env("B2_TRVM_COMPILED"))

  @nf_sha256 "2318bd828467fea8f7ecb2e214a0a9fc736c23c08e62feacfa1c7d57d5118eb6"
  @nf_bytes 3260
  @golden_nf "b755abdf955c4c243c288dcabf15041a4a691021a1a1f6ade0595fcc2ccceca1"
  @kind "compiled.c.step.v1"

  setup do
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.reset()
    Bridge.reset()
    Peer.reset()
    Harness.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
    Application.put_env(:ampd, :carrier_machine, Harness)
    Ampd.Carrier.Machine.Gate.sync()

    on_exit(fn ->
      Application.delete_env(:ampd, :carrier_machine)
      Harness.reset()
    end)

    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)
    Process.sleep(120)
    Authority.install_worktree()
    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)
    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "fold an epoch"]), "goal")
    lane = ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")
    w = ok!(Control.command(control, :open_worker, [lane["id"], "work"]), "worker")
    ok!(Control.command(agent, :attach_worker, [w["id"]]), "worker")
    %{agent: agent, lane: lane}
  end

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key} to be allowed, got: #{inspect(Map.take(result, ["allow", "reason", "refusal"]))}"

    result[key]
  end

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-compiled-kind")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "compiled\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "compiled@example.invalid"],
          ["config", "user.name", "Compiled"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo: git #{Enum.join(args, " ")} -> #{out}"
    end

    dir
  end

  # ------------------------------------------------------------------ the executor and its fixtures
  defp executor_py, do: System.fetch_env!("B2_TRVM_COMPILED")

  defp config(opts \\ []) do
    %{
      guardian: Path.expand("../../tools/hypersurface/node-guardian", __DIR__),
      python: System.find_executable("python3"),
      executor: executor_py(),
      emitter: "c",
      scratch: Ampd.Store.data_dir(),
      timeout_ms: opts[:timeout_ms] || 30_000
    }
    |> Map.merge(Map.new(opts) |> Map.drop([:timeout_ms]))
  end

  defp start_bridge(cfg) do
    {:ok, bridge} = Reducer.start_link({:managed_compiled, cfg})
    Process.unlink(bridge)
    on_exit(fn -> if Process.alive?(bridge), do: GenServer.stop(bridge) end)
    bridge
  end

  defp bundle(world, epoch \\ 1) do
    dir = Path.join(System.tmp_dir!(), "compiled-bundle-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    out = Path.join(dir, "bundle.json")

    {meta, 0} =
      System.cmd(
        System.find_executable("python3"),
        [
          Path.join(Path.dirname(executor_py()), "make_bundle.py"),
          "--world",
          world,
          "--epoch",
          to_string(epoch),
          "--meta",
          "--out",
          out
        ],
        stderr_to_stdout: true,
        env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
      )

    on_exit(fn -> File.rm_rf(dir) end)
    raw = File.read!(out)
    {raw, JSON.decode!(String.trim(meta)), JSON.decode!(raw)}
  end

  # A bundle is JSON with three base64 fields; a case that edits one edits exactly what the executor will re-hash.
  defp reseal(b), do: JSON.encode!(b)
  defp put_b64(b, field, bytes), do: Map.put(b, field, Base.encode64(bytes))
  defp get_b64(b, field), do: Base.decode64!(b[field])

  defp put_param(b, k, v),
    do: put_in(b, ["request", "params", k], v)

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp await_take(server, peer, op, remaining \\ 1500)
  defp await_take(_, _, _, 0), do: flunk("the slot never settled")

  defp await_take(server, peer, op, remaining) do
    case Reducer.take(server, peer, op) do
      :pending ->
        Process.sleep(10)
        await_take(server, peer, op, remaining - 1)

      result ->
        result
    end
  end

  defp run(ctx, raw, cfg \\ nil) do
    bridge = start_bridge(cfg || config())
    {:ok, op} = Reducer.submit(bridge, ctx.agent, ctx.lane["id"], raw)
    {bridge, op, await_take(bridge, ctx.agent, op)}
  end

  # ------------------------------------------------------------------------------------------------ cases

  test "G1c · the 30-relay world's epoch 1: the witness's nf_sha256, produced without reducing a term", ctx do
    {raw, meta, _} = bundle("chain30")
    assert meta["nf_sha256"] == @nf_sha256 and meta["nf_bytes"] == @nf_bytes
    {_b, _op, outcome} = run(ctx, raw)
    assert {:ok, %{candidate: c}} = outcome
    assert c["status"] == "candidate"
    assert c["executor"] == "compiled" and c["childReaped"] == true
    # the exit witness this kind has, and the one it does not: the guardian reaped the child; there is no worker thread
    refute Map.has_key?(c, "workerExited")
    assert sha(c["output"]) == @nf_sha256 and byte_size(c["output"]) == @nf_bytes
    assert c["kind"] == @kind and String.starts_with?(c["backend_id"], "cbknd-")

    params = meta_params(meta)
    result = TrvmReduce.compiled_result_from(outcome, params)
    assert result["nf_sha256"] == @nf_sha256
    assert result["plan_sha256"] == params["plan_sha256"]
    assert result["control_sha256"] == params["control_sha256"]
    assert result["state_sha256"] == params["state_sha256"]

    fields = TrvmReduce.receipt_fields("trvm.reduce", result)
    assert fields["kind"] == @kind and fields["executor"] == "compiled" and fields["child_reaped"] == true
    assert fields["flags"] == ["-O2"]
    # the calculus kind's fields are ABSENT, not false: this result has no term and no interaction count
    refute Map.has_key?(fields, "term_sha256")
    refute Map.has_key?(fields, "interactions")
    refute Map.has_key?(fields, "worker_exited")
  end

  test "G2c · the Golden demo's epoch 1 — the computation the calculus kind cannot run", ctx do
    {raw, meta, _} = bundle("golden-demo")
    assert meta["nf_sha256"] == @golden_nf
    # the whole claim of the kind, as a number: the term for this epoch is 9.5 MB and the checked host refuses it
    # at 64 KiB; the bundle that produces the same normal form is under 16 KB, because the step is not unrolled.
    assert byte_size(raw) < 16_384
    {_b, _op, outcome} = run(ctx, raw)
    assert {:ok, %{candidate: c}} = outcome
    assert sha(c["output"]) == @golden_nf
    assert TrvmReduce.compiled_result_from(outcome, meta_params(meta))["nf_sha256"] == @golden_nf
  end

  test "F-Pw · a plan edited only in WHITESPACE is still the same world: plan_sha256 moves, `sem` does not, and the fold is admitted",
       ctx do
    # Measured here rather than assumed, because it is the difference between the two identities the request
    # carries: `plan_sha256` pins the BYTES handed to the executor (the transport check) and `sem` pins the
    # MEANING (`wrl_plan._plan_to_artifact` re-hashes the parsed plan). A byte edit that changes no field is
    # admitted, correctly — and F-P below is the edit that is not.
    {_raw, meta, b} = bundle("chain30")
    edited = get_b64(b, "plan_b64") <> " "
    raw = b |> put_b64("plan_b64", edited) |> put_param("plan_sha256", sha(edited)) |> reseal()
    {_b, _op, outcome} = run(ctx, raw)
    assert {:ok, %{candidate: %{"status" => "candidate"} = c}} = outcome
    assert c["plan_sha256"] == sha(edited) and c["plan_sha256"] != meta["plan_sha256"]
    assert c["sem"] == meta["sem"]
    assert sha(c["output"]) == @nf_sha256
  end

  test "F-P · a plan whose CONTENT no longer re-hashes to its sem: refused BY NAME before any step, no result", ctx do
    {_raw, meta, b} = bundle("chain30")
    plan = JSON.decode!(get_b64(b, "plan_b64"))
    # one relay fewer: a different world, still claiming the sem it came with
    edited = JSON.encode!(Map.put(plan, "relays", Enum.drop(plan["relays"], 1)))
    raw = b |> put_b64("plan_b64", edited) |> put_param("plan_sha256", sha(edited)) |> reseal()
    {_b, _op, outcome} = run(ctx, raw)
    assert {:ok, %{candidate: %{"status" => "refused", "reason" => reason}}} = outcome
    assert reason in ~w(plan-not-bound outside-shapes input-decoding),
           "expected a named refusal, got #{reason}"

    assert reason == "plan-not-bound"
    # and it reaches the effect as UNKNOWN carrying that name, never as an undifferentiated executor failure
    assert_raise RuntimeError, ~r/refused before any step: plan-not-bound/, fn ->
      TrvmReduce.compiled_result_from(outcome, meta_params(meta))
    end
  end

  test "F-S · a previous payload that does not decode against this plan: input-decoding, no result", ctx do
    {_raw, meta, b} = bundle("chain30")
    broken = binary_part(get_b64(b, "state_b64"), 0, 200)
    raw = b |> put_b64("state_b64", broken) |> put_param("state_sha256", sha(broken)) |> reseal()
    {_b, _op, outcome} = run(ctx, raw)
    assert {:ok, %{candidate: %{"status" => "refused", "reason" => "input-decoding"}}} = outcome

    assert_raise RuntimeError, ~r/refused before any step: input-decoding/, fn ->
      TrvmReduce.compiled_result_from(outcome, meta_params(meta))
    end
  end

  test "F-T · a digest in the request that is not the bytes handed over: request-mismatch, named, no result", ctx do
    {_raw, _meta, b} = bundle("chain30")
    raw = b |> put_param("control_sha256", String.duplicate("0", 64)) |> reseal()
    {_b, _op, outcome} = run(ctx, raw)
    assert {:ok, %{candidate: %{"status" => "refused", "reason" => "request-mismatch"} = c}} = outcome
    assert c["detail"]["field"] == "control_sha256"
  end

  test "F-D′ · a fabricated well-shaped payload is COMMITTED and receipted — honesty stays at the reference gate", _ctx do
    {_raw, meta, _b} = bundle("chain30")
    params = meta_params(meta)
    lie = "λa.λb.(a b)"

    fabricated =
      {:ok,
       %{
         candidate: %{
           "status" => "candidate",
           "childReaped" => true,
           "output" => lie,
           "kind" => @kind,
           "plan_sha256" => params["plan_sha256"],
           "control_sha256" => params["control_sha256"],
           "state_sha256" => params["state_sha256"],
           "backend_id" => "cbknd-" <> String.duplicate("a", 64),
           "source_sha256" => String.duplicate("b", 64),
           "so_sha256" => String.duplicate("c", 64),
           "flags" => ["-O2"],
           "nf_sha256" => @nf_sha256
         }
       }}

    result = TrvmReduce.compiled_result_from(fabricated, params)
    # every shape check passes, and the digest is over the bytes the executor ACTUALLY printed -- never its own
    # account of them -- so the lie is receipted with a digest the reference comparison can refuse.
    assert result["nf_sha256"] == sha(lie)
    refute result["nf_sha256"] == @nf_sha256
  end

  test "K · the compiled and calculus kinds cannot share an idempotency key, by construction", _ctx do
    {_raw, meta, _b} = bundle("chain30")
    params = meta_params(meta)
    # the compiled request names an EPOCH of a world (plan+control+state); the calculus request names a TEXT
    refute Map.has_key?(params, "term_sha256")
    for k <- ~w(plan_sha256 control_sha256 state_sha256), do: assert(is_binary(params[k]))

    # and a compiled result cannot be validated against a calculus request: the identities it must match are absent
    calculus = %{"sem" => params["sem"], "scenario_digest" => params["scenario_digest"],
                 "epoch" => params["epoch"], "term_sha256" => String.duplicate("d", 64)}

    assert_raise RuntimeError, ~r/read a different plan_sha256/, fn ->
      TrvmReduce.validate_compiled!(
        %{"nf_sha256" => @nf_sha256, "nf_bytes" => @nf_bytes, "guardian_status" => 0,
          "sem" => params["sem"], "scenario_digest" => params["scenario_digest"],
          "epoch" => params["epoch"], "executor" => "compiled", "child_reaped" => true,
          "kind" => @kind, "plan_sha256" => params["plan_sha256"],
          "control_sha256" => params["control_sha256"], "state_sha256" => params["state_sha256"]},
        calculus
      )
    end
  end

  defp start_fence do
    {:ok, pid} =
      HyperSurface.ExecutionFence.start_link(Path.join(Ampd.Store.data_dir(), "compiled-kind-fence"))

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  test "C-F · the compiled kind CAN claim the Lane fence — the gap the resident kind records against itself", ctx do
    start_fence()
    {raw, meta, _} = bundle("chain30")
    {_b, _op, outcome} = run(ctx, raw, config(fence: true))
    assert {:ok, %{candidate: %{"status" => "candidate"} = c}} = outcome
    assert sha(c["output"]) == @nf_sha256
    assert TrvmReduce.compiled_result_from(outcome, meta_params(meta))["nf_sha256"] == @nf_sha256
  end

  defp meta_params(meta),
    do: Map.take(meta, ~w(kind sem scenario_digest epoch plan_sha256 control_sha256 state_sha256))
end
