Code.require_file("execution_fence.exs", __DIR__)

defmodule HyperSurface.CompiledExecutor do
  @moduledoc """
  T8 -- the guardian-owned ONE-SHOT owner for the compiled `trvm.reduce` executor
  (`wek/b2/trvm/COMPILED_EXECUTOR_PROPOSAL.md`; ruled by Travis 2026-09-19: *one-shot now, resident later*).

  It is `NodeExecutor` with a different child and one fewer witness, and both differences are the point.

    * **A different child.** `python3 TRVM/compiled/executor.py <emitter> <bundle>` folds ONE epoch of one sealed
      world from the plan, the epoch's control text and the previous normal form -- never a term -- and prints the
      calculus's canonical bytes, so `nf_sha256` and the film oracle are the witness's, unchanged (proposal §2).
      That is what lets this kind run the Golden demo's 9.5 MB epoch, which the checked Wasm host refuses at 64 KiB.

    * **One input file, because the guardian says so.** `node_guardian.rs` runs `Command::new(argv[0]).args(argv[1..4])`
      and states "Never accepts request-selected argv": a guardian-owned child gets exactly one free argument and one
      input path. The proposal says the plan, control and state travel "beside the request" and does not say in how
      many files; measured against this guardian, the answer is ONE -- a base64 bundle (`executor.py`'s `bundle_bytes`),
      base64 because the three `sha256`s are over exact bytes and a transport that can normalise a newline can move a
      hash.

    * **One fewer witness, and no word invented to hide it.** The Node kind has two independent witnesses -- the host's
      own `workerExited` (its Worker thread ended) and the guardian's reap. A one-shot compiled child has only the
      second: the process IS the work. So this kind stamps `childReaped: true` -- the guardian's reap, and nothing
      else -- and never `workerExited`, which here would be the same fact counted twice.

    * **A refusal keeps its name.** The guardian forwards the child's stdout only when the child exits 0; a refusal
      exits 3 and the guardian returns 67 with no bytes. `executor.py` therefore also writes its outcome beside the
      bundle, in the scratch directory this owner made and removes, and this owner reads it ONLY on a status that
      means the child was reaped. Without it every refusal -- a plan that does not re-hash to its `sem`, a payload
      that does not decode, a world outside the emitter's shapes, a stale object -- would reach the Lane as one
      undifferentiated `executor_failed`.

  Not a Carrier profile and not a confinement boundary; native code from generated C, with no memory safety, no
  interaction bound and no deadline from a guest (proposal §4). What stands behind it is the battery and, per effect,
  the unchanged reference gate.
  """
  use GenServer

  @max_stdout 2 * 1024 * 1024

  def start(bridge, op, input, config),
    do: GenServer.start(__MODULE__, {bridge, op, input, config})

  def cancel(pid) do
    GenServer.call(pid, :cancel, 5_000)
  catch
    :exit, _ -> {:error, :stop_unconfirmed}
  end

  def init({bridge, op, input, config}) do
    claim =
      if config[:fence] == true,
        do: HyperSurface.ExecutionFence.claim(config.fence_key),
        else: {:ok, nil}

    case claim do
      {:ok, fence} -> boot(bridge, op, input, config, fence)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp boot(bridge, op, input, config, fence) do
    Process.monitor(bridge)

    dir =
      Path.join(
        config.scratch,
        "compiled-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    File.mkdir_p!(config.scratch)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "bundle.json")
    File.write!(path, input, [:exclusive])

    try do
      port =
        Port.open(
          {:spawn_executable, config.guardian},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :hide,
            args:
              [config.python, config.executor, emitter(config), path] ++
                if(fence, do: [fence.receipt, fence.token], else: [])
          ]
        )

      # The compiled step is microseconds; the Python interpreter and Forge's decoders around it are not, and the
      # Golden demo's render is a millisecond. The default is the one-shot span the proposal measured (§6), not the
      # calculus kind's 2 s.
      timer = Process.send_after(self(), :deadline, config[:timeout_ms] || 20_000)

      {:ok,
       %{
         fence: fence,
         bridge: bridge,
         op: op,
         dir: dir,
         outcome: path <> ".outcome",
         port: port,
         timer: timer,
         data: [],
         bytes: 0,
         stopping: false,
         callers: []
       }}
    rescue
      e ->
        File.rm_rf!(dir)
        reraise e, __STACKTRACE__
    end
  end

  defp emitter(config) do
    case config[:emitter] do
      nil -> "c"
      e when e in ["c", "c2"] -> e
      other -> raise ArgumentError, "compiled executor: unknown emitter #{inspect(other)}"
    end
  end

  def handle_call(:cancel, from, st) do
    stop_child(st.port)
    {:noreply, %{st | stopping: true, callers: [from | st.callers]}}
  end

  def handle_info({:DOWN, _, :process, bridge, _}, %{bridge: bridge} = st) do
    stop_child(st.port)
    {:noreply, %{st | stopping: true}}
  end

  def handle_info(:deadline, st) do
    stop_child(st.port)
    {:noreply, %{st | stopping: true}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = st) do
    if st.bytes + byte_size(data) > @max_stdout do
      stop_child(port)
      {:noreply, %{st | stopping: true, data: []}}
    else
      {:noreply, %{st | bytes: st.bytes + byte_size(data), data: [data | st.data]}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = st) do
    # The guardian's own statuses; 0 and 42 and 67 all follow wait/reap of its exact child.
    confirmed = status in [0, 42, 67, 68, 69]

    for caller <- st.callers,
        do: GenServer.reply(caller, if(confirmed, do: :ok, else: {:error, :stop_unconfirmed}))

    unless st.stopping do
      case outcome(st, status) do
        {:ok, result} -> send(st.bridge, {:result, st.op, result})
        :none -> :ok
      end
    end

    if confirmed do
      if st.fence, do: HyperSurface.ExecutionFence.reconcile(st.fence.lane)
      send(st.bridge, {:node_reaped, st.op})
      {:stop, :normal, st}
    else
      # A missing guardian acknowledgement is not proof of absence: the slot stays fenced, no retry.
      send(st.bridge, {:stop_unconfirmed, st.op})
      {:noreply, %{st | port: nil, callers: [], data: [], stopping: true}}
    end
  end

  # status 0: the child exited 0 and the guardian forwarded its stdout. A candidate, or nothing.
  defp outcome(st, 0) do
    with {:ok, result} <- JSON.decode(st.data |> Enum.reverse() |> IO.iodata_to_binary()),
         %{"status" => "candidate"} <- result do
      {:ok, Map.merge(result, %{"executor" => "compiled", "childReaped" => true})}
    else
      _ -> :none
    end
  end

  # status 67: the child exited NON-ZERO and was reaped -- a refusal by design. The guardian sent no bytes, so the
  # reason is read from the sidecar the child wrote in this owner's own scratch directory, and only from there.
  defp outcome(st, 67) do
    with {:ok, body} <- File.read(st.outcome),
         {:ok, %{"status" => "refused", "reason" => reason} = r} when is_binary(reason) <-
           JSON.decode(body) do
      {:ok, Map.merge(r, %{"executor" => "compiled", "childReaped" => true})}
    else
      _ -> :none
    end
  end

  defp outcome(_st, _status), do: :none

  def terminate(_, st) do
    Process.cancel_timer(st.timer)
    # On a kill this callback does not run: the Port closes, the guardian sees EOF and kills and reaps the child.
    File.rm_rf(st.dir)
    :ok
  end

  defp stop_child(port) do
    Port.command(port, "x")
  rescue
    ArgumentError -> false
  end
end
