Code.require_file("execution_fence.exs", __DIR__)

defmodule HyperSurface.NodeExecutor do
  @moduledoc """
  Lab-only owner for a trusted single-process Node driver (Worker threads allowed).
  This is not a Carrier profile or a descendant-process confinement boundary.
  The guardian owns/reaps Node; EOF and Linux parent death cover owner loss.
  """
  use GenServer

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
        "node-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    File.mkdir_p!(config.scratch)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "input")
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
              [config.node, config.driver, config.host, path] ++
                if(fence, do: [fence.receipt, fence.token], else: [])
          ]
        )

      timer = Process.send_after(self(), :deadline, config[:timeout_ms] || 2_000)

      {:ok,
       %{
         fence: fence,
         bridge: bridge,
         op: op,
         dir: dir,
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
    if st.bytes + byte_size(data) > 2 * 1024 * 1024 do
      stop_child(port)
      {:noreply, %{st | stopping: true, data: []}}
    else
      {:noreply, %{st | bytes: st.bytes + byte_size(data), data: [data | st.data]}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = st) do
    # Guardian status 0 and 42 both follow wait/reap of its exact child.
    confirmed = status in [0, 42, 67, 68, 69]

    for caller <- st.callers,
        do: GenServer.reply(caller, if(confirmed, do: :ok, else: {:error, :stop_unconfirmed}))

    if status == 0 and not st.stopping do
      with {:ok, result} <- JSON.decode(st.data |> Enum.reverse() |> IO.iodata_to_binary()),
           %{"status" => "candidate", "workerExited" => true} <- result do
        send(st.bridge, {:result, st.op, result})
      else
        _ -> :ok
      end
    end

    if confirmed do
      # A normal BEAM exit alone is not an exit witness: GenServer.stop can
      # end an owner normally while its child is still running.
      if st.fence, do: HyperSurface.ExecutionFence.reconcile(st.fence.lane)
      send(st.bridge, {:node_reaped, st.op})
      {:stop, :normal, st}
    else
      # A missing guardian acknowledgement is not proof of absence. Leave
      # this owner alive and its bridge slot fenced; no automatic retry.
      send(st.bridge, {:stop_unconfirmed, st.op})
      {:noreply, %{st | port: nil, callers: [], data: [], stopping: true}}
    end
  end

  def terminate(_, st) do
    Process.cancel_timer(st.timer)
    # On a kill this callback does not run: the Port closes automatically,
    # delivering EOF to the independent guardian, which kills and reaps Node.
    File.rm_rf(st.dir)
    :ok
  end

  defp stop_child(port) do
    Port.command(port, "x")
  rescue
    ArgumentError -> false
  end
end
