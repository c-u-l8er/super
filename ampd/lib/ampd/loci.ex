defmodule Ampd.Loci do
  @moduledoc """
  `workspace@1` · `goal@1` · `lane@1` · `worktree-cap@1` — the durable
  semantic objects, and the store that outlives every Carrier.

  ## What this store is for

  Everything else in `ampd` is authority *about* something. This is the
  something: the positions authority is held **from**. A grant says
  "kestrel may do X"; a Lane says *where kestrel is standing* while it does
  it, and it keeps standing there after the process that was standing
  there dies.

  That is the whole reason this is a store and not a supervision tree. A
  `LaneSupervisor` holding lanes as GenServers would make lane identity a
  property of a running process — and then killing the process would
  destroy the position, which is precisely the failure mode
  `Ampd.Worktree`'s falsifiers exist to refuse. **A Lane is a record. A
  Carrier is a process. They are not the same kind of thing and they do
  not share a lifetime.**

  ## The Lane is the first product-level Locus — provisionally

  D.1.1 treats a Lane as the first executable approximation of an active
  Locus. It is *not* claimed to be the final universal Locus abstraction;
  the point of building it is to find out whether the factorization
  survives contact with a real machine resource. Where the two words are
  both used below, "Lane" is the product object and "Locus" is the role it
  is being tested in.

  ## Why `caps` live here and paths do not

  A `worktree-cap@1` is semantic authority — which Lane may cause which
  class of effect on which resource — so it is World-persistent and it
  belongs beside the Lane that holds it. What it deliberately does **not**
  contain is a filesystem path. It names a `resource_ref`, an opaque id,
  and `Ampd.Worktree` is the only module that can turn one into a path.

  This is the mechanical form of the rule the whole slice is testing:

      knowing a name  ≠  possessing authority

  A Lane that somehow learned `/home/travis/x/lane-a` can do nothing with
  it, because no command in `Ampd.CommandSpec` accepts a path. The only
  thing a Lane can say is *"the resource my capability names"*.

  **This paragraph was false for the whole of D.1.1a and nothing noticed.**
  When `profile` was added to the cap to make the embodiment basis
  recoverable, it brought `facts.worktree_root` — the literal path — with
  it, so the record this module describes as path-free contained one, two
  levels down, on every capability. The prose stayed put because prose is
  not a check.

  It is a check now: `F19f` walks the stored records and every projection
  recursively, and there is a case that re-creates the D.1.1a fact set and
  fails if the walker cannot see it. The rule the episode leaves behind is
  worth more than the fix — **a nested object inherits every disclosure
  rule of the record it is embedded in**, and a "no path" claim about a
  record is a claim about its transitive closure or it is nothing.

  ## Freshness, and why a capability carries four bases

  A capability record surviving on disk is not the same claim as that
  capability still being exercisable. Persistence is not authority. So
  each cap binds the four things whose change would make it a different
  permission than the one that was established:

      world_ref       installation_id + generation — the lineage it was
                      established in. `Ampd.Authority.advance_lineage/2`
                      moves this, and authority does not cross it.

      authority_basis the grant id that conferred it. Revoke the grant and
                      the cap has nothing standing under it.

      profile_basis   a digest over the embodiment facts that decide what
                      the effect *means* — see `Ampd.Locus.profile_digest/0`.

      generation      the cap's own counter, so a superseded cap is
                      distinguishable from the one that replaced it rather
                      than merely absent.

  None of these is a wall-clock timestamp, deliberately. A timestamp
  proves when a record was written and nothing about whether the authority
  it describes is current, and treating it as freshness is the error
  `worktree_created@1` is explicitly forbidden from making.
  """

  use GenServer

  @store "loci"

  @workspace_schema "workspace@1"
  @goal_schema "goal@1"
  @lane_schema "lane@1"
  @cap_schema "worktree-cap@1"

  def workspace_schema, do: @workspace_schema
  def goal_schema, do: @goal_schema
  def lane_schema, do: @lane_schema
  def cap_schema, do: @cap_schema

  @doc """
  The rights a `worktree-cap@1` may carry. **One.**

  This was `["create", "observe"]`, and `create` was never checked by
  anything — `Ampd.Locus.carries?/2` is called for `observe` and for
  nothing else. The rule the list was supposed to be following ("no right
  that the slice does not exercise") was being broken by the list itself.

  The reason it could not be exercised is the interesting part, and it is
  an ontology correction rather than a missing check: **creation is
  authorized by the grant over the Locus, not by the capability over the
  resource.** The capability does not exist until creation has already
  happened, so a `create` right on it could never be the thing that
  permitted the creation.

      worktree.create grant over the Locus
              │  authorizes establishment
              ▼
      the machine resource
              │
              ▼
      worktree-cap@1 over the resource  ──▶ observe

  `delete`, `git_mutate`, `execute` and `delegate` remain imaginable and
  remain absent. A right is added when an operation exercises it **and** a
  negative test proves its absence is enforced — not before.
  """
  @rights ~w(observe)
  def rights, do: @rights

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    case Ampd.Store.boot(@store, &initial/0) do
      {:ok, tab, s} -> {:ok, %{tab: tab, s: s, sealed: nil}}
      {:sealed, reason} -> {:ok, %{tab: nil, s: sealed_state(), sealed: reason}}
    end
  end

  @doc """
  What a sealed store serves: nothing.

  The stakes here are one step higher than for a pack registry. Projecting
  `initial/0` from a sealed loci store would hand callers an **empty**
  world of lanes — and an empty lane table reads as "no lane holds that
  capability", which is indistinguishable from a revocation nobody
  ordered. Fail-closed is the only projection that is not a lie in one
  direction or the other; `Ampd.Locus` turns the seal into a named
  refusal before any of it is reachable.
  """
  def sealed_state,
    do: %{"workspaces" => %{}, "goals" => %{}, "lanes" => %{}, "caps" => %{}, "seq" => 0}

  @doc """
  The zero-authority initial state: no workspace, no goal, no lane, no cap.

  A fresh `ampd` confers nothing, and that includes conferring a position
  to confer things from. Fixtures create lanes; boot does not.
  """
  def initial,
    do: %{"workspaces" => %{}, "goals" => %{}, "lanes" => %{}, "caps" => %{}, "seq" => 0}

  def sealed, do: GenServer.call(__MODULE__, :sealed)
  def close_store, do: GenServer.call(__MODULE__, :close_store)
  def load_state(s), do: GenServer.call(__MODULE__, {:load_state, s})

  # ------------------------------------------------------------- reads
  def workspaces, do: GenServer.call(__MODULE__, {:all, "workspaces"})
  def goals, do: GenServer.call(__MODULE__, {:all, "goals"})
  def lanes, do: GenServer.call(__MODULE__, {:all, "lanes"})
  def caps, do: GenServer.call(__MODULE__, {:all, "caps"})

  def workspace(id), do: GenServer.call(__MODULE__, {:get, "workspaces", id})
  def goal(id), do: GenServer.call(__MODULE__, {:get, "goals", id})
  def lane(id), do: GenServer.call(__MODULE__, {:get, "lanes", id})
  def cap(id), do: GenServer.call(__MODULE__, {:get, "caps", id})

  @doc "Every cap held by one lane, active or not."
  def caps_of(lane_id),
    do: caps() |> Enum.filter(fn {_, c} -> c["locus_ref"] == lane_id end) |> Map.new()

  @doc """
  The active cap naming `resource_ref`, or `nil`.

  Deliberately **not** filtered by lane: a caller asking "who holds this
  resource" must get the true answer, so that `Ampd.Locus` can refuse a
  cross-lane claim by comparing rather than by failing to find. A lookup
  that silently returns `nil` for another lane's cap would refuse with
  `capability-unknown` and teach the caller nothing about whether the
  resource exists — and would make F2 and F1 indistinguishable in the
  evidence.
  """
  def cap_for_resource(resource_ref) do
    caps()
    |> Enum.find_value(fn {_, c} ->
      if c["resource_ref"] == resource_ref and c["status"] == "active", do: c
    end)
  end

  # --------------------------------------------------------- mutations
  def create_workspace(f), do: GenServer.call(__MODULE__, {:create, "workspaces", "ws_", f})
  def create_goal(f), do: GenServer.call(__MODULE__, {:create, "goals", "gl_", f})
  def create_lane(f), do: GenServer.call(__MODULE__, {:create, "lanes", "ln_", f})
  def create_cap(f), do: GenServer.call(__MODULE__, {:create, "caps", "wc_", f})
  def put_cap(id, patch), do: GenServer.call(__MODULE__, {:patch, "caps", id, patch})
  def put_lane(id, patch), do: GenServer.call(__MODULE__, {:patch, "lanes", id, patch})
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- ordered-authority boundary -------------------------------------
  # Creating a Lane is creating a position from which authority may be
  # established, and minting a cap is minting authority outright. Both are
  # served only when the caller IS the total order — the same rule the
  # grant registry has held since C1.1.0, for the same reason: a mutation
  # that cannot be attributed cannot be ordered against a concurrent
  # revocation.
  @ordered_ops [:create, :patch, :reset, :load_state]
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

  def handle_call({:all, kind}, _f, %{s: s} = st), do: {:reply, Map.get(s, kind, %{}), st}

  def handle_call({:get, kind, id}, _f, %{s: s} = st),
    do: {:reply, s |> Map.get(kind, %{}) |> Map.get(id), st}

  # --- ordered implementations (reached only via the guard above) ----
  def handle_ordered({:create, kind, prefix, fields}, %{tab: tab, s: s} = st) do
    seq = s["seq"] + 1
    id = prefix <> String.pad_leading(Integer.to_string(seq), 4, "0")

    schema =
      case kind do
        "workspaces" -> @workspace_schema
        "goals" -> @goal_schema
        "lanes" -> @lane_schema
        "caps" -> @cap_schema
      end

    rec = Map.merge(%{"schema" => schema, "id" => id}, fields)
    s2 = s |> put_in([kind, id], rec) |> Map.put("seq", seq)
    {:reply, rec, %{st | s: Ampd.Store.save(tab, s2)}}
  end

  def handle_ordered({:patch, kind, id, patch}, %{tab: tab, s: s} = st) do
    case get_in(s, [kind, id]) do
      nil ->
        {:reply, nil, st}

      rec ->
        rec = Map.merge(rec, patch)
        {:reply, rec, %{st | s: Ampd.Store.save(tab, put_in(s, [kind, id], rec))}}
    end
  end

  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)
    {:reply, :ok, %{st | tab: tab, s: Ampd.Store.save(tab, s), sealed: nil}}
  end

  def handle_ordered(:reset, %{tab: tab} = st),
    do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, initial())}}
end
