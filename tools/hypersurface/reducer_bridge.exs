Code.require_file("node_executor.exs", __DIR__)
Code.require_file("resident_executor.exs", __DIR__)

defmodule HyperSurface.ReducerBridge do
  @moduledoc """
  Explicit integration experiment, not loaded by Ampd.Application or CommandSpec.
  A trusted test/operator installs one executor at construction. Request callers
  supply neither executor nor profile. One ephemeral slot retains the outcome
  until its owner consumes it. No durable execution or authority is minted here.
  """
  use GenServer
  alias Ampd.{AuthorityCoordinator, Loci, Peer, Worker, World}

  defmodule Handle do
    @enforce_keys [:pid, :admission]
    defstruct [:pid, :admission]
  end

  def start_link(executor), do: GenServer.start_link(__MODULE__, executor)

  def start_link(executor, admission: :bounded) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, {:bounded, executor}) do
      {:ok, GenServer.call(pid, :admission_handle)}
    end
  end

  def stop(%Handle{pid: pid}), do: GenServer.stop(pid)
  def stop(pid), do: GenServer.stop(pid)

  def submit(%Handle{pid: pid, admission: table}, peer, lane, input) do
    token = make_ref()
    entry = {:permit, token, self()}

    if :ets.insert_new(table, entry) do
      # Only the server releases a submitted permit. Caller timeout/death must
      # not admit more work while this request is still queued or executing.
      GenServer.call(pid, {:reserved_submit, token, peer, lane, input})
    else
      {:refused, :overloaded}
    end
  rescue
    ArgumentError -> {:refused, :bridge_unavailable}
  end

  def submit(server, peer, lane, input), do: GenServer.call(server, {:submit, peer, lane, input})
  def take(%Handle{pid: pid}, peer, op), do: take(pid, peer, op)
  def take(server, peer, op), do: GenServer.call(server, {:take, peer, op})
  def cancel(%Handle{pid: pid}, peer, op), do: cancel(pid, peer, op)
  def cancel(server, peer, op), do: GenServer.call(server, {:cancel, peer, op})

  @doc "Wait for readiness without polling, then collect through the normal authority check."
  def await(server, peer, op, timeout \\ 5_000)
  def await(%Handle{pid: pid}, peer, op, timeout), do: await(pid, peer, op, timeout)

  def await(server, peer, op, timeout) when is_integer(timeout) and timeout >= 0 do
    # Already-completed tiny jobs retain the existing one-call fast path.
    case take(server, peer, op) do
      :pending -> await_pending(server, peer, op, timeout)
      result -> result
    end
  end

  defp await_pending(server, peer, op, timeout) do
    # Demonitoring also deactivates the reply alias, discarding late notices.
    # Timeout bounds the readiness wait, not the final authority collection.
    ref = :erlang.monitor(:process, server, [{:alias, :demonitor}])

    try do
      case GenServer.call(server, {:watch, peer, op, ref}) do
        :ready ->
          take(server, peer, op)

        :watching ->
          receive do
            {:ready, ^ref} -> take(server, peer, op)
            {:DOWN, ^ref, :process, _, _} -> {:refused, :bridge_unavailable}
          after
            timeout -> {:error, :await_timeout}
          end

        refusal ->
          refusal
      end
    after
      Process.demonitor(ref, [:flush])
      GenServer.cast(server, {:unwatch, op, ref})
    end
  end

  def init({:bounded, executor}) do
    table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
    Process.send_after(self(), :sweep_admission, 100)
    {:ok, %{executor: executor, slot: nil, admission: table}}
  end

  def init(executor), do: {:ok, %{executor: executor, slot: nil, admission: nil}}

  def handle_call(:admission_handle, _, st) do
    {:reply, %Handle{pid: self(), admission: st.admission}, st}
  end

  def handle_call({:reserved_submit, token, peer, lane, input}, from, st) do
    case st.admission && :ets.lookup(st.admission, :permit) do
      [{:permit, ^token, caller} = entry] when caller == elem(from, 0) ->
        try do
          admit(peer, lane, input, st)
        after
          :ets.delete_object(st.admission, entry)
        end

      _ ->
        {:reply, {:refused, :overloaded}, st}
    end
  end

  def handle_call({:submit, _, _, _}, _, %{admission: table} = st) when table != nil,
    do: {:reply, {:refused, :admission_required}, st}

  def handle_call({:submit, peer, lane, input}, _, st), do: admit(peer, lane, input, st)

  def handle_call({:watch, peer, op, ref}, from, %{slot: %{peer: peer, op: op} = slot} = st) do
    cond do
      slot.exited or slot.stop_unconfirmed ->
        {:reply, :ready, st}

      slot.waiter != nil ->
        {:reply, {:refused, :await_in_progress}, st}

      true ->
        waiter = %{ref: ref, monitor: Process.monitor(elem(from, 0))}
        {:reply, :watching, %{st | slot: %{slot | waiter: waiter}}}
    end
  end

  def handle_call({:cancel, peer, op}, _, %{slot: %{peer: peer, op: op} = slot} = st) do
    # Legacy callbacks only suppress results. The explicit managed adapter
    # answers :ok only after its guardian has reaped the exact Node child.
    answer =
      cond do
        slot.stop_unconfirmed -> {:error, :stop_unconfirmed}
        slot.exited -> :ok
        slot.managed -> HyperSurface.NodeExecutor.cancel(slot.pid)
        # the resident adapter answers :ok only on the host's own stop witness (workerExited after terminate,
        # or jobRetired before the cancel arrived) or on the daemon's reaped status after a kill
        slot.resident -> HyperSurface.ResidentJob.cancel(slot.pid)
        true -> :ok
      end

    {:reply, answer, %{st | slot: %{slot | cancelled: true, result: nil}}}
  end

  def handle_call({:take, peer, op}, _, %{slot: %{peer: peer, op: op} = slot} = st) do
    if slot.stop_unconfirmed do
      {:reply, {:refused, :stop_unconfirmed}, st}
    else
      if slot.exited do
        result =
          ordered_read(fn ->
            cond do
              slot.cancelled ->
                {:refused, :cancelled}

              basis(peer, slot.lane) != {:ok, slot.basis} ->
                {:refused, :owner_changed}

              slot.result == nil ->
                {:refused, :executor_failed}

              true ->
                {:ok,
                 %{
                   candidate: slot.result,
                   input_digest: slot.input_digest,
                   occupancy_epoch: slot.basis.occupancy_epoch
                 }}
            end
          end)

        {:reply, result, %{st | slot: nil}}
      else
        {:reply, :pending, st}
      end
    end
  end

  def handle_call(_, _, st), do: {:reply, {:refused, :operation_unknown}, st}

  def handle_info({:result, op, result}, %{slot: %{op: op} = slot} = st) do
    # A result message alone is not proof that its executor exited.
    result = if slot.cancelled, do: nil, else: result
    {:noreply, %{st | slot: %{slot | result: result}}}
  end

  def handle_info({:DOWN, monitor, :process, _, reason}, %{slot: %{monitor: monitor} = slot} = st) do
    result = if reason == :normal, do: slot.result, else: nil

    uncertain =
      (slot.managed and not slot.node_reaped) or
        (slot.resident and slot.resident_witness not in [:retired, :confirmed])

    slot = %{slot | result: result, exited: not uncertain, stop_unconfirmed: uncertain}
    {:noreply, %{st | slot: notify_ready(slot)}}
  end

  def handle_info(
        {:DOWN, monitor, :process, _, _},
        %{slot: %{waiter: %{monitor: monitor}} = slot} = st
      ),
      do: {:noreply, %{st | slot: %{slot | waiter: nil}}}

  def handle_info({:node_reaped, op}, %{slot: %{op: op} = slot} = st) do
    {:noreply, %{st | slot: %{slot | node_reaped: true}}}
  end

  # The resident job's three endings: a retired job id (the warm-path barrier, TRVM resident README §2), a stop the
  # host or the kernel confirmed, or neither -- which is exactly the one-shot path's `stop_unconfirmed`.
  def handle_info({:resident_retired, op}, %{slot: %{op: op} = slot} = st),
    do: {:noreply, %{st | slot: %{slot | resident_witness: :retired}}}

  def handle_info({:resident_confirmed, op}, %{slot: %{op: op} = slot} = st),
    do: {:noreply, %{st | slot: %{slot | resident_witness: :confirmed}}}

  def handle_info({:resident_unconfirmed, op}, %{slot: %{op: op} = slot} = st) do
    {:noreply,
     %{
       st
       | slot:
           notify_ready(%{
             slot
             | result: nil,
               stop_unconfirmed: true,
               resident_witness: :unconfirmed
           })
     }}
  end

  def handle_info({:stop_unconfirmed, op}, %{slot: %{op: op} = slot} = st) do
    {:noreply, %{st | slot: notify_ready(%{slot | result: nil, stop_unconfirmed: true})}}
  end

  def handle_info(:sweep_admission, %{admission: table} = st) when table != nil do
    # Recover the narrow death-before-enqueue window. Never reclaim a live
    # caller's permit on time alone; that could release an in-flight request.
    case :ets.lookup(table, :permit) do
      [{:permit, _, caller} = entry] ->
        if not Process.alive?(caller), do: :ets.delete_object(table, entry)

      [] ->
        :ok
    end

    Process.send_after(self(), :sweep_admission, 100)
    {:noreply, st}
  end

  def handle_info(_, st), do: {:noreply, st}

  def handle_cast(
        {:unwatch, op, ref},
        %{slot: %{op: op, waiter: %{ref: ref} = waiter} = slot} = st
      ) do
    Process.demonitor(waiter.monitor, [:flush])
    {:noreply, %{st | slot: %{slot | waiter: nil}}}
  end

  def handle_cast({:unwatch, _, _}, st), do: {:noreply, st}

  defp notify_ready(%{waiter: nil} = slot), do: slot

  defp notify_ready(%{waiter: waiter} = slot) do
    send(waiter.ref, {:ready, waiter.ref})
    Process.demonitor(waiter.monitor, [:flush])
    %{slot | waiter: nil}
  end

  defp admit(peer, lane, input, st) do
    answer = ordered_read(fn -> basis(peer, lane) end)

    cond do
      not match?({:ok, _}, answer) ->
        {:reply, answer, st}

      not is_binary(input) or byte_size(input) > 65536 ->
        {:reply, {:refused, :input_limit}, st}

      st.slot != nil ->
        {:reply, {:refused, :busy}, st}

      true ->
        {:ok, bound} = answer
        op = make_ref()
        parent = self()
        executor = st.executor

        case start_executor(executor, parent, op, input, lane) do
          {:error, reason} when reason in [:execution_fenced, :fence_unavailable] ->
            {:reply, {:refused, reason}, st}

          {:error, _} ->
            {:reply, {:refused, :executor_unavailable}, st}

          {:ok, pid, monitor} ->
            slot = %{
              op: op,
              peer: peer,
              lane: lane,
              basis: bound,
              input_digest: Ampd.Core.intent_digest(input),
              pid: pid,
              monitor: monitor,
              result: nil,
              exited: false,
              cancelled: false,
              managed: match?({:managed_node, _}, executor),
              resident:
                match?({:managed_resident, _}, executor) or
                  match?({:remote_resident, _}, executor),
              resident_witness: nil,
              stop_unconfirmed: false,
              node_reaped: false,
              waiter: nil
            }

            {:reply, {:ok, op}, %{st | slot: slot}}
        end
    end
  end

  defp start_executor({:managed_node, config}, parent, op, input, lane) do
    config = Map.put(config, :fence_key, lane)

    case HyperSurface.NodeExecutor.start(parent, op, input, config) do
      {:ok, pid} -> {:ok, pid, Process.monitor(pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_executor({:managed_resident, config}, parent, op, input, _lane) do
    case HyperSurface.ResidentJob.start(parent, op, input, config) do
      {:ok, pid} -> {:ok, pid, Process.monitor(pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The remote resident kind: the same job over TCP to a daemon on another host, no guardian (RemoteResident's moduledoc).
  defp start_executor({:remote_resident, config}, parent, op, input, _lane) do
    config = Map.put(config, :executor_module, HyperSurface.RemoteResident)

    case HyperSurface.ResidentJob.start(parent, op, input, config) do
      {:ok, pid} -> {:ok, pid, Process.monitor(pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_executor(callback, parent, op, input, _lane) when is_function(callback, 1) do
    {pid, monitor} =
      spawn_monitor(fn ->
        result = callback.(input)
        send(parent, {:result, op, result})
      end)

    {:ok, pid, monitor}
  end

  # Admission and collection inspect authority; they do not mutate it.
  # Keep their ordering with mutations, execute refusal-producing reads once,
  # and avoid announcing a fictitious authority change to subscribers.
  defp ordered_read(fun) do
    {_cursor, result} = AuthorityCoordinator.observe_once(fun)
    result
  end

  defp basis(peer_ref, lane_ref) do
    {peer, a} = Peer.occupancy_snapshot(peer_ref)
    lane = Loci.lane(lane_ref)
    # One fresh manifest read per ordered decision: the lineage the occupancy
    # check validates is the lineage this basis records.
    world = World.lineage()

    cond do
      peer == nil or lane == nil ->
        {:refused, :owner_unavailable}

      peer["channel"] != :agent ->
        {:refused, :agent_required}

      true ->
        with {:ok, w} <- Worker.occupancy_worker(a, peer, lane, world) do
          epoch = a["occupancy_epoch"]

          if is_binary(epoch) and w != nil and Peer.occupancy_snapshot(peer_ref) == {peer, a} do
            {:ok,
             %{
               peer: peer_ref,
               peer_epoch: a["peer_epoch"],
               occupancy_epoch: epoch,
               worker: w["id"],
               generation: w["generation"] || 1,
               lane: lane_ref,
               world: world
             }}
          else
            {:refused, :attachment_occurrence_missing}
          end
        end
    end
  end
end
