Code.require_file("execution_fence.exs", __DIR__)

defmodule HyperSurface.ResidentExecutor do
  @moduledoc """
  Lab-only owner of ONE resident checked-host daemon (`resident-serve.mjs` over TRVM's `resident.mjs`), started once
  and kept: the guardian owns the Node child exactly as for the one-shot driver (PDEATHSIG, stop byte → SIGKILL →
  `Child.wait`), so the kernel's witness is unchanged for the daemon as a whole. What changes is per job: a job is a
  frame over a private Unix socket in the executor's scratch directory, and its barrier on the warm path is the host's
  own `jobRetired: true`, not a process exit (TRVM `runtime/wasm/resident/README.md` §2, §6). This module makes that
  loss of the per-job kernel witness explicit: a job whose stop the host does not confirm asks the executor to kill the
  daemon, which costs the warm pool and keeps the proof. Not a Carrier profile, not a production backend.
  """
  use GenServer

  @connect_poll_ms 20

  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @doc "The socket path a job connects to; the call waits until the daemon accepts connections (bounded by the executor's connect timeout)."
  def socket(pid), do: GenServer.call(pid, :socket, 15_000)

  @doc "Kill the daemon through the guardian and wait for its reaped-child witness. Loses the warm pool by design."
  def kill(pid) do
    GenServer.call(pid, :kill, 10_000)
  catch
    :exit, _ -> {:error, :stop_unconfirmed}
  end

  def stop(pid), do: GenServer.stop(pid)

  @doc "What a job's reply carries about the executor that produced it."
  def identity(_pid), do: %{"executor" => "resident"}

  def init(config) do
    dir =
      Path.join(
        config.scratch,
        "resident-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    File.mkdir_p!(config.scratch)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    sock = Path.join(dir, "sock")

    port =
      Port.open(
        {:spawn_executable, config.guardian},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: [config.node, config.driver, config.host, sock],
          env: [
            {~c"RESIDENT_POOL", to_charlist(config[:pool] || 4)},
            {~c"RESIDENT_MAX_QUEUE", to_charlist(config[:max_queue] || 16)}
          ]
        ]
      )

    deadline = System.monotonic_time(:millisecond) + (config[:connect_timeout_ms] || 5_000)
    send(self(), :poll_ready)

    {:ok,
     %{
       dir: dir,
       sock: sock,
       port: port,
       ready: false,
       deadline: deadline,
       exit_status: nil,
       killers: [],
       waiters: []
     }}
  end

  def handle_call(:socket, _, %{ready: true, exit_status: nil} = st),
    do: {:reply, {:ok, st.sock}, st}

  # not ready yet: the job waits for the daemon's first accepted connection, or for the connect deadline
  def handle_call(:socket, from, %{exit_status: nil} = st),
    do: {:noreply, %{st | waiters: [from | st.waiters]}}

  def handle_call(:socket, _, st), do: {:reply, {:error, :daemon_exited}, st}

  def handle_call(:kill, from, %{exit_status: nil} = st) do
    stop_child(st.port)
    {:noreply, %{st | killers: [from | st.killers]}}
  end

  def handle_call(:kill, _, st), do: {:reply, confirmed_reply(st.exit_status), st}

  def handle_info(:poll_ready, %{ready: false, exit_status: nil} = st) do
    case :gen_tcp.connect({:local, st.sock}, 0, [:binary, packet: 4, active: false], 200) do
      {:ok, s} ->
        :gen_tcp.close(s)
        for w <- st.waiters, do: GenServer.reply(w, {:ok, st.sock})
        {:noreply, %{st | ready: true, waiters: []}}

      {:error, _} ->
        if System.monotonic_time(:millisecond) > st.deadline do
          for w <- st.waiters, do: GenServer.reply(w, {:error, :not_ready})
          stop_child(st.port)
          {:noreply, %{st | waiters: []}}
        else
          Process.send_after(self(), :poll_ready, @connect_poll_ms)
          {:noreply, st}
        end
    end
  end

  def handle_info(:poll_ready, st), do: {:noreply, st}

  def handle_info({port, {:data, _}}, %{port: port} = st), do: {:noreply, st}

  def handle_info({port, {:exit_status, status}}, %{port: port} = st) do
    # 42 = killed and reaped after the stop byte; 0/67/68/69 = the child exited and was reaped. 66 = wait failed.
    for caller <- st.killers, do: GenServer.reply(caller, confirmed_reply(status))
    for w <- st.waiters, do: GenServer.reply(w, {:error, :daemon_exited})
    {:noreply, %{st | exit_status: status, ready: false, killers: [], waiters: []}}
  end

  def terminate(_, st) do
    # A kill of this owner closes the Port: EOF reaches the guardian, which kills and reaps the daemon.
    File.rm_rf(st.dir)
    :ok
  end

  # The guardian's reaped statuses: 42 = killed on the stop byte and waited; 0/67/68/69 = the child ended on its own
  # and was waited (67 = a non-zero exit, which is what a SIGKILLed daemon reports). A signalled GUARDIAN shows here as
  # 128+signal from the port, and that is no reap of the daemon at all: `stop_unconfirmed`.
  defp confirmed_reply(status) when status in [0, 42, 67, 68, 69], do: :ok
  defp confirmed_reply(_), do: {:error, :stop_unconfirmed}

  defp stop_child(port) do
    Port.command(port, "x")
  rescue
    ArgumentError -> false
  end
end

defmodule HyperSurface.RemoteResident do
  @moduledoc """
  Lab-only owner of a RESIDENT daemon this runtime did NOT start: TRVM's `residentd.mjs --port N --bind ADDR` on another
  host (a lab machine over the LAN), started out of band. Same frames as the private-socket kind; two things are different
  by construction and are said, not hidden. (1) There is no guardian, so there is NO kernel witness for the daemon: a
  cancel the host does not confirm, or a connection that closes with no host word, is `stop_unconfirmed` -- `kill/1`
  cannot kill anything and says so. (2) Nothing on the remote host is trusted: the receipt names the host and the module
  digest the daemon reports, and the reference gate + film oracle are what decide whether its bytes are right (F-D).
  Readiness is a connect probe, bounded by the connect timeout; the endpoint is re-probed on every `socket/1`.
  """
  use GenServer

  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @doc "The TCP endpoint a job connects to, after a connect probe; `{:error, :not_ready}` when the host does not answer."
  def socket(pid), do: GenServer.call(pid, :socket, 15_000)

  @doc "There is no kernel witness for a remote daemon: a kill is never confirmed."
  def kill(_pid), do: {:error, :stop_unconfirmed}

  @doc "What a job's reply carries about the executor that produced it."
  def identity(pid), do: GenServer.call(pid, :identity)

  def stop(pid), do: GenServer.stop(pid)

  def init(config) do
    {:ok,
     %{
       host: to_charlist(config.host),
       port: config.port,
       connect_timeout_ms: config[:connect_timeout_ms] || 2_000
     }}
  end

  def handle_call(:socket, _, st) do
    case :gen_tcp.connect(
           st.host,
           st.port,
           [:binary, packet: 4, active: false],
           st.connect_timeout_ms
         ) do
      {:ok, s} ->
        :gen_tcp.close(s)
        {:reply, {:ok, {:tcp, st.host, st.port}}, st}

      {:error, reason} ->
        {:reply, {:error, {:not_ready, reason}}, st}
    end
  end

  def handle_call(:identity, _, st),
    do: {:reply, %{"executor" => "remote", "host" => to_string(st.host), "port" => st.port}, st}
end

defmodule HyperSurface.ResidentJob do
  @moduledoc """
  One job on the resident daemon: its own connection, one `{id, term}` frame, one reply. The reply's `jobRetired: true`
  (a candidate posted by a worker that stays alive) is the warm-path barrier the bridge forwards on; a cancel is a
  cancel frame answered by the host with `workerExited: true` after it terminated the worker, and a cancel the host does
  not confirm within its bound becomes a kill of the whole daemon through the executor (the kernel's witness), whose
  reaped status is the confirmation. Nothing here mints authority; the bridge's slot, basis and once-only take stand.
  """
  use GenServer

  def start(bridge, op, input, config),
    do: GenServer.start(__MODULE__, {bridge, op, input, config})

  def cancel(pid) do
    GenServer.call(pid, :cancel, 8_000)
  catch
    :exit, _ -> {:error, :stop_unconfirmed}
  end

  # The executor a job talks to: the private-socket kind (a daemon this runtime owns through the guardian) or the remote
  # kind (a daemon on another host, no guardian). Both answer `socket/1`, `kill/1` and `identity/1`.
  defp executor_module(config), do: config[:executor_module] || HyperSurface.ResidentExecutor

  defp connect({:tcp, host, port}),
    do: :gen_tcp.connect(host, port, [:binary, packet: 4, active: true], 500)

  defp connect(path) when is_binary(path),
    do: :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: true], 500)

  def init({bridge, op, input, config}) do
    Process.monitor(bridge)

    with {:ok, endpoint} <- executor_module(config).socket(config.executor),
         {:ok, sock} <- connect(endpoint) do
      :ok = :gen_tcp.send(sock, JSON.encode!(%{id: 1, term: input}))
      timer = Process.send_after(self(), :deadline, config[:timeout_ms] || 2_000)

      {:ok,
       %{
         bridge: bridge,
         op: op,
         sock: sock,
         timer: timer,
         config: config,
         done: false,
         cancelling: false,
         callers: []
       }}
    else
      {:error, reason} -> {:stop, {:executor_unavailable, reason}}
    end
  end

  def handle_call(:cancel, _from, %{done: true} = st), do: {:reply, :ok, st}

  def handle_call(:cancel, from, st) do
    request_cancel(st)
    {:noreply, %{st | cancelling: true, callers: [from | st.callers]}}
  end

  def handle_info(:deadline, %{done: false} = st) do
    request_cancel(st)
    {:noreply, %{st | cancelling: true}}
  end

  def handle_info(:deadline, st), do: {:noreply, st}

  def handle_info({:tcp, sock, data}, %{sock: sock} = st) do
    case JSON.decode(data) do
      {:ok, %{"id" => 1} = reply} -> finish(reply, st)
      _ -> {:noreply, st}
    end
  end

  def handle_info({:tcp_closed, sock}, %{sock: sock, done: false} = st) do
    # The connection closed under the job with no host word: the daemon died, or it dropped the connection. Either
    # way the job's stop is exactly as unconfirmed as a cancel the host never answered, so it takes the same road --
    # the kernel's witness through the executor (a stop byte, then the guardian's reaped status for the daemon as a
    # whole; if the daemon is already dead the guardian has that status within its poll). A reaped status confirms
    # the absence and the slot ends `executor_failed`, never a result; anything else stays `stop_unconfirmed`.
    Process.cancel_timer(st.timer)
    answer = executor_module(st.config).kill(st.config.executor)
    {:noreply, %{st | done: true} |> conclude({:closed, answer})}
  end

  def handle_info({:DOWN, _, :process, bridge, _}, %{bridge: bridge} = st) do
    request_cancel(st)
    {:noreply, %{st | cancelling: true}}
  end

  def handle_info({:cancel_bound, _}, %{done: true} = st), do: {:noreply, st}

  def handle_info({:cancel_bound, _}, st) do
    # the host did not answer the cancel within its bound: the kernel's witness instead, at the cost of the pool
    answer = executor_module(st.config).kill(st.config.executor)
    {:noreply, %{st | done: true} |> conclude({:killed, answer})}
  end

  def handle_info(:retire, st), do: {:stop, :normal, st}

  def handle_info(_, st), do: {:noreply, st}

  defp request_cancel(%{cancelling: true}), do: :ok

  defp request_cancel(st) do
    :gen_tcp.send(st.sock, JSON.encode!(%{id: 1, cancel: true}))
    Process.send_after(self(), {:cancel_bound, 1}, st.config[:cancel_bound_ms] || 3_000)
    :ok
  end

  defp finish(reply, st) do
    Process.cancel_timer(st.timer)
    st = %{st | done: true}

    cond do
      st.cancelling ->
        # the host's own account of the stop; a terminate it could not confirm is `indeterminate`
        confirmed = reply["workerExited"] == true and reply["status"] in ["cancelled", "deadline"]
        {:noreply, conclude(st, if(confirmed, do: :confirmed, else: :unconfirmed))}

      reply["status"] == "candidate" and reply["jobRetired"] == true ->
        send(st.bridge, {:result, st.op, with_identity(reply, st)})
        {:noreply, conclude(st, :retired)}

      reply["status"] == "candidate" and reply["workerExited"] == true ->
        send(st.bridge, {:result, st.op, with_identity(reply, st)})
        {:noreply, conclude(st, :confirmed)}

      reply["workerExited"] == true ->
        {:noreply, conclude(st, :confirmed)}

      reply["status"] == "refused" ->
        # refused before dispatch: no worker ran, nothing to stop -- the one-shot path's guardian-67 shape
        {:noreply, conclude(st, :confirmed)}

      true ->
        {:noreply, conclude(st, :unconfirmed)}
    end
  end

  defp with_identity(reply, st),
    do: Map.merge(reply, executor_module(st.config).identity(st.config.executor))

  defp conclude(st, how) do
    :gen_tcp.close(st.sock)

    {msg, answer} =
      case how do
        :retired -> {{:resident_retired, st.op}, :ok}
        :confirmed -> {{:resident_confirmed, st.op}, :ok}
        {:killed, :ok} -> {{:resident_confirmed, st.op}, :ok}
        {:killed, other} -> {{:resident_unconfirmed, st.op}, other}
        {:closed, :ok} -> {{:resident_confirmed, st.op}, :ok}
        {:closed, other} -> {{:resident_unconfirmed, st.op}, other}
        :unconfirmed -> {{:resident_unconfirmed, st.op}, {:error, :stop_unconfirmed}}
      end

    send(st.bridge, msg)
    for caller <- st.callers, do: GenServer.reply(caller, answer)
    Process.send_after(self(), :retire, 0)
    %{st | callers: []}
  end

  def terminate(_, _), do: :ok
end
