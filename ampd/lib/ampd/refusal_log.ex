defmodule Ampd.RefusalLog do
  @moduledoc """
  A bounded ring of recent refusals, so `inspect_refusal` can mean what
  its name says.

  `refusal@1` already mints a `correlation_id` and hands it to both
  channels. Until now nothing could be looked up by one: `inspect_refusal`
  returned a literal `nil`, which is a command whose name claims a
  semantics it does not have. Either implement the lookup or remove the
  command — this is the implementation.

  The ring is **in memory and bounded**. A refusal is a diagnostic, not
  authority: losing one costs an explanation, not a decision, and an
  unbounded refusal log is a denial-of-service surface an agent can fill
  by retrying. The receipt ledger and the effect journal are the durable
  records; this is the thing that tells you *why the door did not open*
  ten seconds ago.

  Looking one up is projected exactly like receiving it was — an agent
  sees its own `code`/`public_message`, an operator sees
  `operator_detail`. That makes the dual projection checkable twice, from
  two directions, against one stored object.
  """
  use GenServer

  @capacity 200

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{ring: [], n: 0}}

  @doc """
  Record a refusal as it is minted. Tolerates the process being absent:
  refusals are minted during boot, before this ring exists, and a
  diagnostic that could crash a boot would be worse than a missing entry.
  """
  def record(refusal) do
    case Process.whereis(__MODULE__) do
      nil -> refusal
      _ -> GenServer.cast(__MODULE__, {:record, refusal}); refusal
    end
  end

  @doc "The stored refusal for a correlation id, unprojected. `nil` if it aged out."
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc "Most recent first, for the operator projection."
  def recent(n \\ 20), do: GenServer.call(__MODULE__, {:recent, n})

  def count, do: GenServer.call(__MODULE__, :count)
  def reset, do: GenServer.call(__MODULE__, :reset)
  def capacity, do: @capacity

  @impl true
  def handle_cast({:record, r}, st) do
    # `recent_refusals` is in the operator projection, so a refusal landing
    # is a visible change — and it is emphatically not an authority
    # mutation. Second clock; see `Ampd.AuthorityCoordinator.touched/0`.
    #
    # This is also why `Ampd.CommandSpec` had to gain `retry:`. Recording
    # advances the view revision, and the view revision is what
    # `Ampd.Projection.framed/2` compares — so a *speculative* read that
    # constructs a refusal would invalidate its own attempt and retry, and
    # record again. Reads that can refuse take the ordered path once.
    Ampd.AuthorityCoordinator.touched()
    ring = [r | st.ring] |> Enum.take(@capacity)
    {:noreply, %{st | ring: ring, n: st.n + 1}}
  end

  @impl true
  def handle_call({:get, id}, _f, st),
    do: {:reply, Enum.find(st.ring, &(&1["correlation_id"] == id)), st}

  def handle_call({:recent, n}, _f, st), do: {:reply, Enum.take(st.ring, n), st}
  def handle_call(:count, _f, st), do: {:reply, length(st.ring), st}
  def handle_call(:reset, _f, st), do: {:reply, :ok, %{st | ring: [], n: 0}}
end
