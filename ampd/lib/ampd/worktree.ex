defmodule Ampd.Worktree do
  @moduledoc """
  The trusted host edge: the **only** module that knows a path, and the
  only module that runs a program.

  ## What this module is, stated plainly

  It is the Trusted Computing Base this slice adds, and it is deliberately
  small enough to read in one sitting. Everything above it — `Ampd.Loci`,
  `Ampd.Locus`, `Ampd.Control` — reasons in opaque refs. This module is
  where a `resource_ref` becomes a directory and a decision becomes a
  process.

  Two properties are load-bearing and are asserted by
  `Ampd.Worktree.confined?/2` and by the census in
  `scripts/make-super-d11-bundle.mjs`:

  1. **No caller above this module can name a path.** `Ampd.CommandSpec`
     declares no path-typed field. The resolution table below is private
     to this process, and `resolve/1` is not part of the command surface.

  2. **A path is never trusted for being well-formed.** The name segment
     is validated *before* git runs and the resulting directory is
     verified *after* git runs, against the realpath. Those are two
     independent checks, because they fail to different attacks: the first
     stops `../../etc`, the second stops a repository whose own
     configuration relocates the worktree somewhere the first check never
     saw.

  ## The TCB delta this represents, recorded rather than absorbed

  Before this module, `System.cmd` / `Port.open` / `:os.cmd` appeared in
  **0** of `ampd`'s modules — the runtime decided and the Rust host
  executed. This module makes that **1**, and pretending otherwise would
  be the exact failure `WEK_R0_FLOOR_CENSUS_V0.md` §0 warns about.

  It is confined to one named module behind `Ampd.Worktree.Effector`
  precisely so the number stays 1 and so the execution can later move into
  the Rust host without the authority model above it changing at all. The
  authority decision is already fully separated: by the time `create/2` is
  reached, admission has happened and this module performs, it does not
  judge.

  ## The lifecycle, and why it is not two steps

  A filesystem mutation and a durable receipt are not atomic, and a design
  that assumes they are will, on the first crash, produce either a
  directory nobody has authority over or a capability over a directory
  that was never created. Only one of those is safe.

      REQUESTED  →  ADMITTED  →  CREATING  →  OBSERVED_CREATED  →  COMMITTED_READY

  `CREATING` is written **and synced** before git is invoked, so a crash
  during creation is discoverable rather than invisible. On restart,
  `recover/0` reclassifies anything still in `CREATING`:

      INDETERMINATE       the record says creating; the disk has not been consulted
      QUARANTINED         the disk disagrees with the record in a way that is
                          not safe to resolve automatically
      RECOVERY_REQUIRED   a human must decide

  **The capability is established at `COMMITTED_READY` and nowhere
  earlier.** A crash therefore leaves state without authority, which is the
  survivable direction: a stray directory is litter, whereas a live
  capability over an unverified resource is a hole.
  """

  use GenServer

  @store "worktrees"

  # The single confinement root, relative to the runtime's own data dir.
  # Everything this module creates lives under it, and `confined?/2`
  # refuses anything whose realpath does not.
  @root "worktrees"

  # A caller-supplied leaf name. Lowercase, no separators, no leading dot
  # or dash, bounded. Everything a traversal needs is outside this class.
  @name_re ~r/^[a-z0-9][a-z0-9._-]{0,62}$/

  @states ~w(REQUESTED ADMITTED CREATING OBSERVED_CREATED COMMITTED_READY
             INDETERMINATE QUARANTINED RECOVERY_REQUIRED)

  def states, do: @states

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
  @participant_mutations ~w(close_store load_state reset register_repo request set_state create recover)a

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
  What a sealed store serves: nothing.

  A sealed resolution table cannot resolve a `resource_ref`, and it must
  not guess. Serving an empty table means every `observe` refuses, which
  is correct — the runtime genuinely does not know where those resources
  are, and inventing a path would be the one mistake this module cannot
  survive.
  """
  def sealed_state, do: %{"repos" => %{}, "resources" => %{}, "bases" => %{}, "seq" => 0}
  def initial, do: %{"repos" => %{}, "resources" => %{}, "bases" => %{}, "seq" => 0}

  def sealed, do: ask(:sealed)
  def close_store, do: ask(:close_store)
  def load_state(s), do: ask({:load_state, s})
  def reset, do: ask(:reset)

  @doc "Every registered repository, `rp_XXXX => %{...}`. Operator-facing."
  def repos, do: ask({:all, "repos"})

  @doc """
  Every known resource, `wt_XXXX => record`.

  The record carries `path`, so this is **operator-facing only** and is
  never projected onto an agent channel. `Ampd.Locus.observe/2` returns
  the redacted view a Lane may see.
  """
  def resources, do: ask({:all, "resources"})

  def resource(ref), do: ask({:get, "resources", ref})
  def repo(ref), do: ask({:get, "repos", ref})

  @doc "Every bound `source-basis@1`, by ref."
  def source_bases, do: ask({:all, "bases"})

  @doc "One `source-basis@1`, or `nil`."
  def source_basis(ref), do: ask({:get, "bases", ref})

  @doc """
  Bind a `source-basis@1` over an already-established worktree resource.

  See `handle_ordered({:bind_basis, …})` for what is checked and why.
  """
  def bind_source_basis(fields), do: ask({:bind_basis, fields})

  @doc """
  An exact Git object name, and nothing that has to be *resolved* to become
  one.

  Phase A's rule is that a basis names an immutable object. `HEAD`, `main`,
  `HEAD~1` and `origin/main` are all selections — they denote whatever the
  repository happens to say at the moment somebody asks, which is the one
  property a basis may not have. The existing establishment path accepts
  them (`Effector.create` does `revision || "HEAD"`) and that stays true:
  a Lane may *select* symbolically, and the resolved `head` the effector
  observed is what a basis may bind.
  """
  def exact_oid?(s) when is_binary(s), do: Regex.match?(~r/^[0-9a-f]{40}$/, s)
  def exact_oid?(_), do: false

  @doc """
  The confinement root for this runtime, as an absolute path.

  Under the data dir on purpose: the runtime already owns that directory,
  `AMPD_DATA_DIR` already relocates it per-run, and a verification battery
  that shares a worktree root with the last one is a battery measuring
  state it did not set up.
  """
  def root do
    r = Path.join(Ampd.Store.data_dir(), @root)
    File.mkdir_p!(r)
    real!(r)
  end

  @doc """
  Register a repository and return its opaque `rp_XXXX` ref.

  **This is the one place an operator hands the runtime a host path**, and
  it is recorded as such in the ambient-authority census rather than
  presented as typed. It is not reachable from an agent channel: no
  command in `Ampd.CommandSpec` accepts a path, so a Lane cannot register
  a repository and cannot discover one it was not given a ref to.

  **Ordered like everything else here.** D.1.1 exempted it as "the
  privileged bootstrap path", which was a misreading of `Ampd.Ordered`:
  that module's point is that bootstrap satisfies the rule *by running
  inside the coordinator*, rather than being excepted from it. Registering
  a repository is the act that decides which directory on this machine the
  runtime will ever create worktrees from, and an unordered write of that
  fact races every establishment reading it.

  `Ampd.Authority.register_repository/1` is the entry point. Calling this
  directly from an ordinary process is refused as
  `unordered-authority-mutation`.
  """
  def register_repository!(path) do
    ask({:register_repo, path})
  end

  # ------------------------------------------------------- name checking
  @doc """
  Is `name` a legal worktree leaf?

  Returns `:ok` or `{:error, reason}`. Called **before** anything touches
  the filesystem, and its refusals are F4's first half.
  """
  def legal_name?(name) when is_binary(name) do
    cond do
      not Regex.match?(@name_re, name) ->
        {:error, "name must match #{inspect(Regex.source(@name_re))}"}

      String.contains?(name, "..") ->
        {:error, "name contains a parent-directory segment"}

      true ->
        :ok
    end
  end

  def legal_name?(_), do: {:error, "name must be a string"}

  @doc """
  Is `path` really inside `root`, after symlinks are resolved?

  The check is on the **realpath**, and it compares path *segments* rather
  than doing a string prefix test. `"/a/b-evil"` starts with `"/a/b"` and
  is not inside it; a prefix test would admit it. This is F4's second
  half, and it is the check that survives a repository whose own config
  relocates the worktree.
  """
  def confined?(path, root) do
    with {:ok, p} <- real(path),
         {:ok, r} <- real(root) do
      pp = Path.split(p)
      rp = Path.split(r)
      length(pp) > length(rp) and Enum.take(pp, length(rp)) == rp
    else
      _ -> false
    end
  end

  # --------------------------------------------------------- lifecycle
  @doc """
  Move a resource to `REQUESTED`, allocating its opaque ref.

  Creates no directory and confers nothing. The ref exists so the rest of
  the flow can be spoken about without a path.
  """
  def request(fields), do: ask({:request, fields})

  @doc "Mark a requested resource admitted. Called only after `Ampd.Locus` has decided."
  def admitted(ref), do: ask({:set_state, ref, "ADMITTED", %{}})

  @doc """
  The deadline this call gives the mechanism, **below the transaction
  budget that encloses it**.

  This was 30 s inside a 15 s `Ampd.AuthorityCoordinator` budget, so an
  ordinary slow `git` did not produce an INDETERMINATE record — it made
  the coordinator's caller raise, killing the transaction with the
  lifecycle state unwritten. The record was already `CREATING` on disk by
  then, so reconciliation still catches it, but the runtime learned
  nothing at the moment it happened and the person saw a crash rather
  than a refusal.

  Newly reachable in D.1.3a: a channel endpoint can answer promptly and
  *wrongly*, and a mis-correlated observation is skipped rather than
  accepted — correctly — so it costs time without costing liveness.

  **This is the bounded fix, not the architectural one.** The right shape
  is ordered-admit → unordered-mechanism → ordered-commit, so machine
  latency is never held inside the total order at all. That refactor is
  not a completion-pass edit: `:create` is in `@ordered_ops`, so the
  effect is reachable *only* from the coordinator, and moving it out means
  changing the ordered-authority boundary itself and adding a revalidation
  phase. It is named as the next slice rather than half-done here.
  """
  def call_deadline_ms, do: 12_000

  @doc """
  Create the worktree. **Performs; does not judge.**

  Writes `CREATING` durably before invoking the effector, observes the
  result, verifies confinement of the realpath, and lands on
  `OBSERVED_CREATED` or a recovery state. Returns `{:ok, record}` or
  `{:error, code, detail}`.
  """
  def create(ref), do: ask({:create, ref}, call_deadline_ms())

  @doc "Mark the resource committed — reached only once a receipt is durable."
  def committed(ref), do: ask({:set_state, ref, "COMMITTED_READY", %{}})

  @doc """
  Reclassify anything still in `CREATING` as `INDETERMINATE`.

  Run at boot. A record saying `CREATING` after a restart means the
  process died between the durable write and the observation, and the
  honest reading is *the disk has not been consulted*, not *it worked* and
  not *it failed*.
  """
  def recover, do: ask(:recover)

  @doc """
  Resolve a ref to its record **including the path**. Trusted callers only.

  Not exported through any command. `Ampd.Locus` calls it and redacts.
  """
  def resolve(ref), do: resource(ref)

  @doc """
  Move a resource into a terminal recovery state with a stated reason.

  Called only by `Ampd.Locus.reconcile/0`, which is the one place that can
  see all three durable stores at once. Ordered, like every other mutation
  here.
  """
  def quarantine_as(ref, state, why) when state in @states,
    do: ask({:set_state, ref, state, %{"recovery_reason" => why}})

  # ---------------------------------------------------------- internals
  # --- ordered-authority boundary -------------------------------------
  #
  # **Every mutation here is ordered, including the lifecycle.**
  #
  # This list was `[:reset, :load_state]`, on the reasoning that the
  # lifecycle calls "are reached exclusively from `Ampd.Locus.establish/3`,
  # so guarding them again would refuse the one caller that is allowed to
  # make them." **Both halves of that were wrong.**
  #
  # The second half was wrong on the facts. `Ampd.Locus.establish/3` runs
  # *inside* `AuthorityCoordinator.transact/1`, so the calling process **is**
  # the coordinator and the guard passes. `Ampd.Loci.create_cap/1` is called
  # from the very same transaction and has always been guarded — which was
  # standing proof, in the same function, that the guard does not refuse the
  # legitimate caller.
  #
  # The first half was wrong on the principle. "Reached exclusively from"
  # was a claim about the code as written, not a property the code enforced,
  # and a comment is not a boundary. Measured, from an ordinary process:
  #
  #     Worktree.request(...)  →  wt_0002, REQUESTED
  #     Worktree.admitted(ref) →  ADMITTED
  #     Worktree.create(ref)   →  a real git worktree on disk
  #
  # with no grant, no Lane occupancy, and no capability. The caller got no
  # `worktree-cap@1` — that part held — but **the machine effect had already
  # happened**, which is the whole of what complete mediation means.
  #
  # `register_repo` is ordered too. It was documented as a privileged
  # bootstrap path, and `Ampd.Ordered` is explicit that bootstrap satisfies
  # the rule by running inside the coordinator rather than by being excepted
  # from it. `Ampd.Authority.register_repository/1` is now that path.
  @ordered_ops [:request, :set_state, :create, :register_repo, :bind_basis, :reset, :load_state]

  @doc """
  Every operation this module refuses outside the coordinator.

  Exported so the review generator can **derive** the sentence it prints
  instead of carrying it as prose. D.1.1a's bundle said `register_repo`
  was ordered in §0 and unordered in §5 and §12, in the same generated
  file, because two of the three were hand-written paragraphs that nothing
  re-checked. A generated document that contradicts itself is worse than a
  hand-written one, because its authority comes from being derived.
  """
  def ordered_ops, do: @ordered_ops

  @impl true
  def handle_call(msg, from, st)
      when (is_tuple(msg) and elem(msg, 0) in @ordered_ops) or
             (is_atom(msg) and msg in @ordered_ops) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg

    cond do
      not Ampd.Ordered.from_coordinator?(from) ->
        {:reply, {:refused, Ampd.Ordered.refusal(tag, __MODULE__)}, st}

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

  def handle_call(:recover, _f, %{tab: tab, s: s} = st) do
    {resources, changed} =
      Enum.reduce(s["resources"], {%{}, []}, fn {ref, rec}, {acc, ch} ->
        if rec["state"] == "CREATING" do
          {Map.put(acc, ref, Map.put(rec, "state", "INDETERMINATE")), [ref | ch]}
        else
          {Map.put(acc, ref, rec), ch}
        end
      end)

    s2 = Map.put(s, "resources", resources)
    {:reply, Enum.reverse(changed), %{st | s: Ampd.Store.save(tab, s2)}}
  end

  def handle_ordered({:register_repo, path}, %{tab: tab, s: s} = st) do
    case real(path) do
      {:ok, p} ->
        seq = s["seq"] + 1
        ref = "rp_" <> String.pad_leading(Integer.to_string(seq), 4, "0")
        rec = %{"ref" => ref, "path" => p}
        s2 = s |> put_in(["repos", ref], rec) |> Map.put("seq", seq)
        {:reply, {:ok, rec}, %{st | s: Ampd.Store.save(tab, s2)}}

      {:error, why} ->
        {:reply, {:error, "repository-unresolvable", %{"reason" => why}}, st}
    end
  end

  def handle_ordered({:request, f}, %{tab: tab, s: s} = st) do
    seq = s["seq"] + 1
    ref = "wt_" <> String.pad_leading(Integer.to_string(seq), 4, "0")

    rec =
      Map.merge(
        %{"ref" => ref, "state" => "REQUESTED", "path" => nil, "head" => nil},
        f
      )

    s2 = s |> put_in(["resources", ref], rec) |> Map.put("seq", seq)
    {:reply, rec, %{st | s: Ampd.Store.save(tab, s2)}}
  end

  def handle_ordered({:set_state, ref, state, extra}, %{tab: tab, s: s} = st) do
    case get_in(s, ["resources", ref]) do
      nil ->
        {:reply, nil, st}

      rec ->
        rec = rec |> Map.merge(extra) |> Map.put("state", state)
        {:reply, rec, %{st | s: Ampd.Store.save(tab, put_in(s, ["resources", ref], rec))}}
    end
  end

  def handle_ordered({:create, ref}, %{tab: tab, s: s} = st) do
    rec = get_in(s, ["resources", ref])
    repo = rec && get_in(s, ["repos", rec["repository_ref"]])

    cond do
      rec == nil ->
        {:reply, {:error, "resource-unknown", %{"resource_ref" => ref}}, st}

      rec["state"] != "ADMITTED" ->
        {:reply,
         {:error, "resource-not-admitted", %{"resource_ref" => ref, "state" => rec["state"]}}, st}

      repo == nil ->
        {:reply, {:error, "repository-unknown", %{"repository_ref" => rec["repository_ref"]}}, st}

      true ->
        target = Path.join(root(), rec["name"])

        # **Durable before the side effect.** If the VM dies on the next
        # line, `recover/0` finds CREATING and calls it INDETERMINATE. If
        # this write happened after the effector instead, the same crash
        # would leave a directory on disk that the runtime has no record
        # of at all.
        creating = rec |> Map.put("state", "CREATING") |> Map.put("path", target)
        s1 = put_in(s, ["resources", ref], creating)
        Ampd.Store.save(tab, s1)

        case effector().create(%{
               repo_path: repo["path"],
               target: target,
               revision: rec["base_revision"]
             }) do
          {:ok, %{head: head} = observation} ->
            cond do
              # **The observation must say which machine performed it,
              # and it must be the one that was measured.**
              #
              # Checked FIRST, before the disk, because it is a
              # well-formedness question about the report rather than a
              # finding about the world: an observation that will not name
              # its embodiment is not a report this runtime knows how to
              # commit, and nothing else it says — including that it
              # succeeded — is worth evaluating.
              #
              # **This was conventional and is now structural.** D.1.1b
              # wrote `nil -> false`, i.e. *a success with no identity is
              # not a mismatch*, directly under a comment claiming such an
              # observation "is not silently trusted". Both shipped
              # effectors did report one, so the happy path was correct and
              # the property was not — a future or configured effector
              # could create a real worktree, return a true HEAD, omit the
              # identity, and commit. The rule is now the one the comment
              # claimed: **a successful machine effect implies a valid
              # observed embodiment identity**, and the callback's own
              # typespec requires it.
              (fault = embodiment_fault(observation)) != nil ->
                {code, why} = fault
                q = quarantine(creating, why)

                {:reply, {:error, code, %{"resource_ref" => ref}},
                 %{st | s: Ampd.Store.save(tab, put_in(s1, ["resources", ref], q))}}

              not File.dir?(target) ->
                q = quarantine(creating, "effector reported success and the directory is absent")
                {:reply, {:error, "worktree-unobserved", %{"resource_ref" => ref}},
                 %{st | s: Ampd.Store.save(tab, put_in(s1, ["resources", ref], q))}}

              # The independent second check. The name was legal, and the
              # thing that got created still has to *be* where we think.
              not confined?(target, root()) ->
                q = quarantine(creating, "created path resolves outside the confinement root")
                {:reply, {:error, "worktree-escaped-confinement", %{"resource_ref" => ref}},
                 %{st | s: Ampd.Store.save(tab, put_in(s1, ["resources", ref], q))}}

              true ->
                ok =
                  creating
                  |> Map.put("state", "OBSERVED_CREATED")
                  |> Map.put("head", head)
                  # **What OS authority the thing that ran actually kept.**
                  # Reported by the effector as data rather than asserted
                  # in a comment, so that when a field flips to `true` it
                  # flips in the evidence. `nil` for the in-process
                  # effector, which is itself the honest answer: it applies
                  # none and has no boundary to describe.
                  |> Map.put("confinement", Map.get(observation, :confinement))

                {:reply, {:ok, ok},
                 %{st | s: Ampd.Store.save(tab, put_in(s1, ["resources", ref], ok))}}
            end

          {:error, why} ->
            # A failed `git worktree add` can still leave a partial
            # directory, so the record does not go back to ADMITTED as
            # though nothing happened. It becomes indeterminate and a
            # human decides.
            bad =
              creating
              |> Map.put("state", "INDETERMINATE")
              |> Map.put("failure", why)

            {:reply, {:error, "worktree-create-failed", %{"reason" => why}},
             %{st | s: Ampd.Store.save(tab, put_in(s1, ["resources", ref], bad))}}
        end
    end
  end

  @doc """
  Bind a `source-basis@1` over an established worktree resource.

  ## What a SourceBasis means, and the thing it deliberately does not mean

  **An exact source snapshot that a job is authorized to inspect.** It is
  *not* "the checkout this running Super was built from". R0b.0 proposed
  deriving one from `/proc/self/exe` ancestry and that was rejected for a
  good reason: the host can canonicalize a directory, and it cannot prove
  that directory produced the binary currently executing. A basis that
  claimed build provenance would be asserting something nothing here can
  check.

  ## Why this reuses `wt_` rather than minting a second repository identity

  Everything a snapshot needs already exists. `register_repository!/1` is
  the one place an operator hands the runtime a host path and it yields an
  opaque `rp_` ref; establishment materializes an exact revision with
  `git worktree add --detach`; the resource record carries the host path
  and `Ampd.Locus.view/1` drops it in one place. So a basis binds a
  `resource_ref` and adds the *one* thing establishment does not record:
  which immutable object that materialization is required to be, from now
  on rather than at the moment it was made.

  ## The fields that are NOT here, and why each is absent

  **`tree_oid`.** Git is content-addressed, so `commit_oid` fixes the tree
  forever — a commit cannot come to name different content. Recording the
  tree would be recording a value derivable from one already present. Where
  content identity is genuinely needed at a granularity a job can act on,
  it belongs in the scope manifest as a per-file digest, not as one opaque
  root that says a file changed without saying which.

  **`basis_digest`.** Same argument, one step worse: it would be a second
  implementation of an identity git already computes, and this round has
  spent enough on what happens when two implementations of one fact drift.

  **`repository_ref`, `name`, `path`.** Carried by the resource. Copying
  them here would create two places a repository can be named and one of
  them would eventually be stale.

  ## What is checked

  The resource must exist, must be `COMMITTED_READY` — a basis over a
  resource that is still `CREATING`, `QUARANTINED` or `INDETERMINATE` would
  be a basis over a directory nobody has vouched for — and the commit must
  be an **exact object name**, not a selection. `commit_oid` defaults to
  the `head` the effector observed at creation, which is already resolved;
  a caller may pass one explicitly and it must agree.

  **Correspondence is not checked here and cannot be.** This runs inside
  the coordinator, where a `git` call is an unbounded host round trip. That
  the materialization *is still* this commit and is clean is a question
  asked where its answer is used — immediately before the read capability
  is derived — because an answer obtained any earlier is a TOCTOU with a
  gap you cannot bound. See the host-side basis check.
  """
  def handle_ordered({:bind_basis, f}, %{tab: tab, s: s} = st) do
    ref = f["resource_ref"]
    rec = ref && get_in(s, ["resources", ref])

    cond do
      rec == nil ->
        {:reply, {:error, "resource-unknown", %{"resource_ref" => ref}}, st}

      rec["state"] != "COMMITTED_READY" ->
        {:reply,
         {:error, "source-basis-resource-not-ready",
          %{"resource_ref" => ref, "state" => rec["state"]}}, st}

      not exact_oid?(f["commit_oid"] || rec["head"]) ->
        # The message names the value, because the caller that gets here
        # passed something like "HEAD" and the useful thing to say is which
        # string was not an object name.
        {:reply,
         {:error, "source-basis-revision-not-exact",
          %{"resource_ref" => ref, "revision" => f["commit_oid"] || rec["head"]}}, st}

      f["commit_oid"] != nil and f["commit_oid"] != rec["head"] ->
        # A caller may state the commit it believes it is binding. If it
        # disagrees with what the effector observed, that is a disagreement
        # about which snapshot this is, and guessing which side is right is
        # exactly the thing a basis exists to stop.
        {:reply,
         {:error, "source-basis-revision-mismatch",
          %{"resource_ref" => ref, "stated" => f["commit_oid"], "observed" => rec["head"]}}, st}

      true ->
        seq = s["seq"] + 1
        id = "sb_" <> String.pad_leading(Integer.to_string(seq), 4, "0")

        basis = %{
          "schema" => "source-basis@1",
          "ref" => id,
          "resource_ref" => ref,
          "commit_oid" => rec["head"]
        }

        s2 = s |> put_in(["bases", id], basis) |> Map.put("seq", seq)
        {:reply, {:ok, basis}, %{st | s: Ampd.Store.save(tab, s2)}}
    end
  end

  def handle_ordered({:load_state, s}, st) do
    tab = st.tab || Ampd.Store.open!(@store)
    {:reply, :ok, %{st | tab: tab, s: Ampd.Store.save(tab, s), sealed: nil}}
  end

  def handle_ordered(:reset, %{tab: tab} = st),
    do: {:reply, :ok, %{st | s: Ampd.Store.save(tab, initial())}}

  defp quarantine(rec, why),
    do: rec |> Map.put("state", "QUARANTINED") |> Map.put("quarantine_reason", why)

  @doc false
  # `nil` when the observation is well-formed and names the measured
  # embodiment; `{refusal_code, reason}` otherwise.
  #
  # **Two faults, two names, because they are two different events.**
  # A mismatch means a machine performed the effect that was not the one
  # admission was decided against. An absence means the effector will not
  # say — which is not a lesser version of the same thing, it is a broken
  # contract, and collapsing them would report a protocol violation as an
  # embodiment change.
  #
  # Compared by digest rather than by term equality: the two objects travel
  # by different routes — one built in this VM, one round-tripped through
  # JSON — so an atom/binary or integer/float difference that means nothing
  # would otherwise read as a swapped machine. `intent_digest/1` is the
  # canonicalizer the rest of the runtime already agrees on.
  def embodiment_fault(observation) do
    case Map.get(observation, :identity) do
      id when is_map(id) and map_size(id) > 0 ->
        if Ampd.Core.intent_digest(id) == Ampd.Core.intent_digest(measured_identity()) do
          nil
        else
          {"worktree-embodiment-mismatch",
           "the effector that performed this is not the effector that was measured"}
        end

      _ ->
        {"worktree-embodiment-unidentified",
         "the effector reported success without saying which machine performed it"}
    end
  end

  defp measured_identity, do: Ampd.Worktree.Effector.identity()

  defp effector, do: Ampd.Worktree.Effector.current()

  defp real(p) do
    case File.exists?(p) do
      true -> {:ok, p |> Path.expand() |> resolve_links()}
      false -> {:error, "path does not exist: #{p}"}
    end
  end

  defp real!(p) do
    {:ok, r} = real(p)
    r
  end

  # `File.cwd!` is not consulted: every path reaching here is already
  # absolute, and expanding against the process's working directory would
  # make the result depend on ambient state this module is trying not to
  # have.
  defp resolve_links(p) do
    case File.read_link(p) do
      {:ok, target} ->
        target |> Path.expand(Path.dirname(p)) |> resolve_links()

      _ ->
        parent = Path.dirname(p)

        if parent == p or parent == "/" do
          p
        else
          Path.join(resolve_links(parent), Path.basename(p))
        end
    end
  end
end
