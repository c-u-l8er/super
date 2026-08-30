defmodule Ampd.Worktree.Effector do
  @moduledoc """
  The one place `ampd` runs a program, expressed as a contract so that it
  can stop being in `ampd`.

  D.1.1 ships `Ampd.Worktree.Git`, which shells out. That is a real
  addition to the trusted computing base and it is declared, not absorbed:
  before this behaviour existed, `System.cmd` / `Port.open` / `:os.cmd`
  appeared in **0** of `ampd`'s modules. The whole point of putting a
  behaviour here is that the number stays **1** and that the eventual move
  into the Rust host — or into a confined Carrier — is a swap of this
  module and nothing above it.

  Note what the callback signature does *not* carry: no actor, no lane, no
  capability, no grant. By the time an effector is called the decision has
  already been taken by `Ampd.Locus` inside the total order. An effector
  that could see the authority context would eventually be tempted to
  consult it, and then the decision would live in two places.
  """

  @typedoc "Everything the effector needs, and nothing about who asked."
  @type request :: %{
          repo_path: String.t(),
          target: String.t(),
          revision: String.t() | nil
        }

  @typedoc """
  A successful observation. **Both keys are required.**

  `identity` is not optional and its absence is not a weaker success.
  D.1.1b typed this as `%{head: String.t()}` and let
  `Ampd.Worktree.create/1` treat a missing identity as *no mismatch*, so an
  effector could perform a real effect, report a true HEAD, say nothing
  about which machine did it, and be committed. The property was
  conventional — held by both shipped effectors — rather than structural.

  The rule, in the contract rather than in a comment:

      a successful machine effect  ⇒  a valid observed embodiment identity

  An effector that cannot answer must return `{:error, reason}`. A success
  without an identity is quarantined as
  `worktree-embodiment-unidentified` and commits nothing.
  """
  @type observation :: %{required(:head) => String.t(), required(:identity) => map()}

  @callback create(request) :: {:ok, observation} | {:error, String.t()}

  @doc """
  **What this effector is made of**, as content identity and never as
  pathnames.

  D.1.1a bound an embodiment basis naming the effector *class* and nothing
  about the executable bytes that class runs. `Host.binary/0` is resolved
  at runtime from `SUPER_HOST_BIN`, and the host then resolves `git`
  through `$PATH` — so both halves of the machine that actually performs
  the effect could be replaced while `profile_basis` stayed identical, and
  a capability established under one machine remained exercisable under
  another. That is precisely the thing the basis exists to refuse.

  The contract on the returned map is one rule: **no pathname may appear
  in it.** It is bound into `worktree-profile@1`, which is bound into
  `worktree_created@1`, which an agent reads. Digests, sizes and version
  strings; not locations.

  The rule this encodes, stated once:

      same path, different bytes   →  definitely a different embodiment
      different path, same bytes   →  not, on this evidence, a different one
  """
  @callback identity() :: map()

  @doc """
  A **cheap** value that changes whenever `identity/0` would.

  `identity/0` forks a process and hashes multi-megabyte binaries.
  `Ampd.Locus.check/2` runs on every capability use. Doing the expensive
  thing on the hot path would be one answer; caching it forever would be
  another, and both are wrong — the first is a fork per authority check,
  the second means a binary swapped at 10:00 is still trusted at 17:00.

  So: cache `identity/0`, keyed on this. It must be a `stat`-class
  operation, and it must move if the pathname, size, mtime or inode of
  anything `identity/0` measures moves.

  Its residual is stated rather than hidden: a replacement that preserves
  path, size, mtime **and** inode is not detected until the next restart.
  Forging all four requires deliberate effort by something that already has
  write access to the binary, which is a strictly larger capability than
  the one this check defends.
  """
  @callback identity_probe() :: term()

  @doc """
  The version of the `ampd` ↔ effector contract itself.

  Bound into the basis alongside the effector's own identity. A change to
  what a `request` *means* while its shape stayed the same would otherwise
  be an embodiment change nothing recorded.
  """
  def protocol_version, do: 1

  @doc """
  The identity of whichever effector is current, via `Ampd.Embodiment`'s
  cache. The uncached call is `mod.identity()`.
  """
  def identity, do: Ampd.Embodiment.identity()

  @doc """
  The effector this runtime will use.

  **`Ampd.Worktree.Effector.Channel` is the default, and the default is the
  security property.** D.1.3a moved the production effect from *resolving a
  name* to *possessing a descriptor*; a default that fell back to the named
  effector when no channel was present would delete that property at
  exactly the moment the system was degraded, which is when it matters. A
  boundary with a convenient ambient fallback is not a boundary.

  So a missing channel is `unavailable` — refused by name, lifecycle
  `INDETERMINATE` — and never a pathname exec.

  `Ampd.Worktree.Effector.Host` and `Ampd.Worktree.Git` remain, in-tree and
  tested, as **explicit reference and parity mechanisms**: two
  implementations that must produce the same observation are how the move
  is proved not to have changed the effect. Selecting one is a
  configuration a person writes, not a state the runtime falls into. The
  test environment selects `Host` in `config/config.exs` for exactly that
  reason, and `C13` asserts the *unconfigured* default is the channel so
  that selection cannot quietly become the rule.

  **Which one is running is a load-bearing embodiment fact**, and it is
  already inside `Ampd.Locus.profile_facts/0`. So switching effectors
  changes `profile_basis`, and every capability established under the old
  one refuses until it is re-established. That is not an inconvenience to
  work around — it is the architecture behaving correctly about a change
  to what an effect *means*, and F10 covers it.
  """
  def current, do: Application.get_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Channel)
end

defmodule Ampd.Worktree.Effector.Host do
  @moduledoc """
  The effector that does not execute git — it asks the host to.

  ```text
      ampd    admission · authority · lifecycle
                │  worktree-effect-request@1
                ▼
      host    machine effect + observation
                │  worktree-effect-observation@1
                ▼
      ampd    verification · evidence · commit
  ```

  ## What moved, and what did not

  What moved is the `exec` of `git`. What did **not** move is any part of
  the decision: `super-host effect` receives a request carrying no actor,
  no lane, no capability, no grant and no world, so there is nothing in it
  the host could form an opinion about. It performs an operation that was
  already admitted, and it is not a second gate — a refusal invented there
  would be one no `refusal@1` describes and no projection shows.

  `ampd` still runs a program: this one. **The exec count did not go from
  one to zero and this module does not claim it did.** What changed is
  *which* program, and it is the difference that matters: `ampd` now execs
  one binary it builds and ships, with a typed request, instead of exec'ing
  `git` against a repository whose own contents decide what git then runs.

  ## The observation is not trusted, it is checked

  `Ampd.Worktree.create/1` re-checks that the directory exists and that its
  realpath is inside the confinement root, exactly as it does for the
  in-process effector. `Ampd.LocusTest`'s lying effector exists to prove
  that path, and it protects this one unchanged: an observation is a report,
  and the runtime commits on what it can verify.

  ## Confinement, stated rather than implied

  The host returns a `host-confinement@1` block saying what OS authority
  the child actually retained. As shipped every field is `false`. Moving
  the exec is not confinement; it is the place confinement can be added.
  The block is data so that when a field becomes `true` it becomes true in
  the evidence, not in a document beside it.
  """

  @behaviour Ampd.Worktree.Effector

  @request_schema "worktree-effect-request@1"
  @observation_schema "worktree-effect-observation@1"
  @identity_schema "host-identity@1"

  # Anchored to this **source** file at compile time, not to `priv/` and
  # not to the working directory.
  #
  # `:code.priv_dir(:ampd)` resolves into `_build/`, so a path built from
  # it pointed at `_build/dev/lib/host/target/release/super-host`, which
  # has never existed. `File.cwd!` would have been worse in a quieter way:
  # which binary runs would depend on where somebody happened to start the
  # VM, and that is the ambient authority this whole slice is about not
  # having.
  @dev_default Path.expand("../../../../host/target/release/super-host", __DIR__)

  @doc """
  Where the host binary is.

  `SUPER_HOST_BIN` wins, for the same reason `AMPD_DATA_DIR` does: the host
  decides where its own parts live, and it decides at spawn time rather
  than at compile time.

  The fallback is the in-tree development path, frozen at compile time.
  **A packaged release must set `SUPER_HOST_BIN`** — a compiled-in source
  path is correct here and wrong the moment the tree moves, and
  `create/1` refuses by name rather than falling back to executing git in
  the runtime, so the failure is loud.
  """
  def binary do
    System.get_env("SUPER_HOST_BIN") ||
      Application.get_env(:ampd, :host_bin) ||
      @dev_default
  end

  def available?, do: File.exists?(binary())

  @doc """
  Ask the host what it is: `super-host identity`, one line of
  `host-identity@1`.

  **The host hashes itself, and that is the point.** `ampd` could stat and
  hash `binary()` directly, and it would be attesting the file it *looked
  at*. The host resolves its own running image, so what comes back is the
  bytes that are executing — and it is the same process that will resolve
  and exec `git`, so its answer about which git is the answer about the
  git that runs.

  A missing or unanswerable host is **not** an error here. It is a
  different embodiment, and it gets a different digest: a capability
  established while the host was present must not stay exercisable once it
  is gone. Returning a stable `resolved: false` object rather than raising
  is what makes that a refusal with a name instead of a crash.
  """
  @impl true
  def identity do
    bin = binary()

    cond do
      not File.exists?(bin) ->
        unresolved("the host binary is absent")

      true ->
        case ask_host() do
          {:ok, %{"schema" => @identity_schema} = id} ->
            id

          {:ok, other} ->
            unresolved("the host returned an unknown identity schema: #{inspect(other["schema"])}")

          {:error, why} ->
            unresolved("the host could not be asked: #{why}")
        end
    end
  end

  # No pathname in the reason, for the same rule the object obeys: an
  # error string is still a projection, and this object reaches a receipt.
  defp unresolved(reason) do
    %{
      "schema" => @identity_schema,
      "resolved" => false,
      "reason" => reason,
      "effect_protocol_version" => Ampd.Worktree.Effector.protocol_version()
    }
  end

  defp ask_host do
    bin = binary()

    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["identity"]
      ])

    case collect(port, "") do
      {:ok, out} -> decode(out)
      other -> other
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  The cheap probe: the pathname, size, mtime and inode of the host binary,
  and of the `git` this runtime would resolve.

  **`ampd` stats `git`; it does not execute it.** Resolving the name is how
  a *change* is noticed cheaply. The authoritative answer about which git
  performs the effect still comes from the host, which is the process that
  actually runs it — so if the two would resolve different gits, the host's
  is the one bound and this is only a conservative change detector. A false
  "changed" costs one re-measurement; a missed change would cost a stale
  basis, so erring this way is the correct direction.
  """
  @impl true
  def identity_probe do
    {:host, stat_probe(binary()), stat_probe(System.find_executable("git"))}
  end

  @doc false
  def stat_probe(nil), do: :unresolved

  def stat_probe(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} -> {path, size, mtime, inode}
      _ -> {:absent, path}
    end
  end

  @impl true
  def create(%{repo_path: repo, target: target, revision: revision}) do
    req = %{
      "schema" => @request_schema,
      "op" => "create",
      "repo_path" => repo,
      "target" => target,
      "revision" => revision || "HEAD"
    }

    with {:ok, out} <- invoke(req),
         {:ok, obs} <- decode(out) do
      cond do
        obs["schema"] != @observation_schema ->
          {:error, "host returned an unknown observation schema: #{inspect(obs["schema"])}"}

        obs["ok"] != true ->
          {:error, "host: #{obs["reason"]}"}

        not is_binary(obs["head"]) or obs["head"] == "" ->
          {:error, "host reported success with no head"}

        true ->
          {:ok,
           %{
             head: obs["head"],
             confinement: obs["confinement"],
             # **Reported by the machine that performed it.** The basis
             # `ampd` admitted under is a measurement taken *before* the
             # effect; this is what actually ran. `Ampd.Worktree.create/1`
             # compares them, which is the only way a swap between the
             # measurement and the exec is visible at all.
             identity: obs["identity"]
           }}
      end
    end
  end

  defp invoke(req) do
    bin = binary()

    if not File.exists?(bin) do
      # Named, not a silent fallback to the in-process effector. Quietly
      # running git here instead would change the trusted computing base
      # without anything saying so — and `profile_basis` would still record
      # the effector that was *configured* rather than the one that ran.
      {:error, "the host binary is absent at #{bin} — refusing to execute git in the runtime instead"}
    else
      port =
        Port.open({:spawn_executable, bin}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["effect"]
        ])

      # Newline-terminated: the host reads one line rather than to EOF,
      # because a port gives no way to close the child's stdin without
      # closing the port. Both sides waiting for the other was the first
      # thing this boundary did.
      Port.command(port, [Ampd.Core.canon(req), "\n"])
      collect(port, "")
    end
  rescue
    e -> {:error, "the host effector could not be invoked: #{Exception.message(e)}"}
  end

  # The host writes one observation and exits, so the reply is complete
  # when the exit status arrives — not when the first chunk does. Reading
  # one chunk and calling it the answer is how a large observation becomes
  # a parse error that reads like a malformed host.
  defp collect(port, acc) do
    receive do
      {^port, {:data, chunk}} -> collect(port, acc <> chunk)
      {^port, {:exit_status, _}} -> {:ok, acc}
    after
      30_000 ->
        Port.close(port)
        {:error, "the host effector did not answer within 30s"}
    end
  end

  defp decode(out) do
    case out |> String.split("\n", trim: true) |> List.last() do
      nil ->
        {:error, "the host effector produced no output"}

      line ->
        case :json.decode(line) do
          m when is_map(m) -> {:ok, m}
          other -> {:error, "the host observation is not an object: #{inspect(other)}"}
        end
    end
  rescue
    _ -> {:error, "the host observation is not valid JSON: #{String.slice(out, 0, 200)}"}
  end
end

defmodule Ampd.Worktree.Git do
  @moduledoc """
  `git worktree add`, run with as little ambient authority as this runtime
  can currently take away from it.

  Three deliberate choices, each closing a way the host environment could
  decide what this command means:

  **No shell.** `System.cmd/3` with an argument list `exec`s directly.
  There is no string for a name to be interpolated into, so the class of
  attack that `Ampd.Worktree.legal_name?/1` refuses is one this layer
  cannot express in the first place.

  **`git` is not one program. It is a program that runs other programs.**

  This is the finding that reshaped the module, and it was missed on the
  first pass. `git worktree add` checks out a tree, and checking out a tree
  runs the repository's `post-checkout` hook. Measured, before the fix: a
  `post-checkout` script planted in the fixture repository **executed**,
  with the runtime's uid and the runtime's whole filesystem view. A census
  row reading *"one module executes a program"* was true of the source and
  false about the machine.

  So two suppressions, and neither is optional:

  * `core.hooksPath=/dev/null` — no hook of any kind can run. Passed as
    `-c` on the command line so a repository's own config cannot override
    it, which `.git/config` otherwise can.
  * `--no-checkout`, then an explicit `git checkout`… **no.** That still
    runs hooks. The hooks path is the mechanism; there is no ordering of
    porcelain that avoids it.

  **Config files are disabled by pointing them at `/dev/null`, not by
  unsetting them.** The first version unset `GIT_CONFIG_GLOBAL` and
  `GIT_CONFIG_SYSTEM` on the theory that absent is safer than a value.
  That is backwards for these two specifically: git's documented behaviour
  is that *setting* them to `/dev/null` disables the corresponding file,
  whereas *unsetting* them restores the normal default lookup. Measured:
  with the variables merely unset, `git config --show-origin user.email`
  still read `~/.gitconfig`. Every other variable in the scrub list is
  still unset, because for those absence genuinely is the safe value.

  **`--detach`, and no branch is created.** A branch is a mutation of the
  repository's own namespace, and this slice's authority is to create a
  worktree and observe it. Creating a ref would be exercising an authority
  nobody granted.

  ## What is still NOT closed, and cannot be closed here

  A repository's own `.git/config` can define **filter drivers** whose
  `smudge` command runs during checkout. `core.hooksPath` does not disable
  those, and there is no single flag that does. They are reachable only
  from a repository an operator explicitly registered — but *registered* is
  not *audited*, and a repository is data.

  **Therefore: this is not a sandbox, and configuration cannot make it
  one.** The child inherits the runtime's uid and filesystem view;
  `seccomp` / `landlock` / `unshare` / `capsicum` are absent. Closing
  transitive execution properly needs an OS boundary, which is why the
  concrete execution belongs behind a host effector rather than here.
  `test/locus_test.exs` carries the hook falsifier and the residual filter
  case, so the claim is measured on every run rather than argued once.
  """

  @behaviour Ampd.Worktree.Effector

  # Unset for the child. For these, absence *is* the safe value: each names
  # a location or a program, and having none means git uses its own.
  @scrub ~w(
    GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_COUNT
    GIT_SSH GIT_SSH_COMMAND GIT_EXTERNAL_DIFF GIT_PAGER GIT_EDITOR
    GIT_ASKPASS GIT_NAMESPACE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES
    GIT_ALLOW_PROTOCOL
  )

  # Pointed at `/dev/null`, NOT unset. Unsetting these restores git's
  # default config lookup; setting them to `/dev/null` is what disables it.
  @nulled %{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"}

  # Command-line `-c`, so a repository's own `.git/config` cannot override
  # them. Anything that must hold against a hostile repository has to be
  # asserted at a precedence the repository cannot reach.
  @hardened [
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=false",
    "-c", "protocol.ext.allow=never"
  ]

  def scrubbed_variables, do: @scrub
  def nulled_variables, do: @nulled
  def hardening_flags, do: @hardened

  @identity_schema "host-identity@1"

  @doc """
  What *this* effector is made of.

  The same schema the host answers with, because the question is the same
  question and a second schema would mean `Ampd.Locus` had to know which
  effector it was talking to in order to read the answer. What differs is
  `effector_kind`: this one runs git inside the runtime, so there is no
  separate performing binary to identify — `host_binary` is `false` with a
  reason, which is a true statement about this embodiment rather than a
  gap in it.

  `hardening_policy_digest` is computed with `Ampd.Core.intent_digest/1`,
  the canonicalizer this runtime already has. The host computes its own
  with a fixed serialization of its own constants. **These two digests are
  not comparable and are not meant to be** — they identify two different
  policies belonging to two different embodiments, and a change of
  effector has already changed the basis before either is reached.
  """
  @impl true
  def identity do
    exe = System.find_executable("git")

    git =
      cond do
        exe == nil ->
          %{"resolved" => false, "reason" => "no executable `git` on PATH"}

        true ->
          %{
            "resolved" => true,
            "sha256" => file_digest(exe),
            "version" => git_version(exe),
            "bytes" => file_size(exe)
          }
      end

    %{
      "schema" => @identity_schema,
      "effector_kind" => "in-runtime",
      "effect_protocol" => ["worktree-effect-request@1", "worktree-effect-observation@1"],
      "effect_protocol_version" => Ampd.Worktree.Effector.protocol_version(),
      "host_binary" => %{
        "resolved" => false,
        "reason" => "this effector runs git in the runtime; there is no performing binary"
      },
      "git" => git,
      "hardening_policy_digest" =>
        Ampd.Core.intent_digest(%{
          "schema" => "ampd-git-hardening@1",
          "scrub" => @scrub,
          "nulled" => @nulled,
          "hardened" => @hardened
        }),
      "confinement" => %{
        "schema" => "host-confinement@1",
        "landlock" => false,
        "seccomp" => false,
        "mount_namespace" => false,
        "network_namespace" => false,
        "pid_namespace" => false,
        "chroot" => false,
        "drops_privileges" => false,
        "inherits_uid" => true,
        "inherits_environment_except_scrubbed" => true,
        "note" => "the in-runtime effector applies no confinement and has no boundary to apply it at"
      }
    }
  end

  @impl true
  def identity_probe, do: {:in_runtime_git, stat_probe(System.find_executable("git"))}

  defp stat_probe(nil), do: :unresolved

  defp stat_probe(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} -> {path, size, mtime, inode}
      _ -> {:absent, path}
    end
  end

  # Streamed, not `File.read!`: hashing a multi-megabyte executable by
  # first allocating all of it is the kind of thing that works until the
  # binary is larger than the thing measuring it expects.
  defp file_digest(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          "sha256:" <> (io |> hash_stream(:crypto.hash_init(:sha256)) |> Base.encode16(case: :lower))
        after
          File.close(io)
        end

      _ ->
        nil
    end
  end

  defp hash_stream(io, ctx) do
    case IO.binread(io, 65_536) do
      :eof -> :crypto.hash_final(ctx)
      {:error, _} -> :crypto.hash_final(ctx)
      data -> hash_stream(io, :crypto.hash_update(ctx, data))
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: s}} -> s
      _ -> nil
    end
  end

  # `version --build-options`, not `--version` — see the host's own
  # `git_version`. A distro holds the one-line version constant across
  # backported changes, so it is a claim about branding rather than about
  # behaviour; the build options carry the SHA-1 implementation, the
  # compiled-in shell, the linked TLS library and the upstream commit.
  defp git_version(exe) do
    case System.cmd(exe, ["version", "--build-options"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @impl true
  def create(%{repo_path: repo, target: target, revision: revision}) do
    rev = revision || "HEAD"

    with {:ok, _} <- git(repo, ["worktree", "add", "--detach", target, rev]),
         {:ok, head} <- git(target, ["rev-parse", "HEAD"]) do
      # The in-runtime effector reports its own identity for the same reason
      # the host does: `Ampd.Worktree.create/1` compares what ran against
      # what was admitted, and an effector that answered `nil` would be
      # exempt from a check every other effector takes.
      {:ok, %{head: String.trim(head), identity: identity()}}
    end
  end

  defp git(cd, args) do
    env =
      Enum.map(@scrub, &{&1, nil}) ++
        Enum.to_list(@nulled) ++
        [{"GIT_TERMINAL_PROMPT", "0"}]

    argv = ["-C", cd] ++ @hardened ++ args

    case System.cmd("git", argv, env: env, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "git #{Enum.join(args, " ")} exited #{code}: #{String.trim(out)}"}
    end
  rescue
    e in ErlangError ->
      # `:enoent` — no git on this machine. A missing binary is a refusal
      # with a name, not a crash that takes the store's process with it.
      {:error, "git could not be executed: #{Exception.message(e)}"}
  end
end
