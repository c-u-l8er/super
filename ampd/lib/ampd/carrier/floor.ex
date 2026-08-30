defmodule Ampd.Carrier.Floor do
  @moduledoc """
  `carrier-confinement-floor@1` — the minimum a process must satisfy before it
  may join the World as a Carrier.

  ## Why this is a module and not four booleans in a predicate

  It was four booleans in a predicate, and review found the hole: the check
  required `no_new_privs`, a seccomp filter and an exact descriptor set, and
  **did not require Landlock at all**. A process with no filesystem
  confinement whatsoever satisfied it. D.1.3b·1 spent itself establishing a
  floor that D.1.3b·2 then did not require.

  The failure mode is structural rather than an oversight. An ad-hoc predicate
  grows one clause at a time, each addition looks local, and nothing anywhere
  states what the complete floor *is* — so nothing can notice a missing row.
  A versioned object can be diffed against b·1's `Prepared::configured`.

  ## Evidence classes are not interchangeable

  ```text
  OBSERVED    read by the host out of the child's own /proc
  ATTESTED    the host performed it and says so; not independently readable
  FALSIFIED   proved out-of-band by a gate, not per-Carrier
  ```

  **Landlock is ATTESTED, and that is forced rather than chosen.** Measured on
  this kernel: there is no `Landlock:` field in `/proc/<pid>/status` and no
  `/proc/<pid>/attr/landlock`. A Landlock domain is not visible from outside
  the process in it. The host built the ruleset and called
  `landlock_restrict_self`; its word is the only in-band evidence there is.

  The runtime is entitled to trust the host — it is inside the TCB, and
  `Ampd.Locus`'s embodiment basis already rests on host self-report. What it
  must not do is *report* an attestation as an observation. The out-of-band
  proof that the attestation corresponds to something is
  `super-host verify`'s differential battery, which shows a confined Carrier
  refused ten operations an unconfined sibling reaches.

  ## What this does not do

  It does not re-derive the policy. It checks that the observation and the
  attestation together describe a process at or above the floor, and refuses
  otherwise. Whether the *policy itself* is adequate is b·1's question and is
  answered by the gate, not per-start.
  """

  @schema "carrier-confinement-floor@1"
  @version 1

  def schema, do: @schema
  def version, do: @version

  @doc """
  The floor, as data.

  Each row names its evidence class. `verify/1` walks this list; adding a row
  here is what makes it required, and there is nowhere else to add one.
  """
  def rows do
    [
      {:observed, "no_new_privs", &(&1["no_new_privs"] == true)},
      {:observed, "seccomp_filter_mode", &(&1["seccomp_mode"] == 2)},
      {:observed, "seccomp_filter_present", &(is_integer(&1["seccomp_filters"]) and &1["seccomp_filters"] >= 1)},
      {:observed, "descriptor_set_exact", &(Map.keys(&1["fds"] || %{}) |> Enum.sort() == ~w(0 1 2 3))},
      {:observed, "stdin_is_null", &(get_in(&1, ["fds", "0"]) == "/dev/null")},
      {:observed, "control_is_a_socket", &String.starts_with?(get_in(&1, ["fds", "3"]) || "", "socket:")},
      {:observed, "environment_is_exact",
       &(is_list(&1["env_keys"]) and length(&1["env_keys"]) == 2 and
           Enum.all?(&1["env_keys"], fn k -> String.starts_with?(k, "SUPER_CARRIER_") end))},
      {:observed, "runs_as_this_uid", &is_integer(&1["uid"])},
      {:observed, "has_a_start_time", &is_integer(&1["starttime"])}
    ]
  end

  @doc """
  Rows that can only come from the host's attestation.

  Separated from `rows/0` because they read a different object, and because
  keeping them in one list is exactly how an attestation gets described as an
  observation in a later summary.
  """
  def attested_rows do
    [
      {:attested, "landlock_abi_detected", &(is_integer(&1["landlock_abi"]) and &1["landlock_abi"] >= 1)},
      {:attested, "landlock_governs_filesystem", &nonzero_hex?(&1["landlock_handled_fs"])},
      {:attested, "landlock_governs_network", &nonzero_hex?(&1["landlock_handled_net"])},
      {:attested, "landlock_grants_are_bounded",
       &(is_list(&1["landlock_grants"]) and length(&1["landlock_grants"]) > 0 and
           length(&1["landlock_grants"]) <= 4)},
      {:attested, "seccomp_refusal_is_attributable", &(&1["seccomp_deny_errno"] == 130)},
      {:attested, "parent_death_is_kernel_bound", &(&1["pdeathsig"] == "SIGKILL")},
      {:attested, "no_network", &(&1["network"] == "none")},
      {:attested, "attestor_is_the_host", &(&1["attestor"] == "super-host")}
    ]
  end

  defp nonzero_hex?(v) when is_binary(v) do
    case Integer.parse(String.replace_prefix(v, "0x", ""), 16) do
      {n, _} -> n > 0
      _ -> false
    end
  end

  defp nonzero_hex?(_), do: false

  @doc """
  Check an observation against the floor.

  Returns `:ok` or `{:error, [failed_row_names]}`. **Names the rows that
  failed**, because "confinement unacceptable" is not a diagnosis and the
  operator detail is where a person finds out which of fifteen things it was.
  """
  def verify(observation) when is_map(observation) do
    obs = observation["observed"] || %{}
    att = observation["attested"] || %{}

    failed =
      Enum.filter(rows(), fn {_c, _n, f} -> not safe(f, obs) end) ++
        Enum.filter(attested_rows(), fn {_c, _n, f} -> not safe(f, att) end)

    case failed do
      [] -> :ok
      rows -> {:error, Enum.map(rows, fn {c, n, _} -> "#{c}:#{n}" end)}
    end
  end

  def verify(_), do: {:error, ["observation-not-a-map"]}

  # A predicate that raises on a shape it did not expect is a predicate that
  # fails open if anything above it rescues. Failing closed is the only
  # direction that is not a lie about a confinement claim.
  defp safe(f, subject) do
    try do
      f.(subject) == true
    rescue
      _ -> false
    end
  end

  @doc """
  A digest of the floor itself, for the admission ticket.

  Binds *which floor* a Carrier was admitted under, so that changing this
  module invalidates in-flight admissions rather than silently applying a new
  rule to a start that was accepted under an older one.
  """
  def digest do
    Ampd.Core.intent_digest(%{
      "schema" => @schema,
      "version" => @version,
      "observed" => Enum.map(rows(), fn {_, n, _} -> n end),
      "attested" => Enum.map(attested_rows(), fn {_, n, _} -> n end)
    })
  end
end
