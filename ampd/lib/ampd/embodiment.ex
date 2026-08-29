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

  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

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
      _ -> GenServer.call(__MODULE__, :identity, 30_000)
    end
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
  def refresh, do: GenServer.call(__MODULE__, :refresh, 30_000)

  @doc "The probe value the cache is currently keyed on. Diagnostics."
  def probe, do: GenServer.call(__MODULE__, :probe)

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
