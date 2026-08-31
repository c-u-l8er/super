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

  **It does not decide whether this is the Carrier that was admitted.** The
  floor asks "is this a Carrier"; `Ampd.Carrier.commit_start/2` asks "is this
  *the* Carrier we agreed to", by comparing the ticket's bound
  `carrier-execution-basis@1` against the one the host measured off the
  running process. The floor can require the basis to be *present and
  well-formed* — it does, below — and cannot require it to be *the right one*,
  because the floor has never seen the ticket.

  ## The versioning rule

  > Changing the semantics of an existing named row requires a version change,
  > even when the row's name does not change.

  `digest/0` derives from the version and the row *names*. It cannot see a
  function body, so a row rewritten in place would keep its digest and an
  in-flight admission taken under the old meaning would commit under the new
  one — silently, which is the one failure mode a basis exists to prevent.
  The version is the only thing that can carry that, so it is the thing that
  must move. `E28` asserts it as an exact constant, so a semantic change to a
  row cannot be made without also failing a test that names the version.

  Version 2 is the first exercise of that rule: `payload_is_the_attested_bytes`
  became `execution_basis_is_well_formed`, moved from the correspondence class
  to the attested class, and stopped accepting a bare digest.
  """

  @schema "carrier-confinement-floor@1"
  @version 4

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
      # **`stdin_is_null` was here and D.1.3c·1 made it false.**
      #
      # The row is renamed rather than rewritten, because the versioning rule
      # above is the whole reason this file has a version: `digest/0` cannot
      # see a function body, so a row that kept its name and changed its
      # meaning would keep its digest and an in-flight admission taken under
      # "stdin is /dev/null" would commit under "stdin is a terminal".
      #
      # The production path caught this itself. Giving a served Carrier a
      # terminal turned `super-host verify` seven checks red on
      # `carrier-confinement-unacceptable`, which is the floor doing exactly
      # what it is for — refusing an embodiment whose shape it was not told
      # about, rather than accepting a Carrier that had quietly become
      # something else.
      {:observed, "stdio_is_the_possessed_terminal",
       &(String.starts_with?(get_in(&1, ["fds", "0"]) || "", "/dev/pts/"))},
      # And it is ONE terminal on all three, not three descriptors that each
      # happen to be a terminal. A Carrier holding two would be a Carrier the
      # host handed something it did not mean to.
      {:observed, "stdio_is_one_terminal",
       fn obs ->
         case Enum.map(~w(0 1 2), &get_in(obs, ["fds", &1])) do
           [t, t, t] when is_binary(t) -> true
           _ -> false
         end
       end},
      {:observed, "control_is_a_socket", &String.starts_with?(get_in(&1, ["fds", "3"]) || "", "socket:")},
      # **Exactly these two names.** This accepted "any two keys beginning
      # SUPER_CARRIER_", so `SUPER_CARRIER_ANYTHING` passed. A row called
      # `environment_is_exact` that accepts a set it did not name is a row
      # whose name is the only exact thing about it.
      {:observed, "environment_is_exact",
       &(Enum.sort(&1["env_keys"] || []) == ~w(SUPER_CARRIER_CONTROL_FD SUPER_CARRIER_INCARNATION))},
      {:observed, "has_a_start_time", &is_integer(&1["starttime"])}
    ]
  end

  @doc """
  Rows that compare an observation against **this particular start**.

  `rows/0` and `attested_rows/0` ask "is this a Carrier". These ask "is this
  *the* Carrier we admitted" — the uid the host runs as, the payload bytes it
  said it would launch, the control endpoint it created, the workdir it
  allocated. Separated because they need the attestation and the observation
  *together*, which neither of the other two lists has.

  This is the difference between a process that is Carrier-shaped and the
  process we intended.

  **It is not what stops an admitted implementation A becoming implementation
  B.** This docstring said it was, and review was right that the source did
  not establish it: the row that claimed the payload was checked read only
  `att["payload_digest"]` and established that *the host supplied a
  SHA-shaped string*, which is a fact about the host's output format and not
  about which bytes ran. Nothing here has ever seen the ticket, so nothing
  here can compare against the admission. That comparison is
  `carrier-execution-basis-changed` in `Ampd.Carrier.commit_start/2`.
  """
  def correspondence_rows do
    [
      {:correspondence, "runs_as_the_expected_uid",
       fn obs, att -> is_integer(obs["uid"]) and obs["uid"] == att["expected_uid"] end},
      {:correspondence, "control_fd_is_the_host_created_endpoint",
       fn obs, att ->
         case {get_in(obs, ["fds", "3"]), att["control_inode"]} do
           {"socket:[" <> rest, inode} when is_integer(inode) ->
             String.trim_trailing(rest, "]") == Integer.to_string(inode)

           _ ->
             false
         end
       end},
      {:correspondence, "cwd_is_the_allocated_workdir",
       fn obs, att ->
         # Compared by identity digest, never by path. A raw host path in an
         # agent-visible record is disclosure; `Ampd.Locus.root_identity/0`
         # makes the same argument for the worktree root.
         # `super-host`'s `sha256::digest` emits `sha256:<hex>`; this
         # compared bare hex and refused every real start on a value that
         # was byte-identical after the prefix. Accept the host's own
         # spelling rather than reimplementing it — a second convention for
         # the same digest is how two correct halves disagree.
         is_binary(obs["cwd"]) and is_binary(att["workdir_identity"]) and
           String.trim_leading(att["workdir_identity"], "sha256:") ==
             (:crypto.hash(:sha256, obs["cwd"]) |> Base.encode16(case: :lower))
       end}
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
      {:attested, "attestor_is_the_host", &(&1["attestor"] == "super-host")},
      # --- D.1.3c·1 · the terminal relationship ---------------------------
      #
      # **Four rows, and the fourth is the only one that could not be forged
      # by a Carrier that got hold of some other terminal.** The first three
      # are read out of the child's own `/proc/<pid>/stat`, so they say a
      # controlling-terminal relationship exists; only `is_this_host_master`
      # says it is *this* one — `TIOCGSID` asked of the descriptor the host
      # holds, which answers `ENOTTY` until a slave-side session leader has
      # claimed that exact terminal.
      #
      # They live in the attested class rather than the observed one because
      # the runtime cannot reach `/proc` or the master; the host is the only
      # party that can measure either, and the class says so rather than
      # letting the runtime believe it observed them.
      {:attested, "terminal_session_established",
       &(get_in(&1, ["terminal", "session_leader"]) == true)},
      {:attested, "terminal_is_controlling",
       &(get_in(&1, ["terminal", "controlling_terminal"]) == true)},
      {:attested, "terminal_is_the_hosts_master",
       &(get_in(&1, ["terminal", "is_this_host_master"]) == true)},
      # **v4, and the row v3 was missing.**
      #
      # The two rows around this one prove different relationships and Unix
      # does not join them. `stdio_is_the_possessed_terminal` says 0/1/2 are
      # *a* pseudoterminal; `terminal_is_the_hosts_master` says the
      # *controlling terminal* is the one this host holds. A process may have
      # controlling terminal A while its standard descriptors refer to
      # terminal B — both rows pass, and the terminal the Carrier is using is
      # not the terminal the host possesses.
      #
      # So the chain
      #
      #     host owns master → that master minted this slave
      #       → the Carrier's 0/1/2 ARE that slave → and it is its ctty
      #
      # had its middle link proved only in `super-host verify` and not
      # required at admission. The host compares `st_rdev` of each of
      # `/proc/<pid>/fd/{0,1,2}` against the slave it minted — a device
      # number, never the `/dev/pts/N` symlink text, which is a name and
      # would be equally true of another namespace's terminal with the same
      # index. The runtime requires the boolean and is handed no pathname.
      {:attested, "terminal_stdio_is_the_hosts_slave",
       &(get_in(&1, ["terminal", "stdio_is_this_host_slave"]) == true)},
      # Resize is an operation performed *on* a Carrier by the holder of the
      # master, never an authority the Carrier holds over its own terminal.
      # `TIOCSWINSZ` is off the seccomp allow-list; this is the row that says
      # so in the basis, so a host that quietly started permitting it would
      # be refused rather than believed.
      {:attested, "terminal_resize_is_the_hosts",
       &(get_in(&1, ["terminal", "resize_authority"]) == "super-host")},
      # **The row this replaces was the weakest thing in the floor.**
      #
      # `payload_is_the_attested_bytes` accepted any string that was 32 bytes
      # or longer after an optional `sha256:` prefix and did not begin
      # `unreadable:`. So it held for `"aaaa…"`, and what it actually
      # established was:
      #
      #     the host supplied a nonempty SHA-like payload digest
      #
      # while its name and the docs above it claimed:
      #
      #     the payload running now == the payload admitted in Transaction A
      #
      # It was also in the correspondence class while reading only the
      # attestation, so it was misfiled as well as weak.
      #
      # This requires the whole basis object, exactly spelled, with a digest
      # of the width sha256 actually produces. It still cannot say the basis
      # is the *admitted* one — see the moduledoc — but a malformed or absent
      # basis can no longer reach the comparison that does.
      {:attested, "execution_basis_is_well_formed", &execution_basis_ok?(&1["execution_basis"])}
    ]
  end

  # 64 hex characters, `sha256:`-prefixed, and nothing else accepted. The host
  # emits `sha256:<hex>`; `>= 32` bytes after an *optional* prefix was wide
  # enough to admit a placeholder, and the placeholder is what a hand-written
  # attestation reaches for.
  defp execution_basis_ok?(%{"schema" => "carrier-execution-basis@1"} = b) do
    d = b["payload_digest"]

    is_binary(d) and
      String.starts_with?(d, "sha256:") and
      byte_size(d) == 71 and
      String.match?(String.trim_leading(d, "sha256:"), ~r/\A[0-9a-f]{64}\z/) and
      b["carrier_protocol"] == "carrier-lifecycle" and
      is_integer(b["carrier_protocol_version"])
  end

  defp execution_basis_ok?(_), do: false

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
  operator detail is where a person finds out which of twenty things it was.
  (This said *fifteen* through two rounds that changed the row set — the count
  is derived by `E28` now, so a stale one fails a test rather than a reading.)
  """
  def verify(observation) when is_map(observation) do
    obs = observation["observed"] || %{}
    att = observation["attested"] || %{}

    failed =
      Enum.filter(rows(), fn {_c, _n, f} -> not safe(f, obs) end) ++
        Enum.filter(attested_rows(), fn {_c, _n, f} -> not safe(f, att) end) ++
        Enum.filter(correspondence_rows(), fn {_c, _n, f} -> not safe2(f, obs, att) end)

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

  defp safe2(f, a, b) do
    try do
      f.(a, b) == true
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
      "attested" => Enum.map(attested_rows(), fn {_, n, _} -> n end),
      "correspondence" => Enum.map(correspondence_rows(), fn {_, n, _} -> n end)
    })
  end
end
