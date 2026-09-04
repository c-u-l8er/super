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


  # ------------------------------------------------- participant boundary
  #
  # C1.0b·2·1. Inside `Ampd.AuthorityCoordinator`, a bare `GenServer.call`
  # that fails EXITS the caller — and the caller there is the total order,
  # so one participant's fault becomes `seq` back to zero, the projection
  # epoch re-minted, and every subscriber resnapshotting. The reachability
  # census (`tools/ordered-reachability.json`) proves this module is reached
  # while a transaction or an ordered observation is executing.
  #
  # The class is not optional and is not inferred: a crossing whose class
  # the author has not decided is a crossing whose failure cannot be
  # classified either. Every tag NOT named below is a read.
  @participant_mutations ~w(reset)a

  defp ask(msg, timeout \\ 5_000) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg
    Ampd.Participant.call(__MODULE__, msg, class(tag), timeout: timeout)
  end

  @doc false
  # Public so the closure gate and the falsifiers read the classification
  # rather than infer it.
  def class(tag), do: if(tag in @participant_mutations, do: :mutate, else: :read)

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
  def get(id), do: ask({:get, id})

  @doc "Most recent first, for the operator projection."
  def recent(n \\ 20), do: ask({:recent, n})

  def count, do: ask(:count)
  def reset, do: ask(:reset)
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
