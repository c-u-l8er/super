defmodule Ampd.CapabilityRegistry do
  @moduledoc "What exists: installed packs, versions, declared surfaces, policies."
  use GenServer
  @store "capability_registry"
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
  def sealed_state, do: %{}

  def sealed, do: GenServer.call(__MODULE__, :sealed)
  def close_store, do: GenServer.call(__MODULE__, :close_store)
  def load_state(s), do: GenServer.call(__MODULE__, {:load_state, s})
  def initial do
    %{"github" => %{"installation" => "installed", "version" => "1.4.2",
        "policy" => %{"source_data" => "private",
                      "secret" => %{"ref" => "github.oauth", "residency" => ["local", "fleet"]}},
        "surface" => %{
          "repo.read"  => %{"cls" => "observe"},
          "issue.read" => %{"cls" => "observe"},
          "pr.draft"   => %{"cls" => "local_mutate"},
          "pr.create"  => %{"cls" => "remote_commit", "approval" => "every_effect"},
          "pr.merge"   => %{"cls" => "destructive_admin", "deny" => true}}},
      "browser" => %{"installation" => "installed", "version" => "0.9.0",
        "surface" => %{
          "public.navigate" => %{"cls" => "observe"},
          "inspect"         => %{"cls" => "observe"},
          "form.submit"     => %{"cls" => "remote_commit", "approval" => "every_effect"}}},
      "postgres" => %{"installation" => "available", "version" => "0.9.1",
        "policy" => %{"source_data" => "private"},
        "surface" => %{
          "schema.read" => %{"cls" => "observe"},
          "query.read"  => %{"cls" => "observe"},
          "query.write" => %{"cls" => "remote_write", "deny" => true}}},
      "mcpimport" => %{"installation" => "builtin"}}
  end
  def get(pack), do: GenServer.call(__MODULE__, {:get, pack})
  def all, do: GenServer.call(__MODULE__, :all)
  def install_postgres, do: GenServer.call(__MODULE__, :install_postgres)
  def update_github, do: GenServer.call(__MODULE__, :update_github)
  def reset, do: GenServer.call(__MODULE__, :reset)
  # --- ordered-authority boundary -------------------------------------
  # These mutations are served only when the caller IS the total order.
  @ordered_ops [:install_postgres, :update_github, :reset, :load_state]
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
  def handle_call({:get, pack}, _f, %{s: s} = st), do: {:reply, Map.get(s, pack), st}
  def handle_call(:all, _f, %{s: s} = st), do: {:reply, s, st}


  # --- ordered implementations (reached only via the guard above) ----
  # These were `handle_cast` until C1.1.0. A cast carries no caller, so the
  # ordered-authority guard could not see who sent it — and pack policy is
  # authority, because `source_data` and secret residency decide where an
  # effect may run. A mutation that cannot be attributed cannot be ordered.
  def handle_ordered(:install_postgres, %{tab: tab, s: s} = st),
    do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, put_in(s, ["postgres", "installation"], "installed"))}}

  def handle_ordered(:update_github, %{tab: tab, s: s} = st) do
    s = put_in(s, ["github", "version"], "1.5.0")
    s = put_in(s, ["github", "surface", "issue.write"],
          %{"cls" => "remote_draft", "introduced" => "1.5.0"})
    {:reply, :ok, %{st | s: Ampd.Store.save(tab, s)}}
  end

  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)
    {:reply, :ok, %{st | tab: tab, s: Ampd.Store.save(tab, s), sealed: nil}}
  end

  def handle_ordered(:reset, %{tab: tab} = st), do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, initial())}}
end
