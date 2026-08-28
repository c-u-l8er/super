defmodule Ampd.Approvals do
  @moduledoc "Which exact effects await consent — approvals bound to intent digests."
  use GenServer
  @store "approvals"
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
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
  def sealed_state, do: %{"approvals" => [], "seq" => 0}

  def sealed, do: GenServer.call(__MODULE__, :sealed)
  def close_store, do: GenServer.call(__MODULE__, :close_store)
  def load_state(s), do: GenServer.call(__MODULE__, {:load_state, s})
  def initial, do: %{"approvals" => [], "seq" => 36}
  def all, do: GenServer.call(__MODULE__, :all)
  def push(m), do: GenServer.call(__MODULE__, {:push, m})
  def new_pending(fields) do
    GenServer.call(__MODULE__, {:new_pending, fields})
  end
  def mark(id, status, reason \\ nil), do: GenServer.call(__MODULE__, {:mark, id, status, reason})
  def last_pending do
    all() |> Enum.reverse() |> Enum.find(&(&1["status"] == "pending"))
  end
  def reset, do: GenServer.call(__MODULE__, :reset)
  # --- ordered-authority boundary -------------------------------------
  # These mutations are served only when the caller IS the total order.
  @ordered_ops [:push, :new_pending, :mark, :reset, :load_state]
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
  def handle_call(:all, _f, %{s: s} = st), do: {:reply, s["approvals"], st}

  # --- ordered implementations (reached only via the guard above) ----
  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)
    {:reply, :ok, %{st | tab: tab, s: Ampd.Store.save(tab, s), sealed: nil}}
  end

  def handle_ordered({:push, m}, %{tab: tab, s: s} = st), do: {:reply, m, %{st | s: Ampd.Store.save(tab, %{s | "approvals" => s["approvals"] ++ [m]})}}

  def handle_ordered({:new_pending, fields}, %{tab: tab, s: s} = st) do
    id = "ap_" <> String.pad_leading(Integer.to_string(s["seq"]), 4, "0")
    m = Map.merge(%{"id" => id, "status" => "pending"}, fields)
    {:reply, m, %{st | s: Ampd.Store.save(tab, %{s | "approvals" => s["approvals"] ++ [m], "seq" => s["seq"] + 1})}}
  end

  def handle_ordered({:mark, id, status, reason}, %{tab: tab, s: s} = st) do
    approvals = Enum.map(s["approvals"], fn a ->
      if a["id"] == id do
        a = %{a | "status" => status}
        if reason, do: Map.put(a, "stale_reason", reason), else: a
      else
        a
      end
    end)
    {:reply, :ok, %{st | s: Ampd.Store.save(tab, %{s | "approvals" => approvals})}}
  end

  def handle_ordered(:reset, %{tab: tab} = st), do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, initial())}}
end
