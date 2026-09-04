defmodule Ampd.Embodiment do
  @moduledoc """
  What machine this runtime's effects are actually performed by — measured,
  cached against a cheap probe, and re-measured the moment the probe moves.

  ## The defect this exists to close

  D.1.1a bound `profile_basis` over four facts, one of which was the
  effector *class*:

      effector       = Ampd.Worktree.Effector.Host
      worktree_root
      otp_release
      ampd_vsn

  Meanwhile `Ampd.Worktree.Effector.Host.binary/0` resolves at runtime —
  `SUPER_HOST_BIN`, then application config, then a development fallback —
  and the host it starts then resolves `git` through `$PATH`. So:

      capability C established, profile says effector = Host
      SUPER_HOST_BIN = host-A · git = git-A
                            ↓
      SUPER_HOST_BIN = host-B · PATH resolves git-B
                            ↓
      profile_digest unchanged · C still exercisable
      but the machine executing the effect is a different machine

  The basis existed to make that impossible and did not. Worse, the host's
  observation — including every claim it makes about confinement — is
  supplied *by that executable*, so trusting an unidentified one is
  trusting an unidentified party's account of its own restraint.

  **The floor, stated as a rule:** if the executable bytes that implement a
  capability's effect change, an existing capability must not silently
  remain fresh. It may be re-established under the new basis. It may not
  survive unexamined.

  ## Why a cache, and why not a permanent one

  `Ampd.Locus.check/2` runs on every capability use, and the honest
  measurement forks a process and hashes two multi-megabyte binaries.
  Doing that per authority check is a fork per check; doing it once per VM
  means a binary replaced at 10:00 is still trusted at 17:00. Neither is
  acceptable, so the measurement is cached against a `stat`-class probe
  that moves whenever the measurement would:

      pathname · size · mtime · inode      of the performing binary
      pathname · size · mtime · inode      of the resolved `git`

  **The residual, stated rather than hidden.** A replacement preserving all
  four of those for both binaries is not noticed until the next restart.
  Producing one requires write access to the binary plus deliberate
  metadata forgery — a strictly larger capability than the one this check
  defends against, and the kind of adversary for whom the answer is
  `fs-verity` or IMA rather than a `stat`.

  ## What this module is not

  **It is not an authority store.** It holds no grant, no capability and no
  world; it caches a measurement of the machine. Losing it costs one
  re-measurement, which is why it is not in `Ampd.World.authority_stores/0`
  and why it has no dets table. A store whose loss must seal the world is a
  store that held authority — this one holds an observation, and an
  observation that is lost is simply taken again.
  """

  use GenServer

  @doc """
  How long an identity measurement may take, and it is **not 30 seconds**.

  It was, and that number is reachable from inside an ordered transaction:

      Ampd.Carrier.admit_start/2  → transact
        → Ampd.Locus.profile_digest/0 → profile_facts/0
          → Ampd.Worktree.Effector.identity/0
            → Ampd.Embodiment.identity/0        ← 30_000

  `Ampd.AuthorityCoordinator.budget_ms/0` is 15_000, and the chain that
  module declares is *mechanism wait < enclosing call deadline < transaction
  budget*. Thirty seconds inverts it: the coordinator's client raises at
  fifteen while the coordinator is still blocked here, so the fail-closed
  answer this module is built to give — `unidentified/2` — never arrives.
  The `catch :exit, _` below cannot help, because it only fires once the
  thirty seconds have elapsed.

  **Twelve, and the two numbers either side of it are what pin it.** This
  handler is not a leaf: `safe_probe/1` and `safe_identity/1` both reach
  `Ampd.Bridge` through `Ampd.Worktree.EffectChannel`, whose own deadline is
  **10_000**. So the chain that has to hold is

      Ampd.Worktree.EffectChannel.deadline_ms()   10_000
      this deadline                               12_000   ≥ 2_000 above it
      AuthorityCoordinator.budget_ms()            15_000   ≥ 2_000 above this

  and ten would have been *equal* to the wait it encloses, which the chain
  forbids: a chain that fits by a millisecond is one scheduler hiccup away
  from the defect it exists to close.

  **The handler can still outlive this deadline, and that is not a violation
  — it is the mechanism.** Two sequential channel waits can sum to 20_000,
  above the transaction budget itself, so no choice of this number could
  bound them. What this number does is bound *the coordinator's* wait: at
  twelve seconds the caller stops waiting, `identity/0` answers
  `unidentified/2`, and the transaction finishes inside its budget with a
  fail-closed measurement — which is precisely what this module is built to
  do and what 30_000 made impossible.

  `Ampd.EffectChannelTest`'s C14 falsifier reads this number off this module,
  so the chain is asserted rather than maintained by hand. It was **four**
  numbers and is five; this one was missing from it.

  `refresh/0` takes the same deadline for the same reason — it runs the same
  measurement, and it is a mutation.
  """
  @identity_deadline_ms 12_000
  def identity_deadline_ms, do: @identity_deadline_ms

  @doc false
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
  # **`:identity` is a read, and its handler writes state.** That is the one
  # place in the converted set where the two disagree, and it is deliberate:
  # what it writes is a memo keyed on the probe, not authority. Re-executing
  # it is idempotent and observationally identical, so a lost reply means
  # *the basis could not be established* — `:unavailable`, retryable — and
  # not *a mutation may have landed*. `:refresh` discards the memo on
  # purpose, which is a fact about the cache the caller asked for, so that
  # one is a mutation.
  @participant_mutations ~w(refresh)a

  defp ask(msg, timeout \\ 5_000) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg
    Ampd.Participant.call(__MODULE__, msg, class(tag), timeout: timeout)
  end

  @doc false
  # Public so the closure gate and the falsifiers read the classification
  # rather than infer it.
  def class(tag), do: if(tag in @participant_mutations, do: :mutate, else: :read)

  @impl true
  def init(:ok), do: {:ok, %{probe: :never_measured, identity: nil}}

  @doc """
  The current effector's `host-identity@1`, measured if the probe has
  moved and served from cache otherwise.

  The timeout is generous because a miss forks `super-host identity`,
  which hashes its own image and the resolved `git`.
  """
  def identity do
    # **A crash is not a named refusal.** `Ampd.Locus.check/2` calls this on
    # every capability use, so a `GenServer.call` to a process that is
    # momentarily restarting — or absent, as under `mix run --no-start` —
    # would take down the caller mid-transaction instead of refusing.
    #
    # Absent measurement is fail-closed by construction: `unidentified/2`
    # digests differently from every real identity, so a capability
    # established under a measured machine refuses while the measurement is
    # unavailable, and resumes when it returns. The runtime says
    # `capability-profile-basis-changed`, which is true — it cannot currently
    # confirm the embodiment — rather than raising.
    case Process.whereis(__MODULE__) do
      nil -> unidentified(Ampd.Worktree.Effector.current(), "the embodiment cache is not running")
      _ -> ask(:identity, @identity_deadline_ms)
    end
  rescue
    # **The boundary raises where a bare call exited, and the answer is the
    # same one this module has always given.** `Ampd.Participant` converts a
    # dead or silent participant into a classified exception instead of an
    # exit; without this clause that exception would leave the coordinator
    # through `classify/1` and refuse the whole transaction, replacing a
    # fail-closed measurement with a failed operation. Absent measurement is
    # already fail-closed by construction — `unidentified/2` digests
    # differently from every real identity — so the classification is
    # recorded in the reason and the caller gets a value.
    e in Ampd.Participant.Failure ->
      unidentified(
        Ampd.Worktree.Effector.current(),
        "the embodiment cache did not answer (#{e.outcome})"
      )
  catch
    :exit, _ ->
      unidentified(Ampd.Worktree.Effector.current(), "the embodiment cache did not answer")
  end

  @doc """
  Discard the cache and measure again on the next call.

  Not needed in the production path — the probe does that job. It exists
  so a falsifier can prove the difference between *the probe noticed* and
  *the cache was cleared*, which are two different claims and only the
  first is the one this module makes.
  """
  def refresh, do: ask(:refresh, @identity_deadline_ms)

  @doc "The probe value the cache is currently keyed on. Diagnostics."
  def probe, do: ask(:probe)

  @impl true
  def handle_call(:identity, _from, st) do
    mod = Ampd.Worktree.Effector.current()

    # The module is part of the key. Switching effectors is an embodiment
    # change by itself, and keying only on the probe would let two
    # effectors that happen to resolve the same `git` share a cache entry.
    key = {mod, safe_probe(mod)}

    if key == st.probe and st.identity != nil do
      {:reply, st.identity, st}
    else
      id = safe_identity(mod)
      {:reply, id, %{probe: key, identity: id}}
    end
  end

  def handle_call(:refresh, _from, _st), do: {:reply, :ok, %{probe: :never_measured, identity: nil}}
  def handle_call(:probe, _from, st), do: {:reply, st.probe, st}

  # An effector that cannot answer is a *different embodiment*, not an
  # exception. Both helpers return a stable object rather than raising, so
  # the failure lands as `capability-profile-basis-changed` — a refusal with
  # a name — instead of taking down the caller mid-transaction.
  # **`Code.ensure_loaded?/1` first, and it is not a formality.**
  #
  # `function_exported?/3` answers about a *loaded* module and returns false
  # for one that merely has not been loaded yet. Under lazy loading that made
  # the answer depend on whether anything had happened to call the effector
  # earlier in the VM's life — so the first measurement recorded
  # `resolved: false, "the effector declares no identity/0"` and a later one,
  # after `Ampd.Worktree.create/1` had loaded the module by calling it,
  # recorded the true identity. Two different digests for one unchanged
  # machine.
  #
  # Measured as an intermittent F19b failure that depended on the ExUnit seed:
  # a capability established, then refused as
  # `capability-profile-basis-changed` with nothing having changed. **An
  # embodiment basis that depends on code-loading order is not an embodiment
  # basis**, and the failure mode is the worst available — a refusal nobody
  # can explain, appearing under load and not under a debugger.
  defp loaded_export?(mod, fun) do
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0)
  end

  defp safe_probe(mod) do
    if loaded_export?(mod, :identity_probe) do
      mod.identity_probe()
    else
      {:no_probe, mod}
    end
  rescue
    e -> {:probe_failed, mod, Exception.message(e)}
  end

  defp safe_identity(mod) do
    if loaded_export?(mod, :identity) do
      mod.identity()
    else
      unidentified(mod, "the effector declares no identity/0")
    end
  rescue
    e -> unidentified(mod, "the effector could not be identified: #{Exception.message(e)}")
  end

  @doc """
  The identity of an effector that will not say what it is.

  Deliberately **not** an empty map and not `nil`: an unidentified
  embodiment must digest to something stable and distinct, so that a
  capability established under an identified machine refuses under an
  unidentified one rather than matching a `nil` that means nothing.
  """
  def unidentified(mod, reason) do
    %{
      "schema" => "host-identity@1",
      "resolved" => false,
      "effector" => inspect(mod),
      "reason" => reason,
      "effect_protocol_version" => Ampd.Worktree.Effector.protocol_version()
    }
  end
end
