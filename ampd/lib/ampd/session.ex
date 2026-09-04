defmodule Ampd.Session do
  @moduledoc "Ambient context: workspace, current run, retired run ids."
  use GenServer
  @store "session"
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
  @participant_mutations ~w(close_store load_state world end_run reset)a

  defp ask(msg, timeout \\ 5_000) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg
    Ampd.Participant.call(__MODULE__, msg, class(tag), timeout: timeout)
  end

  @doc false
  # Public so the closure gate and the falsifiers read the classification
  # rather than infer it.
  def class(tag), do: if(tag in @participant_mutations, do: :mutate, else: :read)

  @impl true
  def init(:ok) do
    case Ampd.Store.boot(@store, &initial/0) do
      {:ok, tab, s} -> {:ok, %{tab: tab, s: s, sealed: nil}}
      {:sealed, reason} -> {:ok, %{tab: nil, s: sealed_state(), sealed: reason}}
    end
  end
  @doc """
  What a sealed registry serves: nothing. A sealed store's persisted
  truth is unknown or untrusted, so projecting `initial/0` would hand
  callers fabricated defaults — pack policies that were never
  installed, a workspace that was never opened. Neutral and empty is
  the only honest projection; `Ampd.Gateway` turns the seal into a
  named refusal before any of it is reachable.
  """
  def sealed_state, do: %{"world" => nil, "run" => nil, "seq" => 0, "retired" => MapSet.new()}

  def sealed, do: ask(:sealed)
  def close_store, do: ask(:close_store)
  def load_state(s), do: ask({:load_state, s})
  def initial, do: %{"world" => "trvm", "run" => "run-b51", "seq" => 51, "retired" => MapSet.new()}
  def ctx do
    s = ask(:snap)
    %{"actor" => "kestrel", "workspace" => s["world"], "run" => s["run"], "placement" => nil}
  end
  def run, do: ask(:snap)["run"]
  def retired?(r), do: ask({:retired?, r})
  def set_world(w), do: ask({:world, w})
  def end_run, do: ask(:end_run)
  def run_or(default) do
    case Process.whereis(__MODULE__) do
      nil -> default
      _ -> run()
    end
  end
  def reset, do: ask(:reset)
  # --- ordered-authority boundary -------------------------------------
  # These mutations are served only when the caller IS the total order.
  @ordered_ops [:world, :end_run, :reset, :load_state]
  @impl true
  def handle_call(msg, from, st)
      when (is_tuple(msg) and elem(msg, 0) in @ordered_ops) or
             (is_atom(msg) and msg in @ordered_ops) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg

    cond do
      not Ampd.Ordered.from_coordinator?(from) ->
        {:reply, {:refused, Ampd.Ordered.refusal(tag, __MODULE__)}, st}

      # A sealed store refuses by name. Raising here would kill the
      # coordinator too, turning one lost store into a node-wide outage.
      st.sealed != nil and tag != :load_state ->
        {:reply, {:refused, Ampd.Ordered.sealed_refusal(st.sealed, tag, __MODULE__)}, st}

      true ->
        handle_ordered(msg, st)
    end
  end
  @impl true
  def handle_call(:sealed, _f, st), do: {:reply, st.sealed, st}
  def handle_call(:close_store, _f, st) do
    if st.tab, do: :dets.close(st.tab)
    {:reply, :ok, %{st | tab: nil}}
  end
  def handle_call(:snap, _f, %{s: s} = st), do: {:reply, s, st}
  def handle_call({:retired?, r}, _f, %{s: s} = st), do: {:reply, MapSet.member?(s["retired"], r), st}

  # --- ordered implementations (reached only via the guard above) ----
  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)
    {:reply, :ok, %{st | tab: tab, s: Ampd.Store.save(tab, s), sealed: nil}}
  end

  def handle_ordered({:world, w}, %{tab: tab, s: s} = st), do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, %{s | "world" => w})}}

  def handle_ordered(:end_run, %{tab: tab, s: s} = st) do
    old = s["run"]
    seq = s["seq"] + 1
    s2 = %{s | "run" => "run-b#{seq}", "seq" => seq,
               "retired" => MapSet.put(s["retired"], old)}
    {:reply, old, %{st | s: Ampd.Store.save(tab, s2)}}
  end

  def handle_ordered(:reset, %{tab: tab} = st), do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, initial())}}
end
