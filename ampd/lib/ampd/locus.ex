defmodule Ampd.Locus do
  @moduledoc """
  Where a Lane becomes a Locus: the establishment of typed authority over
  a real machine resource, and the check that decides whether that
  authority is still the one that was established.

  ## The sentence this module exists to make executable

  > A Lane occupies an established position in a persistent governed
  > structure. That position admits specific authority over a real machine
  > resource. The current execution Carrier may disappear without
  > destroying the semantic Locus, and a replacement Carrier receives no
  > authority except that which can be legitimately re-established from
  > the Locus's current basis.

  Every clause of that maps to something here:

      "occupies"          occupies?/2 — a Carrier occupies a Lane only by
                          being bound to the Lane's actor, and the binding
                          is `Ampd.Peer`'s, not the caller's claim.

      "admits specific    establish/3 — a grant, then a cap over one
       authority"         resource_ref with two rights and four bases.

      "may disappear"     nothing in this module or `Ampd.Loci` holds a
                          pid. A cap outlives `Ampd.Peer.reset/0` because
                          it was never a property of a peer.

      "no authority       check/2 — re-derived on every use from the
       except"            current world, the current grant, and the
                          current profile. Never from the fact that the
                          record survived.

  ## Carrier and Locus, mechanically

  A **Carrier** here is a peer binding: `Ampd.Peer.attach_agent/3` mints
  one, `Ampd.Peer.reset/0` mints a fresh epoch and every outstanding
  handle stops resolving. That is Carrier death and it already existed —
  D.1.1 adds no process machinery to model it, which is the point. The
  WEK thesis is that semantic richness can grow while privileged
  mechanism does not, and reusing the peer epoch instead of inventing a
  Carrier registry is one data point in favour.

  A **Locus** is a `lane@1` record in `Ampd.Loci`. It is in dets. It has
  no pid. Killing every process in the VM does not change it.

  ## Persistence is not authority

  `check/2` re-derives four things and refuses if any has moved:

      world generation      an advance is a discontinuity; authority does
                            not cross one, it is reacquired on the far side
      the grant             revoked, expired, or scoped elsewhere → nothing
                            stands under the cap
      the profile basis     the embodiment that decided what the effect
                            *means* has changed
      cap status            establishing, revoked, superseded

  A record that survives a reboot proves it was written. It does not
  prove anyone may still use it, and this module never treats the first
  as evidence of the second.
  """

  alias Ampd.{Core, Loci, Worktree, Receipts, Refusal, Session, World}

  @receipt_kind "worktree_created@1"

  @doc "The capability name a Lane must hold to establish a worktree."
  def create_capability, do: "worktree.create"

  def receipt_kind, do: @receipt_kind

  # ------------------------------------------------------------ profile
  @doc """
  The load-bearing embodiment facts, as data.

  Load-bearing means: if this changes, the same request does not
  necessarily mean the same thing.

  ## Two defects fixed here, and they pull in opposite directions

  **The set was too thin.** D.1.1a bound the effector *class* —
  `Ampd.Worktree.Effector.Host` — and nothing about the executable that
  class runs. `Host.binary/0` resolves at runtime from `SUPER_HOST_BIN`,
  and the host then resolves `git` through `$PATH`, so the entire machine
  performing the effect could be replaced with this digest unchanged. The
  basis named a *decision about which module to call* and called it an
  embodiment. `embodiment` is the correction: content identity for the
  performing binary, for the git it resolves, and for the hardening policy
  under which it runs.

  **And it was too disclosing.** `worktree_root` was the literal host path,
  and because `profile_object/0` is bound onto every `worktree-cap@1` and
  into every `worktree_created@1`, that path reached an agent channel
  nested two levels below a key called `profile`. The receipt had no
  top-level `path` and contained a path anyway.

  So `worktree_root_identity` replaces it: a digest that answers *is this
  the same root?* without answering *which directory is it?*

  **What that identity is and is not.** It is an identity, not a secret.
  Anyone holding a candidate path can confirm or refute it by digesting
  their guess — and an agent that already knows the path has learned
  nothing new. What it stops is the thing that actually happens: the host
  filesystem namespace being serialized into evidence that is framed,
  coalesced, rendered, logged and screenshotted. Confidentiality against a
  party who knows the answer is not what the basis is for; **not putting
  the answer into every projection** is.

  `:profile_overrides` merges over the derived facts. It exists so the
  F10 falsifier can move an embodiment fact without needing a second
  machine, and nothing in the production path sets it.
  """
  def profile_facts do
    Map.merge(
      %{
        "effector" => inspect(Ampd.Worktree.Effector.current()),
        "effector_protocol_version" => Ampd.Worktree.Effector.protocol_version(),
        # The machine, by content. See `Ampd.Embodiment`.
        "embodiment" => Ampd.Worktree.Effector.identity(),
        "worktree_root_identity" => root_identity(),
        "otp_release" => List.to_string(:erlang.system_info(:otp_release)),
        "ampd_vsn" => to_string(Application.spec(:ampd, :vsn) || "0")
      },
      Application.get_env(:ampd, :profile_overrides, %{})
    )
  end

  @doc """
  An opaque identity for the confinement root — the same root gives the
  same value, a different root gives a different one, and neither answer
  contains the directory.

  Digested with `Core.intent_digest/1` and domain-separated by a `kind`
  field so it cannot collide with a digest of anything else that happens
  to be a one-key map holding a string.
  """
  def root_identity,
    do: Core.intent_digest(%{"kind" => "worktree-root@1", "path" => Worktree.root()})

  @fact_set_version 2

  @doc """
  The revision of the fact **vocabulary**, not of any fact's value.

  It moves when a fact is added, removed or renamed — which invalidates
  every capability established under the previous revision, by design and
  not as a side effect.

  Exported so `scripts/make-super-d11-bundle.mjs` can report the running
  value. The alternative is a sentence in a document, and a sentence in a
  document is how this field came to say 1 while the bundle said 2.
  """
  def fact_set_version, do: @fact_set_version

  @fact_keys ~w(ampd_vsn effector effector_protocol_version embodiment
                otp_release worktree_root_identity)

  @doc """
  The fact **vocabulary** this version declares, as a sorted list.

  Declared rather than derived from `profile_facts/0`, and then checked
  against it by a test, because the two are answers to different questions:
  this is what the version *promises*, that is what the runtime *produced*.
  A change to one without the other is exactly the drift D.1.1c is closing,
  so it fails a test instead of appearing in a bundle.

  It is also pure. `profile_facts/0` measures the machine and therefore
  needs `Ampd.Embodiment` running; the generator only wants to print the
  vocabulary, and should not have to boot a runtime to do it.
  """
  def fact_keys, do: @fact_keys

  @doc """
  `worktree-profile@1` — the embodiment basis as an **object**, not only a
  hash.

  D.1.1 carried `profile_basis` as a bare digest. A digest is enough to
  *detect* that the embodiment moved and useless for saying what it moved
  from: six months later the only honest reading of a stored hash is
  "something was different", which is not provenance. If environmental
  state decides admission, the environmental state has to be in the
  committed evidence.

  So the object is what gets digested and the object is what gets bound
  into `worktree_created@1`. `fact_set_version` is here because the fact
  set is **provisional and known to be incomplete** — when a fact is added,
  every existing capability's digest changes and every one of them refuses
  until re-established, which is the correct behaviour and is much easier
  to reason about when the version says so out loud.

  `evidence_class` is `declared-provisional`: these facts were chosen
  by argument, not derived from a theory of which embodiment changes matter.
  Classifying a change into `STILL_VALID` / `REQUIRES_REVALIDATION` /
  `INVALIDATED` / `UNAVAILABLE_ON_NEW_EMBODIMENT` is deliberately **not**
  done here — that theory belongs to Agent-Invariants and WEK policy, and
  inventing it in Super would be a runtime asserting a research result.
  What Super does is the fail-closed floor: same basis, proceed to the
  other checks; different basis, refuse.
  """
  def profile_object do
    %{
      "schema" => "worktree-profile@1",
      # **2 since D.1.1c.** The vocabulary genuinely changed in D.1.1b —
      # `worktree_root` (a literal path) left, and `effector_protocol_version`,
      # `embodiment` and `worktree_root_identity` arrived — and this field
      # stayed at 1 while the review bundle said it had advanced. The digest
      # moved either way, so nothing was authorized wrongly; but a field whose
      # only job is to name the revision of the fact vocabulary, and which does
      # not move when the vocabulary does, is doing nothing.
      #
      # It is also why `fact_set_version/0` is exported: the generator reads
      # the running value rather than reprinting a sentence about it, which is
      # how the two came apart.
      "fact_set_version" => fact_set_version(),
      "evidence_class" => "declared-provisional",
      "facts" => profile_facts()
    }
  end

  @doc """
  A digest over `profile_object/0`, using the same canonicalization as
  every other digest in this runtime.

  Reusing `Ampd.Core.intent_digest/1` rather than writing a second hash is
  deliberate: two canonicalizations in one system is two things that can
  disagree, and the parity vectors already pin this one across languages.

  It digests the **object**, not the bare facts, so the schema and the
  fact-set version are inside the commitment. A fact set that changed shape
  while producing the same facts would otherwise hash the same.
  """
  def profile_digest, do: Core.intent_digest(profile_object())

  # ----------------------------------------------------------- occupancy
  @doc """
  Does `peer` occupy `lane`? **Delegated to `Ampd.Worker` since D.1.2.**

  ## What this used to be, and why it is not that any more

      def occupies?(peer, lane),
        do: peer["actor"] != nil and peer["actor"] == lane["actor"]

  That was the D.1.1 bootstrap and it was sufficient for what D.1.1 asked:
  the actor came from the peer binding rather than the payload, so a fresh
  Carrier attaching as somebody else reached nothing. F8 is still true.

  It stopped being sufficient the moment one identity could hold more than
  one position. Under actor equality, a Carrier authenticating as an actor
  with three Lanes occupied **all three simultaneously**, and the check
  above could not tell which one a command was issued from — because there
  was nothing to tell. `who you are ⇒ everywhere you are associated with`
  is ambient authority wearing the vocabulary that was supposed to remove
  it.

  **The architectural result D.1.2 was asked for is that this equality did
  have to go.** It did not survive contact with a Worker. What replaced it
  keeps identity as a necessary condition and adds an explicit, current,
  singular assignment:

      occupancy  =  identity  ∧  live attachment to an open Worker on
                                 this Lane, under the current world
                                 lineage, peer epoch and Worker generation

  Every call site here is unchanged — `check/2`, `reconstruct/2` and
  `establish/3` still ask the same question and still refuse the same way.
  What changed is the answer, which is why the D.1.1 falsifiers still pass
  while `D2-01` … `D2-12` are now also true.
  """
  defdelegate occupies?(peer, lane), to: Ampd.Worker

  @doc """
  The capability set a Carrier gets by attaching to `lane`.

  **Reconstructed, not inherited.** Each cap is re-checked with `check/2`
  before it is included, so attaching to a Locus whose grant was revoked
  while no Carrier was attached yields an empty set rather than the set
  that was live when the last Carrier died. That is F9: a replacement
  Carrier receives only what can be re-established now.
  """
  def reconstruct(peer, lane_id) do
    lane = Loci.lane(lane_id)

    cond do
      lane == nil ->
        {:refused, refuse("locus-unknown", %{"locus_ref" => lane_id})}

      # The refusal comes from `Ampd.Worker` rather than being rebuilt
      # here, so the caller learns *which* of the occupancy conditions
      # failed — "attach first" and "you are standing somewhere else" are
      # different instructions and both are actionable.
      (occ = Ampd.Worker.occupancy(peer, lane)) != :ok ->
        occ

      true ->
        live =
          lane_id
          |> Loci.caps_of()
          |> Enum.filter(fn {_, c} -> check(c, peer) == :ok end)
          |> Map.new()

        {:ok, %{"locus" => lane, "capabilities" => live, "count" => map_size(live)}}
    end
  end

  # --------------------------------------------------------------- check
  @doc """
  Is this capability exercisable **now**, by this Carrier?

  Returns `:ok` or `{:refused, refusal}`. Every branch is a falsifier in
  `test/locus_test.exs`, and the order is chosen so the refusal names the
  first thing that is actually wrong rather than the last thing checked.
  """
  def check(nil, _peer), do: {:refused, refuse("capability-unknown", %{})}

  def check(cap, peer) do
    lane = Loci.lane(cap["locus_ref"])

    cond do
      lane == nil ->
        {:refused, refuse("locus-unknown", %{"locus_ref" => cap["locus_ref"]})}

      # **F2, and it is checked before anything else about the capability.**
      #
      # Order is disclosure here, exactly as it is in
      # `Ampd.Refusal.agent_code/1`. Testing `status` first — which this did —
      # told a caller who does not hold the capability whether it is active,
      # establishing, failed or superseded. That is a bit of another Locus's
      # state per probe, and a caller free to guess ids can accumulate them.
      #
      # Occupancy first means a stranger gets exactly one answer,
      # `capability-not-held`, whatever the capability's condition is; the
      # holder gets the specific reason, because the holder is entitled to it.
      #
      # **D.1.2 splits "not the holder" into two cases, and they disclose
      # differently.** A stranger — an actor the Lane is not held by — is
      # told exactly what it was told before. An actor that *is* the Lane's
      # actor but is not standing there is told so, because that is a fact
      # about its own position and "attach first" is unactionable if it
      # cannot be told apart from "this was never yours". The grading is
      # `Ampd.Worker.occupancy/2`'s; this branch only chooses which of the
      # two questions is being answered.
      peer == nil or peer["actor"] == nil or peer["actor"] != lane["actor"] ->
        {:refused,
         refuse("capability-not-held", %{
           "capability" => cap["id"],
           "locus_ref" => cap["locus_ref"],
           "hint" =>
             "the capability exists and is held by another Locus — knowing its id is not holding it"
         })}

      (occ = Ampd.Worker.occupancy(peer, lane)) != :ok ->
        occ

      cap["status"] != "active" ->
        {:refused,
         refuse("capability-not-active", %{"capability" => cap["id"], "status" => cap["status"]})}

      # F3b. A lineage advance is a discontinuity. The record survived it;
      # the authority did not.
      cap["world_ref"] != World.lineage() ->
        {:refused,
         refuse("capability-generation-stale", %{
           "capability" => cap["id"],
           "established_in" => cap["world_ref"],
           "current" => World.lineage(),
           "hint" =>
             "state moved across the generation change and authority did not — re-establish it"
         })}

      # F3a. Nothing stands under the cap any more.
      grant_of(cap) == nil ->
        {:refused,
         refuse("capability-authority-revoked", %{
           "capability" => cap["id"],
           "authority_basis" => cap["authority_basis"],
           "hint" => "the grant that conferred this capability is no longer active for this actor"
         })}

      # F10. The embodiment that decided what this effect means has moved.
      cap["profile_basis"] != profile_digest() ->
        {:refused,
         refuse("capability-profile-basis-changed", %{
           "capability" => cap["id"],
           "established_under" => cap["profile_basis"],
           "current" => profile_digest(),
           "hint" =>
             "persistent state does not imply persistent authority when the embodiment changed"
         })}

      true ->
        :ok
    end
  end

  @doc """
  Does `cap` carry `right`?

  Separate from `check/2` on purpose: a cap can be perfectly current and
  still not carry the right being asked for, and collapsing the two would
  report a rights failure as a freshness failure.
  """
  def carries?(cap, right), do: is_map(cap) and right in (cap["rights"] || [])

  # ----------------------------------------------------------- establish
  @doc """
  Establish a worktree for a Lane. The whole D.1.1 slice, in order.

  Runs inside the total order, because it both reads the grant table and
  mints a capability from what it read — doing those as two calls would
  leave a writable gap between the decision and the authority it creates,
  which is the defect `Ampd.Authority.revoke_matching/2` already exists to
  avoid one layer down.

  Returns `{:ok, %{...}}` or `{:refused, refusal}`.

  **Must run inside the coordinator, and does not wrap itself in one.**
  `Ampd.Authority.establish_worktree/3` is the entry point, because the
  fence that says *which world incarnation this work belongs to* lives in
  `Ampd.Authority.in_world/2` and is read by its `tx/1`. Wrapping the
  transaction here instead would run the work unfenced — the command
  would linearize into whatever world was current when it arrived rather
  than the one its channel was bound to.

  Calling this directly is not a hole: every mutation it performs lands in
  `Ampd.Loci`, whose ordered-authority guard refuses anything that did not
  come from the coordinator.
  """
  def establish(peer, lane_id, name) do
    lane = Loci.lane(lane_id)

    cond do
      lane == nil ->
        {:refused, refuse("locus-unknown", %{"locus_ref" => lane_id})}

      # **`locus_ref` is a check, not a choice.** A Carrier holds at most
      # one attachment, so this argument cannot select which position to
      # act from — it can only agree or disagree with where the Carrier
      # already is, and a disagreement is refused. Property A of
      # *Capability Myths Demolished*: no designation without authority.
      (occ = Ampd.Worker.occupancy(peer, lane)) != :ok ->
        occ

      # F4, first half — refused before anything touches the filesystem.
      match?({:error, _}, Worktree.legal_name?(name)) ->
        {:error, why} = Worktree.legal_name?(name)

        {:refused,
         refuse("worktree-name-illegal", %{
           "name" => String.slice(to_string(name), 0, 64),
           "reason" => why
         })}

      # F1. The authority check happens **before** a resource ref is
      # allocated, so an unauthorized Lane leaves nothing behind at all —
      # not a directory, not a receipt, and not a durable REQUESTED record
      # it could accumulate without limit.
      grant_for_lane(lane) == nil ->
        {:refused,
         refuse("worktree-authority-missing", %{
           "locus_ref" => lane_id,
           "capability" => create_capability(),
           "hint" =>
             "a Lane owns no filesystem authority because a pathname is known to it — " <>
               "an active grant for #{create_capability()} over this Locus is what confers it"
         })}

      true ->
        admit(lane, name, grant_for_lane(lane))
    end
  end

  defp admit(lane, name, grant) do
    goal = Loci.goal(lane["goal_ref"]) || %{}
    repo_ref = lane["repository_ref"]
    repo = Worktree.repo(repo_ref)

    if repo == nil do
      {:refused, refuse("repository-unknown", %{"repository_ref" => repo_ref})}
    else
      base = base_revision(lane)

      res =
        Worktree.request(%{
          "repository_ref" => repo_ref,
          "locus_ref" => lane["id"],
          "name" => name,
          "base_revision" => base
        })

      # Minted `establishing`, not `active`. A capability becomes live
      # only once the resource it names has been observed and its receipt
      # is durable — so a crash anywhere below leaves state without
      # authority, which is the survivable direction.
      cap =
        Loci.create_cap(%{
          "world_ref" => World.lineage(),
          "workspace_ref" => lane["workspace_ref"],
          "goal_ref" => lane["goal_ref"],
          "locus_ref" => lane["id"],
          "repository_ref" => repo_ref,
          "base_revision" => base,
          "resource_ref" => res["ref"],
          "rights" => Loci.rights(),
          "authority_basis" => grant["id"],
          "profile_basis" => profile_digest(),
          "profile" => profile_object(),
          "generation" => 1,
          "status" => "establishing"
        })

      Worktree.admitted(res["ref"])

      case Worktree.create(res["ref"]) do
        {:ok, observed} ->
          receipt = emit_receipt(cap, lane, goal, observed, grant)
          Worktree.committed(res["ref"])
          cap = Loci.put_cap(cap["id"], %{"status" => "active"})

          {:ok,
           %{
             "capability" => cap,
             "resource" => view(observed),
             "receipt" => receipt
           }}

        {:error, code, detail} ->
          # The cap never becomes active and the resource keeps whichever
          # recovery state `Ampd.Worktree` landed on. No receipt is
          # emitted, which is F6: a refusal cannot mint evidence that the
          # thing happened.
          Loci.put_cap(cap["id"], %{"status" => "failed"})
          {:refused, refuse(code, Map.put(detail, "resource_ref", res["ref"]))}
      end
    end
  end

  # ------------------------------------------------------------ observe
  @doc """
  What a Lane may see of its own resource.

  Returns `{:ok, view}` or `{:refused, refusal}`. The view is redacted:
  **`path` is not in it.** An agent channel that could read the path would
  make every subsequent confinement argument decorative, because the Lane
  could then hand the path to anything else it can reach.
  """
  def observe(peer, cap_id) do
    cap = Loci.cap(cap_id)

    with :ok <- check(cap, peer),
         true <- carries?(cap, "observe") do
      case Worktree.resolve(cap["resource_ref"]) do
        nil -> {:refused, refuse("resource-unknown", %{"resource_ref" => cap["resource_ref"]})}
        rec -> {:ok, view(rec)}
      end
    else
      {:refused, _} = r -> r
      false -> {:refused, refuse("right-not-carried", %{"capability" => cap_id, "right" => "observe"})}
    end
  end

  @doc """
  The redacted resource view.

  Everything a Lane can act on and nothing it can act *with*: the opaque
  ref, the lifecycle state, the commit that was checked out, and whether
  the directory is presently there. `path` is dropped here, in one place,
  rather than being omitted at each call site — the same reason
  `Ampd.Refusal.project/2` centralizes disclosure.
  """
  def view(rec) when is_map(rec) do
    rec
    |> Map.take(["ref", "state", "head", "base_revision", "repository_ref", "locus_ref", "name"])
    |> Map.put("exists", rec["path"] != nil and File.dir?(rec["path"]))
  end

  # ---------------------------------------------------------- reconcile
  @doc """
  The boot interpretation of every durable cross-state.

  `Ampd.Worktree.recover/0` handles the one cut inside the effector call.
  It is not the only cut. Establishment crosses **three** durable stores —
  `worktrees`, `receipts`, `loci` — and a process can die between any two
  writes, so the state that matters is the *combination*, which no single
  store can see. This function is the only place that can, and it runs at
  boot from `Ampd.Application`.

  The rule is not "repair". It is **every durable combination has a defined
  interpretation**, because the failure being avoided is a resource and a
  capability stranded in a shape nothing describes.

      resource state      receipt   cap        interpretation
      ─────────────────────────────────────────────────────────────────
      REQUESTED           —         —          inert · nothing happened
      ADMITTED            —         establishing
                                               inert · the effector never ran
      CREATING            —         establishing
                                               INDETERMINATE · the disk was
                                               never consulted
      OBSERVED_CREATED    absent    establishing
                                               RECOVERY_REQUIRED · a real
                                               directory exists with no evidence
      OBSERVED_CREATED    present   establishing
                                               RECOVERY_REQUIRED · evidence is
                                               durable, the commit is not
      COMMITTED_READY     present   establishing
                                               RECOVERY_REQUIRED · committed
                                               with no live capability
      COMMITTED_READY     present   active     complete
      COMMITTED_READY     absent    any        QUARANTINED · committed without
                                               evidence, which must not happen
      INDETERMINATE / QUARANTINED / RECOVERY_REQUIRED
                                               already terminal · left alone

  **No cut promotes a capability.** `RECOVERY_REQUIRED` is a state a person
  resolves; auto-repair would mean the runtime deciding that a capability it
  never finished establishing is now live, which is the one direction that
  cannot be undone.

  Returns a list of `{resource_ref, interpretation}` for anything that was
  not already complete.
  """
  def reconcile do
    receipts_by_resource =
      Receipts.all()
      |> Enum.filter(&(&1["kind"] == @receipt_kind))
      |> Map.new(&{&1["resource_ref"], &1})

    caps_by_resource = Map.new(Loci.caps(), fn {_, c} -> {c["resource_ref"], c} end)

    Worktree.resources()
    |> Enum.map(fn {ref, res} ->
      {ref, interpret(res, receipts_by_resource[ref], caps_by_resource[ref])}
    end)
    |> Enum.reject(fn {_, v} -> v == :complete or v == :inert end)
    |> Enum.map(fn {ref, {state, why}} ->
      Worktree.quarantine_as(ref, state, why)
      {ref, state, why}
    end)
  end

  defp interpret(res, receipt, cap) do
    state = res["state"]
    cap_status = cap && cap["status"]

    cond do
      state in ~w(INDETERMINATE QUARANTINED RECOVERY_REQUIRED) -> :complete
      state in ~w(REQUESTED ADMITTED) -> :inert
      state == "CREATING" -> {"INDETERMINATE", "the disk was never consulted"}
      state == "COMMITTED_READY" and receipt == nil ->
        {"QUARANTINED", "committed with no worktree_created@1 — the commit order was violated"}

      state == "COMMITTED_READY" and cap_status == "active" -> :complete

      state == "COMMITTED_READY" ->
        {"RECOVERY_REQUIRED",
         "committed and evidenced, but no capability is live (cap #{inspect(cap_status)})"}

      state == "OBSERVED_CREATED" and receipt == nil ->
        {"RECOVERY_REQUIRED", "a real directory exists and nothing records why"}

      state == "OBSERVED_CREATED" ->
        {"RECOVERY_REQUIRED", "evidence is durable and the commit is not"}

      true ->
        {"QUARANTINED", "no defined interpretation for state #{inspect(state)}"}
    end
  end

  # ------------------------------------------------------------ receipt
  # **No wall-clock is used as proof of authority freshness.** A timestamp
  # is recorded because an operator reading history needs one, and it is
  # never read back by `check/2`. The freshness bases are the world
  # lineage, the grant, and the profile digest — each of which can be
  # re-derived and compared, which is what makes them evidence.
  defp emit_receipt(cap, lane, goal, observed, grant) do
    Receipts.emit(%{
      "kind" => @receipt_kind,
      "world_ref" => World.lineage(),
      "workspace_ref" => lane["workspace_ref"],
      "goal_ref" => lane["goal_ref"],
      "locus_ref" => lane["id"],
      "locus_actor" => lane["actor"],
      "goal_title" => goal["title"],
      "repository_ref" => cap["repository_ref"],
      "base_revision" => cap["base_revision"],
      "resource_ref" => cap["resource_ref"],
      "worktree_head" => observed["head"],
      "capability_ref" => cap["id"],
      "authority_basis" => grant["id"],
      "rights_digest" => Core.intent_digest(%{"rights" => cap["rights"]}),
      "profile_basis" => cap["profile_basis"],
      # The basis itself, not only its hash. A historical digest with no
      # recoverable canonical basis cannot answer "what did this commit us
      # to?", and that question is the whole reason the digest is bound.
      "profile" => cap["profile"],
      "runtime_revision" => runtime_revision(),
      "effector" => inspect(Ampd.Worktree.Effector.current()),
      # What the thing that actually ran retained, as data. Every field is
      # `false` today; the point is that when one becomes `true` it becomes
      # true in the evidence rather than in a paragraph beside it. `nil`
      # means the in-process effector, which applies none.
      "confinement" => observed["confinement"],
      "lifecycle_state" => "OBSERVED_CREATED",
      "outcome" => "admitted",
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp runtime_revision do
    System.get_env("AMPD_REVISION") || to_string(Application.spec(:ampd, :vsn) || "0")
  end

  # ------------------------------------------------------------ helpers
  defp ctx_for(lane) do
    %{
      "actor" => lane["actor"],
      "workspace" => Session.ctx()["workspace"],
      "run" => Session.ctx()["run"]
    }
  end

  # **Establishment** searches for *an* applicable grant. That is correct
  # here and only here: nothing has been established yet, so there is no
  # basis to be exact about, and a person who authored any covering grant
  # authored the authority this capability will stand on.
  #
  # The grant is looked up over the **Locus**, not over the resource: the
  # resource does not exist until the request is admitted, so authority
  # scoped to it could only ever be granted after the fact.
  defp grant_for_lane(lane) do
    Core.grant_for(
      Ampd.GrantRegistry.list(),
      create_capability(),
      lane["id"],
      ctx_for(lane),
      &Session.retired?/1
    )
  end

  @doc false
  # **Exercise resolves the EXACT grant the capability was established
  # from, by id. It never accepts a substitute.**
  #
  # This searched for *an* equivalent grant, exactly like `grant_for_lane/1`,
  # and that was a hole with a name: authority resurrection. Measured —
  #
  #     grant gr_0193  → establish capability wc_0004
  #     revoke gr_0193 → wc_0004 correctly refuses
  #     mint  gr_0194  (same actor, capability, resource)
  #                    → wc_0004 became usable again
  #
  # — while its own record and its `worktree_created@1` both still named
  # `gr_0193`. So the evidence said one thing and the runtime authorized on
  # another, and a revocation could be undone by a grant that was never
  # about this capability. **A new grant is grounds for a new capability,
  # never for reviving an old one.**
  #
  # Identity is not sufficient on its own, so the grant is re-validated in
  # full after it is found: a stored grant can be edited on disk, and its
  # duration can expire without its `status` changing — `duration_ok/3` is
  # what makes `run` and `once` mean anything.
  def grant_of(cap) do
    lane = Loci.lane(cap["locus_ref"])
    basis = cap["authority_basis"]
    g = lane && basis && Enum.find(Ampd.GrantRegistry.list(), &(&1["id"] == basis))

    cond do
      lane == nil or g == nil -> nil
      g["status"] != "active" -> nil
      g["capability"] != create_capability() -> nil
      g["actor"] != lane["actor"] -> nil
      g["resource"] != lane["id"] -> nil
      not Core.duration_ok(g, ctx_for(lane), &Session.retired?/1) -> nil
      true -> g
    end
  end

  # **A Lane that pins nothing still requested something.**
  #
  # This returned `lane["base_revision"]` unchanged, so a Lane opened
  # without an explicit base produced a `worktree_created@1` binding
  # `base_revision: nil` — a receipt that cannot answer *created from
  # what?*, which is one of the fields program control required it to
  # bind. The D.1.1 falsifier caught it; nothing else would have, because
  # the worktree itself was correct and only the evidence was empty.
  #
  # `"HEAD"` is the symbolic request and `worktree_head` on the receipt is
  # the commit it resolved to. Both are recorded, because only the pair
  # answers the question: the first says what was asked for, the second
  # says what was got, and a repository whose HEAD moves between the two
  # is exactly when the difference matters.
  defp base_revision(lane), do: lane["base_revision"] || "HEAD"

  defp refuse(code, detail) do
    Refusal.new(code,
      component: "Ampd.Locus",
      retryable: false,
      requires_human: code in ~w(worktree-authority-missing capability-authority-revoked
                                 capability-generation-stale capability-profile-basis-changed),
      operator_detail: detail
    )
  end
end
