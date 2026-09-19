defmodule HyperSurface.ExecutionFence do
  @moduledoc """
  Opt-in laboratory physical-execution fence, shared across bridge incarnations.
  One registered owner per VM; one trusted fixed directory per participating set.
  A pending attempt is synced before launch. Only its guardian's exact receipt
  proves absence. Process death and elapsed time never clear a pending attempt.
  Not a distributed store or an authority grant.
  """
  use GenServer
  @table __MODULE__

  def start_link(dir), do: GenServer.start_link(__MODULE__, dir, name: __MODULE__)
  def claim(lane) when is_binary(lane), do: call({:claim, lane})
  def claim(_), do: {:error, :invalid_fence_key}
  def reconcile(lane), do: call({:reconcile, lane})

  defp call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _ -> {:error, :fence_unavailable}
  end

  def init(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    marker = Path.join(dir, "initialized")
    store = Path.join(dir, "pending.dets")

    state =
      case File.read(marker) do
        {:ok, "execution-fence@1"} ->
          if(File.regular?(store), do: :existing, else: :missing_store)

        {:error, :enoent} ->
          if(File.ls!(dir) == [], do: :fresh, else: :orphaned)

        _ ->
          :untrusted_marker
      end

    if state in [:fresh, :existing] do
      if state == :fresh, do: File.write!(marker, "execution-fence@1", [:exclusive, :sync])
      receipts = Path.join(dir, "receipts")
      File.mkdir_p!(receipts)

      case :dets.open_file(@table, file: String.to_charlist(store), type: :set, repair: false) do
        {:ok, table} ->
          :ok = :dets.sync(table)
          {:ok, %{table: table, receipts: receipts}}

        {:error, reason} ->
          {:stop, {:fence_store_unavailable, reason}}
      end
    else
      {:stop, {:fence_store_unavailable, state}}
    end
  end

  def handle_call({:claim, lane}, _, st) do
    case reconcile_entry(lane, st) do
      :ok ->
        token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        receipt = Path.join(st.receipts, token)
        :ok = :dets.insert(st.table, {lane, token})
        :ok = :dets.sync(st.table)
        {:reply, {:ok, %{token: token, receipt: receipt, lane: lane}}, st}

      error ->
        {:reply, error, st}
    end
  end

  def handle_call({:reconcile, lane}, _, st), do: {:reply, reconcile_entry(lane, st), st}

  defp reconcile_entry(lane, st) do
    case :dets.lookup(st.table, lane) do
      [] ->
        :ok

      [{^lane, token}] when is_binary(token) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, token) do
          receipt = Path.join(st.receipts, token)

          case File.read(receipt) do
            {:ok, ^token} ->
              :ok = :dets.delete(st.table, lane)
              :ok = :dets.sync(st.table)
              # Delete proof only after the pending record's removal is synced.
              File.rm(receipt)
              :ok

            _ ->
              {:error, :execution_fenced}
          end
        else
          {:error, :execution_fenced}
        end

      _ ->
        {:error, :execution_fenced}
    end
  end

  def terminate(_, st), do: :dets.close(st.table)
end
