# T73 (agenda A-93; plan dt_0237; superlane/t73/TASK.md revision 2 with amendments 1 and 2).
# T83 (agenda A-110 with A-109; plan dt_0253; superlane/t83/TASK.md revision 2).
#
# Three parts, one law file:
#
#   1. The suite runs `Ampd.Supervisor` with its own restart intensity,
#      `{1_000, 5}` from `config/config.exs`'s test block; unconfigured, which
#      is production, it stays `{100, 5}` (`Ampd.Application.supervisor_options/0`).
#      L1 and L2.
#   2. `Ampd.Effects` mints and persists its epoch in `init/1` and pushes the
#      fences from `handle_continue/2`, with a fence budget of elapsed time,
#      and the boot waits for that completion (`Ampd.Effects.await_ready!/0`)
#      before `recover!/0`. L3, L4, L5, P7's law and the cold-start check.
#   3. T83: P9's law and P12's law, each in a disposable BEAM (`:peer` with
#      `connection: :standard_io`) on scratch storage, with I (the suite's own
#      application and storage, compared before and after each law), and PR's
#      law (`:ready` is a read at the participant boundary).
#
# Not async: every test here kills or suspends named, supervised processes,
# and the cold-start check stops and starts the application.
defmodule Ampd.SupervisionBudgetTest do
  use ExUnit.Case, async: false

  # The Effects crashes, fence warnings and application stops provoked here are expected.
  @moduletag :capture_log
  @moduletag timeout: 180_000

  @registries [Ampd.GrantRegistry, Ampd.Approvals, Ampd.Receipts, Ampd.Effects]
  @participants [Ampd.GrantRegistry, Ampd.Approvals, Ampd.Receipts]
  @test_intensity {1_000, 5}
  @production_intensity {100, 5}

  # The participants held at a cold start, each for 3 s from the moment
  # Effects is waiting on it: about 6 s of fencing, every participant well
  # inside its own 5 s budget, and longer than the 5 s `recover!/0` waits.
  # Approvals is fenced first and Receipts last; GrantRegistry is left alone
  # because the children started after Effects read the grant table.
  @cold_start_delays [{Ampd.Approvals, 3_000}, {Ampd.Receipts, 3_000}]

  # ------------------------------------------------------------------ L1

  test "L1: the running supervisor uses the suite's intensity, and 40 reboots of the four registries recover" do
    sup = Process.whereis(Ampd.Supervisor)
    assert is_pid(sup), "Ampd.Supervisor is not running"

    effective = running_intensity()

    assert effective == @test_intensity,
           "Ampd.Supervisor runs with #{inspect(effective)} (max_restarts, max_seconds), not the suite's " <>
             "#{inspect(@test_intensity)}: the suite's deliberate kills are spending the production budget"

    opts = Ampd.Application.supervisor_options()

    assert {opts[:max_restarts], opts[:max_seconds]} == effective,
           "the selecting function and the running supervisor disagree"

    reset_and_settle!()

    for n <- 1..40 do
      old = pids()
      Ampd.AuthorityLog.close()
      Enum.each(@registries, fn mod -> Process.exit(Map.fetch!(old, mod), :kill) end)
      await_recovered!(old, 10_000, "reboot #{n} of 40")

      assert Process.whereis(Ampd.Supervisor) == sup,
             "reboot #{n} of 40: Ampd.Supervisor is not the process the test started with"

      assert ampd_started?(), "reboot #{n} of 40: the ampd application is not running"
    end
  end

  # ------------------------------------------------------------------ L2

  test "L2: unconfigured is {100, 5}, the suite's configuration is {1_000, 5}, and anything else is refused by name" do
    saved = Application.fetch_env(:ampd, :restart_intensity)

    try do
      opts = Ampd.Application.supervisor_options()
      assert opts[:strategy] == :one_for_one
      assert opts[:name] == Ampd.Supervisor

      assert selected() == @test_intensity,
             "the test configuration selects #{inspect(selected())}, not #{inspect(@test_intensity)}"

      Application.delete_env(:ampd, :restart_intensity)

      assert selected() == @production_intensity,
             "unconfigured, the supervisor would run with #{inspect(selected())}, not production's " <>
               inspect(@production_intensity)

      bad = [
        {0, 5},
        {100, 0},
        {-1, 5},
        {100, -5},
        {100.0, 5},
        {100, 5.0},
        {:many, 5},
        {100, 5, 1},
        [100, 5],
        [max_restarts: 100, max_seconds: 5],
        100,
        nil,
        "100/5"
      ]

      for value <- bad do
        Application.put_env(:ampd, :restart_intensity, value)
        err = assert_raise RuntimeError, fn -> Ampd.Application.supervisor_options() end

        assert String.starts_with?(err.message, "restart-intensity-invalid"),
               "#{inspect(value)} was refused, but not by name: #{err.message}"
      end
    after
      case saved do
        {:ok, value} -> Application.put_env(:ampd, :restart_intensity, value)
        :error -> Application.delete_env(:ampd, :restart_intensity)
      end
    end
  end

  # ------------------------------------------------------------------ L3

  test "L3: whatever order the supervisor sees the four exits in, all four recover within 1,000 ms" do
    {limit, period} = running_intensity()

    assert limit >= 200,
           "L3 kills 96 children; Ampd.Supervisor allows #{limit} restarts in #{period} s, " <>
             "too little headroom to run it without risking the application"

    reset_and_settle!()
    sup = Process.whereis(Ampd.Supervisor)

    for order <- permutations(@registries) do
      label = Enum.map_join(order, " → ", &inspect/1)
      epoch0 = await_recovered!(%{}, 10_000, "before #{label}")
      old = pids()

      # The clock starts immediately before the supervisor is resumed, and
      # every probe call and sleep after it stays inside the one deadline.
      t0 = queue_exits!(sup, order, old, label)
      result = await_settled(old, t0 + 1_000)
      elapsed = mono() - t0

      case result do
        {:ok, epoch1} ->
          assert elapsed <= 1_000,
                 "#{label}: recovered, but #{elapsed} ms after the supervisor resumed"

          assert seq(epoch1) == seq(epoch0) + 1,
                 "#{label}: Effects went from #{epoch0} to #{epoch1}; exactly one new incarnation was expected"

        {:wait, why} ->
          # Let the tree finish recovering, so this order is the only casualty.
          _ = await_settled(old, mono() + 15_000)

          flunk(
            "#{label}: not recovered within 1,000 ms of the supervisor's resume " <>
              "(#{elapsed} ms): #{inspect(why)}"
          )
      end
    end
  end

  # ------------------------------------------------------------------ L4

  test "L4: a sealed Effects boot pushes no fence, mints no epoch and opens no witness log" do
    epoch0 = reset_and_settle!()
    fences0 = fences()
    files0 = witness_files(epoch0)

    for {mod, fence} <- fences0 do
      assert is_map(fence) and fence["epoch"] == epoch0,
             "#{inspect(mod)} does not hold Effects' epoch #{epoch0} before the test: #{inspect(fence)}"
    end

    try do
      dir = Application.get_env(:ampd, :data_dir)
      Ampd.Effects.close_store()
      Ampd.TestStoreLoss.lose!(dir, "effects")
      old = Process.whereis(Ampd.Effects)
      Process.exit(old, :kill)

      await!(10_000, "the sealed Effects did not come up", fn ->
        pid = Process.whereis(Ampd.Effects)
        is_pid(pid) and pid != old and is_binary(call(Ampd.Effects, :sealed, 250))
      end)

      assert Ampd.Effects.sealed() =~ "RECOVERY-STATE-MISSING"
      assert Ampd.Effects.incarnation() == nil, "a sealed Effects minted an incarnation"
      assert fences() == fences0, "a sealed Effects boot changed a participant's fence"
      assert witness_files(epoch0) == files0, "a sealed Effects boot created a witness file"
    after
      Ampd.reset_demo()
    end

    assert Ampd.Effects.sealed() == nil
    await_recovered!(%{}, 15_000, "after the sealed boot was undone")
  end

  # ------------------------------------------------------------- L5 and P7

  test "L5: the fence budget is elapsed time, so a restarted Effects gives up on a participant that never answers within 7 s" do
    reset_and_settle!()
    {elapsed, reason} = stall_effects_on!(Ampd.Receipts)

    assert {%RuntimeError{message: message}, _stack} = reason

    assert message =~ "journal owner cannot fence Ampd.Receipts for epoch",
           "Effects exited, but not with the named fence error: #{message}"

    assert elapsed <= 7_000
  end

  test "P7's law: a fence push that runs out of time leaves no witness file for its epoch" do
    reset_and_settle!()
    {_elapsed, reason} = stall_effects_on!(Ampd.Receipts)

    assert {%RuntimeError{message: message}, _stack} = reason
    assert [_, epoch] = Regex.run(~r/ for epoch (e[0-9]+-[0-9a-f]+):/, message)
    path = Ampd.Effects.Witness.path(epoch)

    refute File.exists?(path),
           "the incarnation #{epoch} never fenced every participant, yet its witness log exists: #{path}"
  end

  # ------------------------------------------------------- the cold start

  test "cold start: the boot waits through Effects' completion, even when fencing outlasts recover!'s 5 s" do
    assert ampd_started?(), "the ampd application is not running before the cold start"

    try do
      {result, elapsed, outcomes} = arranged_cold_start!(@cold_start_delays, 3)

      assert result == :ok,
             "the application did not start, although every participant answered inside its own " <>
               "budget (#{inspect(outcomes)}, #{elapsed} ms): #{inspect(result)}"

      assert elapsed > 5_000,
             "the held participants did not keep the boot past 5 s (#{elapsed} ms, " <>
               "#{inspect(outcomes)}), so this start does not exercise the readiness barrier"

      assert %{"epoch" => _} = call(Ampd.Effects, :incarnation, 1_000)
    after
      unless ampd_started?(), do: Application.ensure_all_started(:ampd)
    end

    reset_and_settle!()
  end

  # ------------------------------------------- P9, P12 and I (T83, A-109)
  #
  # P9's law and P12's law run in a disposable BEAM: a `:peer` started with
  # `connection: :standard_io` (no distribution), given this run's code paths
  # explicitly, its own `AMPD_DATA_DIR` and its own working directory, both
  # under one scratch directory. Everything destructive happens in there,
  # done by `PeerLaws` below, which is compiled here and loaded into the peer
  # as object code (the peer cannot load this dynamically compiled test
  # module). `PeerLaws` returns observations and never asserts; each test
  # evaluates every one of its checks and records every failure, and the
  # cleanup reports them in one failure together with its own and I's.
  #
  # I: the suite's own application is never touched. Before each law (after
  # a passive control with nothing done) and after it, in an `on_exit`
  # callback that runs whether or not an assertion failed, the test compares
  # the pid of `Ampd.Supervisor`, the four registries' pids, the application
  # environment by key, and a path-to-SHA-256 map of the suite's storage and
  # of `priv/data`. Those directories are resolved once, before the law, to
  # absolute paths against the directory this file was loaded in, and the
  # same paths are read after it. A peer that cannot start fails the law:
  # nothing here falls back to the suite's own BEAM.
  #
  # Before I's baseline the suite must be quiescent, read without changing
  # anything: settled; retention with nothing to retire and no pass running;
  # no witness lines deferred in Effects; no authority-log checkpoint
  # running. If it is not, this file's own `reset_and_settle!/0` runs once
  # before the baseline and all four are read again; one that still fails is
  # reported as "I cannot be established" with what was read.

  # Separate deadlines: the peer's start, one RPC, ampd's start in the peer
  # (`await_ready!/0`'s 20 s and the rest of the boot), the peer's stop, and
  # the wait after its controller is killed if the stop did not end it.
  @peer_start_ms 30_000
  @peer_rpc_ms 10_000
  @peer_boot_ms 60_000
  @peer_stop_ms 15_000
  @peer_kill_ms 5_000

  # P9, measured inside the peer. The 7 s window starts at the restart event:
  # the restarted Effects first seen registered. Finding that restart has its
  # own deadline, and so has the recovery after the law.
  @p9_discovery_ms 5_000
  @p9_window_ms 7_000
  @p9_recovery_ms 20_000
  @p9_rpc_ms @p9_recovery_ms * 2 + @p9_discovery_ms + @p9_window_ms + 10_000
  @p12_rpc_ms 15_000

  # I's passive control: the suite settled (read-only probes), then observed
  # twice this far apart with nothing done.
  @suite_settle_ms 15_000
  @suite_control_ms 1_000

  # The suite's working directory, read when this file is loaded, before any
  # law runs. I resolves its relative paths against this, never against the
  # current directory, which a law run in the suite's own BEAM (PM2) changes
  # to a scratch directory that its cleanup then removes.
  @suite_cwd File.cwd!()

  {:module, peer_module, peer_beam, _} =
    defmodule PeerLaws do
      @moduledoc false
      # Runs in the disposable peer. The suite itself calls only `tree/1`,
      # which reads. No step raises out of a law: each one is observed.

      @participants [Ampd.GrantRegistry, Ampd.Approvals, Ampd.Receipts]
      @registries [Ampd.GrantRegistry, Ampd.Approvals, Ampd.Receipts, Ampd.Effects]

      # Configure and start ampd in this BEAM. `:ampd` is loaded first, so
      # loading cannot overwrite what is set here; it then gets `env` (the
      # suite's), loses `deletes` and takes `puts`. Then its dependencies and
      # the application are started.
      def boot(cwd, env, deletes, puts) do
        cd = File.cd(cwd)
        quiet = safe(&quiet_logger/0)
        loaded = Application.load(:ampd)
        Enum.each(env, fn {key, value} -> Application.put_env(:ampd, key, value) end)
        Enum.each(deletes, &Application.delete_env(:ampd, &1))
        Enum.each(puts, fn {key, value} -> Application.put_env(:ampd, key, value) end)

        config = %{
          restart_intensity: Application.fetch_env(:ampd, :restart_intensity),
          data_dir: Application.fetch_env(:ampd, :data_dir),
          ampd_data_dir: System.get_env("AMPD_DATA_DIR"),
          cwd: File.cwd()
        }

        default_before = tree(Path.expand("priv/data"))

        started =
          case safe(fn -> Application.ensure_all_started(:ampd) end) do
            {:ok, _apps} -> :ok
            other -> {:not_started, inspect(other, limit: 50)}
          end

        %{
          cd: cd,
          quiet: quiet,
          loaded: loaded,
          config: config,
          default_before: default_before,
          started: started,
          scratch_used: match?({:ok, [_ | _]}, File.ls(System.get_env("AMPD_DATA_DIR") || ""))
        }
      end

      # P12: what production's configuration selects and runs, and the
      # default directory as it is now.
      def p12 do
        %{
          selected: safe(&selected/0),
          running: safe(&intensity/0),
          default_after: tree(Path.expand("priv/data"))
        }
      end

      # P9: stop `participant` through its supervisor, which does not restart
      # it, kill Effects, and observe the restarted Effects give up on it.
      # Whatever happened, the participant is then restarted and the tree
      # given a bounded time to recover; both outcomes are returned with the
      # observation, never instead of it.
      def p9(participant, discovery_ms, window_ms, recovery_ms) do
        before = safe(fn -> settled(mono() + recovery_ms) end)
        child = safe(fn -> child_id(participant) end)

        terminated =
          case child do
            {:ok, id} -> safe(fn -> Supervisor.terminate_child(Ampd.Supervisor, id) end)
            other -> {:not_attempted, other}
          end

        fence =
          if terminated == :ok,
            do: safe(fn -> gone_fence(discovery_ms, window_ms) end),
            else: :not_attempted

        # Restoration: unconditional, and checked by the test.
        restart =
          case child do
            {:ok, id} -> safe(fn -> restarted(Supervisor.restart_child(Ampd.Supervisor, id)) end)
            other -> {:not_attempted, other}
          end

        recovery = safe(fn -> settled(mono() + recovery_ms) end)

        %{
          before: before,
          child: child,
          terminated: terminated,
          fence: fence,
          restart: restart,
          recovery: recovery
        }
      end

      # Every path under `dir` (relative to it) with its SHA-256, or its type
      # if it is not a regular file; `:absent` if `dir` is not there.
      def tree(dir) do
        if File.exists?(dir) do
          for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true), into: %{} do
            {Path.relative_to(path, dir), entry(path)}
          end
        else
          :absent
        end
      end

      defp entry(path) do
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            case File.read(path) do
              {:ok, bytes} -> {:sha256, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
              {:error, why} -> {:error, why}
            end

          {:ok, %File.Stat{type: type}} ->
            type

          {:error, why} ->
            {:error, why}
        end
      end

      defp gone_fence(discovery_ms, window_ms) do
        old = Process.whereis(Ampd.Effects)

        if is_pid(old) do
          Process.exit(old, :kill)
          killed_at = mono()

          case new_pid(Ampd.Effects, old, killed_at + discovery_ms) do
            nil ->
              {:not_restarted_within, discovery_ms}

            {new, restarted_at} ->
              ref = Process.monitor(new)

              receive do
                {:DOWN, ^ref, :process, ^new, reason} ->
                  now = mono()

                  {:exited,
                   %{
                     since_restart: now - restarted_at,
                     since_kill: now - killed_at,
                     reason: summary(reason)
                   }}
              after
                max(restarted_at + window_ms - mono(), 0) ->
                  Process.demonitor(ref, [:flush])
                  {:no_exit_within, window_ms}
              end
          end
        else
          :effects_not_running
        end
      end

      # The restart event: the restarted process first seen registered.
      defp new_pid(name, old, deadline) do
        pid = Process.whereis(name)

        cond do
          is_pid(pid) and pid != old ->
            {pid, mono()}

          mono() >= deadline ->
            nil

          true ->
            Process.sleep(1)
            new_pid(name, old, deadline)
        end
      end

      defp summary({%RuntimeError{message: message}, _stack}), do: {:runtime_error, message}
      defp summary(other), do: {:other, inspect(other, limit: 20)}

      defp restarted({:ok, pid}) when is_pid(pid), do: :restarted
      defp restarted({:ok, pid, _info}) when is_pid(pid), do: :restarted
      defp restarted(other), do: {:not_restarted, inspect(other)}

      defp child_id(mod) do
        pid = Process.whereis(mod)

        case Enum.find(Supervisor.which_children(Ampd.Supervisor), fn {_id, p, _, _} ->
               is_pid(p) and p == pid
             end) do
          {id, _pid, _type, _modules} -> {:ok, id}
          nil -> {:error, {:not_a_running_child, mod}}
        end
      end

      defp settled(deadline) do
        case probe(deadline) do
          {:ok, _epoch} = ok ->
            ok

          waiting ->
            if mono() < deadline do
              Process.sleep(10)
              settled(deadline)
            else
              waiting
            end
        end
      end

      defp probe(deadline) do
        case Enum.reject(@registries, &is_pid(Process.whereis(&1))) do
          [] ->
            case call_by(Ampd.Effects, :incarnation, deadline) do
              %{"epoch" => epoch} ->
                case Enum.reject(@participants, &fenced_by?(&1, epoch, deadline)) do
                  [] -> {:ok, epoch}
                  behind -> {:wait, {:not_fenced, epoch, behind}}
                end

              other ->
                {:wait, {:effects, inspect(other)}}
            end

          missing ->
            {:wait, {:not_registered, missing}}
        end
      end

      defp fenced_by?(mod, epoch, deadline) do
        case call_by(mod, :fence, deadline) do
          %{"epoch" => ^epoch} -> true
          {:refused, _} -> true
          _ -> false
        end
      end

      defp call_by(name, msg, deadline) do
        case deadline - mono() do
          left when left > 0 ->
            try do
              GenServer.call(name, msg, min(250, left))
            catch
              :exit, why -> {:exit, why}
            end

          _ ->
            {:exit, :deadline}
        end
      end

      defp selected do
        opts = Ampd.Application.supervisor_options()
        {opts[:max_restarts], opts[:max_seconds]}
      end

      # As the suite's `running_intensity/0` reads stdlib-7.1's #state record,
      # but returning what it found instead of asserting.
      defp intensity do
        state = :sys.get_state(Ampd.Supervisor)

        layout? =
          is_tuple(state) and tuple_size(state) >= 7 and elem(state, 0) == :state and
            elem(state, 1) == {:local, Ampd.Supervisor} and elem(state, 2) == :one_for_one and
            is_integer(elem(state, 5)) and is_integer(elem(state, 6))

        if layout?,
          do: {elem(state, 5), elem(state, 6)},
          else: {:layout_unknown, inspect(state, limit: 8)}
      end

      defp quiet_logger do
        _ = Application.ensure_all_started(:logger)
        :logger.set_primary_config(:level, :none)
      end

      defp safe(fun) do
        fun.()
      catch
        kind, why -> {:raised, kind, inspect(why, limit: 50)}
      end

      defp mono, do: System.monotonic_time(:millisecond)
    end

  @peer_module peer_module
  @peer_beam peer_beam

  @tag timeout: 300_000
  test "P9's law: in a disposable BEAM, a participant that is gone, not just slow, still ends a restarted Effects' fence push within 7 s" do
    run_law!("p9", fn law ->
      boot =
        in_peer(
          law.peer,
          @peer_module,
          :boot,
          [law.cwd, Application.get_all_env(:ampd), [], [data_dir: law.data]],
          @peer_boot_ms
        )

      run =
        in_peer(
          law.peer,
          @peer_module,
          :p9,
          [Ampd.Receipts, @p9_discovery_ms, @p9_window_ms, @p9_recovery_ms],
          @p9_rpc_ms
        )

      boot_checks(boot, law, {:ok, law.data}) ++ p9_checks(run)
    end)
  end

  @tag timeout: 300_000
  test "P12's law: in a disposable BEAM, a cold start under production's configuration runs Ampd.Supervisor with {100, 5}" do
    run_law!("p12", fn law ->
      boot =
        in_peer(
          law.peer,
          @peer_module,
          :boot,
          [law.cwd, Application.get_all_env(:ampd), [:restart_intensity], [data_dir: "priv/data"]],
          @peer_boot_ms
        )

      run = in_peer(law.peer, @peer_module, :p12, [], @p12_rpc_ms)

      boot_checks(boot, law, {:ok, "priv/data"}) ++ p12_checks(boot, run)
    end)
  end

  test "PR's law: `:ready` is a read at the participant boundary" do
    assert Ampd.Effects.class(:ready) == :read
  end

  # -------------------------------------------------------------- helpers

  # stdlib-7.1 (`supervisor.erl`): #state{name, strategy, children, dynamics,
  # intensity, period, restarts, ...}, so the limit and the period are
  # elements 5 and 6 of the tuple. The tag, the name and the strategy are
  # checked first, so a change in that layout fails here by name instead of
  # reading the wrong field.
  defp running_intensity do
    state = :sys.get_state(Ampd.Supervisor)

    layout? =
      is_tuple(state) and tuple_size(state) >= 7 and elem(state, 0) == :state and
        elem(state, 1) == {:local, Ampd.Supervisor} and elem(state, 2) == :one_for_one and
        is_integer(elem(state, 5)) and is_integer(elem(state, 6))

    assert layout?,
           "Ampd.Supervisor's state is not stdlib-7.1's #state record: " <> inspect(state, limit: 8)

    {elem(state, 5), elem(state, 6)}
  end

  defp selected do
    opts = Ampd.Application.supervisor_options()
    {opts[:max_restarts], opts[:max_seconds]}
  end

  defp reset_and_settle! do
    Ampd.reset_demo()
    await_recovered!(%{}, 15_000, "after Ampd.reset_demo()")
  end

  defp pids, do: Map.new(@registries, &{&1, Process.whereis(&1)})

  defp call(name, msg, timeout) do
    GenServer.call(name, msg, timeout)
  catch
    :exit, why -> {:exit, why}
  end

  # A probe call with its timeout recomputed from the one deadline: at most
  # 250 ms, never past the deadline, and no call at all once it has passed.
  defp call_by(name, msg, deadline) do
    case deadline - mono() do
      left when left > 0 -> call(name, msg, min(250, left))
      _ -> {:exit, :deadline}
    end
  end

  defp fenced_by?(mod, epoch, deadline) do
    case call_by(mod, :fence, deadline) do
      %{"epoch" => ^epoch} -> true
      {:refused, _} -> true
      _ -> false
    end
  end

  defp fences, do: Map.new(@participants, &{&1, call(&1, :fence, 1_000)})

  # One look at the four: `{:ok, epoch}` once each is registered (and, for
  # every module in `old`, is a new process), Effects answers with its current
  # incarnation, and every participant holds that epoch or refuses as sealed.
  # Every call's timeout is recomputed from `deadline`.
  defp probe(old, deadline) do
    now = pids()
    missing = for {mod, nil} <- now, do: mod
    same = for {mod, pid} <- now, pid != nil and Map.get(old, mod) == pid, do: mod

    cond do
      missing != [] ->
        {:wait, {:not_registered, missing}}

      same != [] ->
        {:wait, {:not_restarted, same}}

      true ->
        case call_by(Ampd.Effects, :incarnation, deadline) do
          %{"epoch" => epoch} ->
            case Enum.reject(@participants, &fenced_by?(&1, epoch, deadline)) do
              [] -> {:ok, epoch}
              behind -> {:wait, {:not_fenced, epoch, behind}}
            end

          other ->
            {:wait, {:effects, other}}
        end
    end
  end

  # Probe until `{:ok, epoch}` or the deadline; each sleep is capped by the
  # time left, so nothing here runs past `deadline` by more than one reply.
  defp await_settled(old, deadline) do
    case probe(old, deadline) do
      {:ok, _epoch} = ok ->
        ok

      waiting ->
        case deadline - mono() do
          left when left > 0 ->
            Process.sleep(min(5, left))
            await_settled(old, deadline)

          _ ->
            waiting
        end
    end
  end

  defp await_recovered!(old, ms, label) do
    case await_settled(old, mono() + ms) do
      {:ok, epoch} ->
        epoch

      {:wait, why} ->
        flunk("#{label}: the four registries did not recover within #{ms} ms: #{inspect(why)}")
    end
  end

  defp await!(ms, what, fun), do: await_until!(mono() + ms, what, fun)

  defp await_until!(deadline, what, fun) do
    cond do
      fun.() ->
        :ok

      mono() >= deadline ->
        flunk(what)

      true ->
        Process.sleep(10)
        await_until!(deadline, what, fun)
    end
  end

  defp await_new_pid!(name, old, deadline) do
    pid = Process.whereis(name)

    cond do
      is_pid(pid) and pid != old ->
        pid

      mono() >= deadline ->
        flunk("#{inspect(name)} was not restarted")

      true ->
        Process.sleep(1)
        await_new_pid!(name, old, deadline)
    end
  end

  # Suspend the supervisor and kill `order` one by one, each exit confirmed in
  # the supervisor's mailbox before the next kill, so the order it handles
  # them in is the order given. Returns the monotonic time taken immediately
  # before the resume, which is where L3's clock starts. Always resumed: a
  # failure before the resume resumes it and is raised again.
  defp queue_exits!(sup, order, old, label) do
    expected = Enum.map(order, &Map.fetch!(old, &1))
    :ok = :sys.suspend(sup)

    try do
      Enum.each(order, fn mod ->
        pid = Map.fetch!(old, mod)
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

        assert queued?(sup, {:EXIT, pid, :killed}, mono() + 1_000),
               "#{label}: #{inspect(mod)}'s exit never reached the suspended supervisor's mailbox"
      end)

      queued = for {:EXIT, pid, :killed} <- mailbox(sup), pid in expected, do: pid

      assert queued == expected,
             "#{label}: the supervisor holds the exits in another order: #{inspect(queued)}"
    catch
      kind, reason ->
        :sys.resume(sup)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end

    t0 = mono()
    :ok = :sys.resume(sup)
    t0
  end

  defp mailbox(pid) do
    case Process.info(pid, :messages) do
      {:messages, messages} -> messages
      nil -> []
    end
  end

  defp queued?(pid, msg, deadline) do
    cond do
      msg in mailbox(pid) ->
        true

      mono() >= deadline ->
        false

      true ->
        Process.sleep(1)
        queued?(pid, msg, deadline)
    end
  end

  # Suspend `participant`, kill Effects, and wait for the restarted Effects to
  # give up on it: `{ms from the kill to its exit, its exit reason}`. It must
  # exit within 7 s of the kill (its 5 s budget plus an observation margin).
  # The participant is always resumed and the tree let recover.
  defp stall_effects_on!(participant) do
    target = Process.whereis(participant)
    old = Process.whereis(Ampd.Effects)
    :ok = :sys.suspend(target)

    try do
      t0 = mono()
      Process.exit(old, :kill)
      new = await_new_pid!(Ampd.Effects, old, t0 + 2_000)
      ref = Process.monitor(new)
      wait = max(t0 + 7_000 - mono(), 0)

      receive do
        {:DOWN, ^ref, :process, ^new, reason} -> {mono() - t0, reason}
      after
        wait ->
          Process.demonitor(ref, [:flush])

          flunk(
            "with #{inspect(participant)} suspended, a restarted Effects did not give up within 7 s " <>
              "of starting: the fence budget is not elapsed time"
          )
      end
    after
      :sys.resume(target)
      _ = await_settled(%{}, mono() + 15_000)
    end
  end

  # A cold start with `delays` arranged, repeated (up to `attempts` times) only
  # while the arrangement itself failed: a participant that its delayer could
  # not suspend before Effects fenced it was not held, and that start shows
  # nothing. A start that failed is returned whatever the arrangement.
  defp arranged_cold_start!(delays, attempts) do
    {result, _elapsed, outcomes} = run = cold_start(delays)
    held? = Enum.all?(outcomes, fn {_mod, outcome} -> outcome == :held end)

    cond do
      held? or result != :ok ->
        run

      attempts > 1 ->
        arranged_cold_start!(delays, attempts - 1)

      true ->
        flunk(
          "could not hold the participants before Effects fenced them, in every attempt; " <>
            "this says nothing about the barrier: #{inspect(outcomes)}"
        )
    end
  end

  # Stop the application, start one delayer per held participant, and start
  # the application again: `{Application.start/1's result, its ms, each
  # delayer's outcome}`.
  defp cold_start(delays) do
    _ = Application.stop(:ampd)
    parent = self()
    delayers = for {mod, ms} <- delays, do: {mod, spawn_delayer(mod, ms, parent)}

    t0 = mono()
    result = Application.start(:ampd)
    elapsed = mono() - t0

    Enum.each(delayers, fn {_mod, pid} -> send(pid, :boot_returned) end)

    outcomes =
      Map.new(delayers, fn {mod, pid} ->
        receive do
          {:delayer, ^pid, outcome} -> {mod, outcome}
        after
          40_000 -> {mod, :no_report}
        end
      end)

    {result, elapsed, outcomes}
  end

  # One participant held at a cold start. Its name is registered before its
  # `init/1` runs, and Effects starts only after it, so a suspend sent the
  # moment the name appears is queued ahead of every fence Effects can send.
  # `:held` means a `{:fence_epoch, ...}` call was seen queued while it was
  # suspended; it then stays suspended for `ms` more. Always resumed.
  defp spawn_delayer(mod, ms, parent) do
    spawn(fn ->
      outcome =
        case await_registered(mod) do
          nil -> :never_registered
          pid -> hold(pid, ms)
        end

      send(parent, {:delayer, self(), outcome})
    end)
  end

  defp await_registered(mod) do
    case Process.whereis(mod) do
      nil ->
        receive do
          :boot_returned -> nil
        after
          0 -> await_registered(mod)
        end

      pid ->
        pid
    end
  end

  defp hold(pid, ms) do
    case safe(fn -> :sys.suspend(pid, 30_000) end) do
      :ok ->
        outcome = await_fence_queued(pid)
        if outcome == :held, do: Process.sleep(ms)
        _ = safe(fn -> :sys.resume(pid, 5_000) end)
        outcome

      other ->
        {:not_suspended, other}
    end
  end

  defp await_fence_queued(pid) do
    if Enum.any?(mailbox(pid), &match?({:"$gen_call", _from, {:fence_epoch, _epoch, _key}}, &1)) do
      :held
    else
      receive do
        :boot_returned -> :not_held
      after
        2 -> await_fence_queued(pid)
      end
    end
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, why -> {:exit, why}
  end

  # Every witness file laid out like `epoch`'s, whatever the layout is.
  defp witness_files(epoch) do
    epoch
    |> Ampd.Effects.Witness.path()
    |> String.replace(epoch, "*")
    |> Path.wildcard()
    |> MapSet.new()
  end

  defp ampd_started?, do: List.keymember?(Application.started_applications(), :ampd, 0)

  defp seq(epoch) do
    [_, n] = Regex.run(~r/^e([0-9]+)-/, epoch)
    String.to_integer(n)
  end

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  defp mono, do: System.monotonic_time(:millisecond)

  # ------------------------------------------- helpers for P9, P12 and I

  # Observe the suite (I), then register the cleanup BEFORE acquiring
  # anything, recording each resource in an unlinked ledger as it is
  # acquired: the scratch directory, then the peer. The law's own checks do
  # not fail the test here: every failed one is evaluated and recorded in
  # the ledger, or, if the law did not reach its checks, the failure that
  # stopped it; `finish_law!/2` then reports them in one failure together
  # with the cleanup's and I's.
  defp run_law!(label, law) do
    before = observe_suite()
    {:ok, ledger} = Agent.start(fn -> %{} end)
    on_exit(fn -> finish_law!(ledger, before) end)

    failed =
      case guarded(fn -> law.(acquire!(ledger, label)) end) do
        checks when is_list(checks) -> for {ok?, message} <- checks, ok? != true, do: message
        other -> ["the law did not reach its checks: " <> describe(other)]
      end

    case guarded(fn -> Agent.update(ledger, &Map.put(&1, :failed, failed)) end) do
      :ok ->
        :ok

      other ->
        flunk(
          "the law's failures could not be recorded for its cleanup (#{inspect(other)}):\n" <>
            Enum.join(failed, "\n")
        )
    end
  end

  # The law's resources, each recorded in the ledger as it is acquired.
  defp acquire!(ledger, label) do
    scratch =
      Path.join(System.tmp_dir!(), "ampd-t83-#{label}-#{System.unique_integer([:positive])}")

    :ok = Agent.update(ledger, &Map.put(&1, :dir, scratch))
    data = Path.join(scratch, "data")
    cwd = Path.join(scratch, "cwd")
    File.mkdir_p!(data)
    File.mkdir_p!(cwd)

    %{peer: start_peer!(ledger, data), dir: scratch, data: data, cwd: cwd}
  end

  # A fresh `:peer` over standard I/O, with this run's code paths and its own
  # AMPD_DATA_DIR, and `PeerLaws`' object code loaded into it. Not linked:
  # no exit signal of the peer's reaches this test process; a peer that dies
  # is seen as a failed RPC, and the cleanup monitors its stop.
  defp start_peer!(ledger, data) do
    root = :code.root_dir()

    paths =
      for path <- :code.get_path(), path != ~c".", not List.starts_with?(path, root),
          do: String.to_charlist(Path.expand(List.to_string(path)))

    erl = Path.join([List.to_string(root), "bin", "erl"])

    options = %{
      connection: :standard_io,
      args: [~c"-pa" | paths],
      env: [{~c"AMPD_DATA_DIR", String.to_charlist(data)}],
      wait_boot: @peer_start_ms
    }

    options =
      if File.exists?(erl), do: Map.put(options, :exec, String.to_charlist(erl)), else: options

    peer =
      case guarded(fn -> :peer.start(options) end) do
        {:ok, peer} ->
          peer

        {:ok, peer, _node} ->
          peer

        other ->
          flunk(
            "no disposable BEAM: :peer.start/1 returned #{inspect(other)}; " <>
              "this law never runs in the suite's own BEAM"
          )
      end

    :ok = Agent.update(ledger, &Map.put(&1, :peer, peer))

    case in_peer(
           peer,
           :code,
           :load_binary,
           [@peer_module, ~c"supervision_budget_test.exs", @peer_beam],
           @peer_rpc_ms
         ) do
      {:ok, {:module, module}} when module == @peer_module ->
        peer

      other ->
        flunk("the law's code did not load into the disposable BEAM: #{inspect(other)}")
    end
  end

  defp in_peer(peer, module, fun, args, timeout) do
    {:ok, :peer.call(peer, module, fun, args, timeout)}
  catch
    kind, why -> {:peer_failed, kind, why}
  end

  # The cleanup, outside the test process, and the law's one report. Each
  # step is attempted and checked on its own, so no failure before it can
  # keep it from running: the peer's stop (bounded, its outcome collected
  # first), the scratch directory's removal, and I. The law's own recorded
  # failures and every one of these are then reported together, in one
  # failure.
  defp finish_law!(ledger, before) do
    held = guarded(fn -> Agent.get(ledger, & &1) end)

    {held, lost} =
      if is_map(held),
        do: {held, []},
        else: {%{}, ["the law's resources could not be read back: #{inspect(held)}"]}

    law =
      case held do
        %{failed: failed} -> failed
        _ when lost != [] -> []
        _ -> ["the law did not finish, so its own checks were never recorded"]
      end

    after_law = lost ++ stop_peer(held) ++ remove_scratch(held) ++ suite_untouched(before)
    _ = guarded(fn -> Agent.stop(ledger) end)

    failures =
      if after_law == [],
        do: law,
        else: law ++ ["after the law:\n  " <> Enum.join(after_law, "\n  ")]

    if failures != [],
      do: flunk(Enum.join(failures, "\n"))
  end

  # The stop itself is bounded. `:peer.stop/1` is synchronous, so it runs in a
  # separate, unlinked process and its outcome is collected here within
  # `@peer_stop_ms`; a stop that has not returned by then is abandoned. If
  # the peer's controller is still running at that deadline it is killed
  # (which closes the peer's standard I/O connection) and waited for at most
  # `@peer_kill_ms`, and the failure is reported either way. Only then are
  # the scratch directory and I looked at.
  defp stop_peer(%{peer: peer}) do
    watch = Process.monitor(peer)
    deadline = mono() + @peer_stop_ms

    {stopper, ref} =
      spawn_monitor(fn -> exit({:stop_returned, guarded(fn -> :peer.stop(peer) end)}) end)

    stop =
      receive do
        {:DOWN, ^ref, :process, ^stopper, outcome} -> outcome
      after
        @peer_stop_ms ->
          Process.exit(stopper, :kill)
          Process.demonitor(ref, [:flush])
          {:stop_not_returned_within, @peer_stop_ms}
      end

    case await_down(watch, peer, max(deadline - mono(), 0)) do
      {:down, _reason} ->
        []

      :running ->
        Process.exit(peer, :kill)

        killed =
          case await_down(watch, peer, @peer_kill_ms) do
            {:down, reason} -> "its controller was then killed and exited #{inspect(reason)}"
            :running -> "its controller is still running #{@peer_kill_ms} ms after it was killed"
          end

        ["the disposable BEAM did not stop within #{@peer_stop_ms} ms (#{inspect(stop)}); " <> killed]
    end
  end

  defp stop_peer(_held), do: []

  defp await_down(watch, peer, ms) do
    receive do
      {:DOWN, ^watch, :process, ^peer, reason} -> {:down, reason}
    after
      ms -> :running
    end
  end

  defp remove_scratch(%{dir: dir}) do
    removed = guarded(fn -> File.rm_rf(dir) end)

    if File.exists?(dir),
      do: ["the scratch directory #{dir} is still there: #{inspect(removed)}"],
      else: []
  end

  defp remove_scratch(_held), do: []

  defp suite_untouched(before) do
    quiet = for what <- before.quiescence, do: "I cannot be established: " <> what

    control =
      if before.control == [],
        do: [],
        else: [
          "I cannot be established: with nothing done, the suite's own application or storage " <>
            "changed during the passive control (settled: #{inspect(before.settled)}): " <>
            inspect(before.control)
        ]

    # The same absolute paths the baseline read, never resolved again here.
    law =
      case guarded(fn -> suite_snapshot(before.paths) end) do
        now when is_map(now) ->
          case differences(before.snapshot, now) do
            [] -> []
            diff -> ["I: the suite's own application or storage changed during the law: #{inspect(diff)}"]
          end

        other ->
          ["I: the suite could not be observed after the law: #{inspect(other)}"]
      end

    quiet ++ control ++ law
  end

  # I, before: the absolute paths it compares, resolved once here
  # (`snapshot_paths/0`) and reused after the law; then the suite quiescent
  # (`read_quiescence/0`, reads only); if it is not, this file's own
  # `reset_and_settle!/0` once, before the baseline, and all four conditions
  # read again. Then the passive control: two snapshots `@suite_control_ms`
  # apart with nothing done.
  defp observe_suite do
    paths = snapshot_paths()

    {settled, quiet} =
      case read_quiescence() do
        {settled, []} ->
          {settled, []}

        {_settled, _failed} ->
          reset_and_settle!()
          {settled, failed} = read_quiescence()
          {settled, Enum.map(failed, &(&1 <> " (read again after this file's reset_and_settle!/0)"))}
      end

    first = suite_snapshot(paths)
    Process.sleep(@suite_control_ms)

    %{
      paths: paths,
      snapshot: first,
      settled: settled,
      quiescence: quiet,
      control: differences(first, suite_snapshot(paths))
    }
  end

  # The four conditions under which no writer changes the suite's storage
  # without a request (superlane/t83/m2/EVIDENCE.md), each read without
  # changing, calling to write or flushing anything in the parent
  # application: `{await_settled's result, what failed, with what was read}`.
  defp read_quiescence do
    settled = await_settled(%{}, mono() + @suite_settle_ms)
    {settled, quiescence_failures(settled)}
  end

  defp quiescence_failures(settled) do
    retention =
      guarded(fn ->
        cfg = Ampd.Retention.config()
        retirable = Ampd.Effects.retirable(cfg.keep_recent, cfg.max_batch)
        status = Ampd.Retention.status()

        {length(retirable) < cfg.min_batch and status["running"] == nil,
         %{config: cfg, retirable: length(retirable), running: status["running"]}}
      end)

    deferred =
      guarded(fn ->
        state = :sys.get_state(Ampd.Effects)
        {state.inc == nil or state.inc.deferred == [], state.inc && state.inc.deferred}
      end)

    checkpoint = guarded(fn -> Ampd.AuthorityLog.status()["checkpoint_running"] end)

    [
      {match?({:ok, _}, settled),
       "the suite did not settle within #{@suite_settle_ms} ms: #{inspect(settled)}"},
      {match?({true, _}, retention),
       "retention has effects to retire or a pass running, so it may write during the law: " <>
         inspect(retention, limit: 20)},
      {match?({true, _}, deferred),
       "Ampd.Effects holds deferred witness lines, so a flush may write during the law: " <>
         inspect(deferred, limit: 20)},
      {checkpoint == nil,
       "an authority-log checkpoint is running, so it may write during the law: " <>
         "checkpoint_running is #{inspect(checkpoint, limit: 20)}"}
    ]
    |> Enum.reject(fn {held?, _what} -> held? end)
    |> Enum.map(fn {_held?, what} -> what end)
  end

  # The absolute paths I reads, resolved once before the law against the
  # directory this file was loaded in (`@suite_cwd`), never the current one.
  defp snapshot_paths do
    %{storage: suite_dirs(), default_dir: Path.expand("priv/data", @suite_cwd)}
  end

  defp suite_snapshot(paths) do
    %{
      supervisor: Process.whereis(Ampd.Supervisor),
      registries: pids(),
      env: Map.new(Application.get_all_env(:ampd)),
      ampd_data_dir: System.get_env("AMPD_DATA_DIR"),
      storage: Enum.reduce(paths.storage, %{}, &Map.merge(&2, files_of(&1))),
      default_dir: files_of(paths.default_dir)
    }
  end

  # The suite's storage: its configured data directory and, if set, the
  # AMPD_DATA_DIR it runs with, each made absolute against `@suite_cwd`.
  defp suite_dirs do
    [Application.get_env(:ampd, :data_dir), System.get_env("AMPD_DATA_DIR")]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand(&1, @suite_cwd))
    |> Enum.uniq()
  end

  defp files_of(dir) do
    case Ampd.SupervisionBudgetTest.PeerLaws.tree(dir) do
      :absent -> %{{dir, "."} => :absent}
      tree -> Map.new(tree, fn {path, entry} -> {{dir, path}, entry} end)
    end
  end

  defp differences(a, b) do
    for key <- Map.keys(a), Map.get(a, key) != Map.get(b, key),
        do: {key, changed(Map.get(a, key), Map.get(b, key))}
  end

  defp changed(a, b) when is_map(a) and is_map(b) do
    keys = Enum.uniq(Map.keys(a) ++ Map.keys(b))
    Enum.take(for(k <- keys, Map.get(a, k) != Map.get(b, k), do: k), 20)
  end

  defp changed(a, b), do: {a, b}

  defp guarded(fun) do
    fun.()
  catch
    kind, why -> {:failed, kind, why}
  end

  # What stopped a law before its checks: an assertion's own message, or the
  # caught term.
  defp describe({:failed, _kind, %ExUnit.AssertionError{message: message}}), do: message
  defp describe(other), do: inspect(other, limit: 50)

  defp boot_checks({:ok, boot}, law, data_dir) do
    [
      {boot.loaded == :ok,
       "the disposable BEAM did not load :ampd before configuring it: #{inspect(boot.loaded)}"},
      {boot.cd == :ok and boot.config.cwd == {:ok, law.cwd},
       "the disposable BEAM did not work in its own directory #{law.cwd}: " <>
         inspect({boot.cd, boot.config.cwd})},
      {boot.config.data_dir == data_dir,
       "the disposable BEAM's :data_dir is #{inspect(boot.config.data_dir)}, not #{inspect(data_dir)}"},
      {boot.config.ampd_data_dir == law.data,
       "the disposable BEAM's AMPD_DATA_DIR is #{inspect(boot.config.ampd_data_dir)}, not #{law.data}"},
      {boot.started == :ok, "ampd did not start in the disposable BEAM: #{inspect(boot.started)}"},
      {boot.scratch_used,
       "ampd in the disposable BEAM wrote nothing into its AMPD_DATA_DIR #{law.data}: " <>
         "its storage is not the scratch storage, so this start says nothing"}
    ]
  end

  defp boot_checks(other, _law, _data_dir),
    do: [{false, "ampd could not be configured and started in the disposable BEAM: #{inspect(other)}"}]

  defp p9_checks({:ok, run}) do
    message =
      case run.fence do
        {:exited, %{reason: {:runtime_error, message}}} -> message
        _ -> nil
      end

    elapsed =
      case run.fence do
        {:exited, %{since_restart: ms}} -> ms
        _ -> nil
      end

    [
      {match?({:ok, _}, run.before),
       "the disposable BEAM's tree was not settled before the law: #{inspect(run.before)}"},
      {run.terminated == :ok,
       "Ampd.Receipts was not stopped through its supervisor: #{inspect({run.child, run.terminated})}"},
      {is_binary(message) and message =~ "journal owner cannot fence Ampd.Receipts for epoch",
       "a restarted Effects did not exit with the named fence error: #{inspect(run.fence)}"},
      {is_binary(message) and message =~ "noproc",
       "Effects gave up on Ampd.Receipts, but not after the :noproc this law arranges: " <>
         inspect(run.fence)},
      {is_integer(elapsed) and elapsed <= @p9_window_ms,
       "with Ampd.Receipts stopped and not restarted, a restarted Effects did not give up within " <>
         "7 s of its restart: the fence deadline does not hold across :noproc retries: " <>
         inspect(run.fence)},
      {run.restart == :restarted,
       "restoration: Ampd.Receipts was not restarted after the law: #{inspect(run.restart)}"},
      {match?({:ok, _}, run.recovery),
       "restoration: the disposable BEAM's tree did not recover within #{@p9_recovery_ms} ms " <>
         "of Ampd.Receipts' restart: #{inspect(run.recovery)}"}
    ]
  end

  defp p9_checks(other),
    do: [{false, "P9's law did not run in the disposable BEAM: #{inspect(other)}"}]

  defp p12_checks({:ok, boot}, {:ok, run}) do
    [
      {boot.config.restart_intensity == :error,
       "the production start ran with a restart intensity configured: " <>
         inspect(boot.config.restart_intensity)},
      {run.default_after == boot.default_before,
       "the production start changed the default directory priv/data under the peer's working " <>
         "directory: #{inspect(boot.default_before)} before, #{inspect(run.default_after)} after"},
      {run.selected == @production_intensity,
       "under production's configuration, supervisor_options/0 selects #{inspect(run.selected)}"},
      {run.running == @production_intensity,
       "under production's configuration, Ampd.Supervisor runs with #{inspect(run.running)}, " <>
         "not #{inspect(@production_intensity)}"}
    ]
  end

  defp p12_checks(boot, run),
    do: [{false, "P12's law did not run in the disposable BEAM: #{inspect({boot, run})}"}]
end
