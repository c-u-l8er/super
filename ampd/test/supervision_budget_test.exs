# T73 (agenda A-93; plan dt_0237; superlane/t73/TASK.md revision 2 with amendments 1 and 2).
#
# Two parts, one law file:
#
#   1. The suite runs `Ampd.Supervisor` with its own restart intensity,
#      `{1_000, 5}` from `config/config.exs`'s test block; unconfigured, which
#      is production, it stays `{100, 5}` (`Ampd.Application.supervisor_options/0`).
#      L1 and L2.
#   2. `Ampd.Effects` mints and persists its epoch in `init/1` and pushes the
#      fences from `handle_continue/2`, with a fence budget of elapsed time,
#      and the boot waits for that completion (`Ampd.Effects.await_ready!/0`)
#      before `recover!/0`. L3, L4, L5, P7's law and the cold-start check.
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
end
