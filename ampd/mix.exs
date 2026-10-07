defmodule Mix.Tasks.Compile.AmpdFd do
  @moduledoc """
  Build `Ampd.NativeFd`'s shared object with the C compiler already on the
  box.

  **Not `elixir_make`, and this is the reason.** `ampd` has `deps: []`, and
  that is load-bearing rather than tidy: the runtime is the thing trusted
  to name identities, and the smaller the set of code that ships inside
  that boundary the smaller the claim. Three syscalls do not justify a
  dependency tree, and a compiler task short enough to read in full is
  the same argument `host/src/fdpass.rs` makes for declaring `sendmsg` by
  hand rather than pulling in a crate.

  It **refuses** rather than degrades. A build that quietly produced a
  runtime with no descriptor sink would be a leaking runtime that says
  nothing, which is the failure mode this whole round exists to end.

  **It keeps only what this build made for this machine.** A shared object
  is a claim about one OS, one architecture and one compiler command, and
  a time stamp says none of that: every file of a fresh clone carries the
  checkout time, so "source newer than object" kept a tracked x86-64 ELF
  on an arm64 Mac and `Ampd.NativeFd` was silently absent. Beside the
  object sits `<object>.identity`, written only after a successful build:
  the identity it was built under and the digest of what it built. No
  record, a different identity, a different object or a newer source each
  mean rebuild.

  **macOS links with `-undefined dynamic_lookup`.** The `enif_*` symbols
  live in the BEAM that loads the object, not in any library at link time.
  GNU ld allows that for a shared object by default; Apple's ld does not.
  Linux's command is exactly what it was.
  """
  use Mix.Task.Compiler

  @so "priv/ampd_fd_nif.so"
  @src "c_src/ampd_fd_nif.c"
  @flags ["-fPIC", "-shared", "-O2", "-Wall", "-Wextra"]

  @impl true
  def run(_argv) do
    File.mkdir_p!("priv")
    {cc, args} = cmd = command()
    id = identity(:os.type(), arch(), cmd)

    if stale?(@so, @src, id) do
      # Neither file survives into a build that fails: a foreign object with
      # no record is exactly what this task exists to stop keeping.
      File.rm(identity_path(@so))
      File.rm(@so)

      case System.cmd(cc, args, stderr_to_stdout: true) do
        {_, 0} ->
          File.write!(identity_path(@so), record(id, @so))
          {:ok, []}

        {out, code} ->
          Mix.raise("""
          the descriptor sink did not build (#{cc} exited #{code})

          #{out}
          `Ampd.NativeFd` is the only thing in the runtime that can dispose
          of a descriptor received over SCM_RIGHTS. Without it the bridge
          refuses to open, so this is a build failure rather than a
          warning. Set CC if your compiler is not `cc`.
          """)
      end
    else
      {:noop, []}
    end
  end

  @impl true
  def clean do
    File.rm(identity_path(@so))
    File.rm(@so)
  end

  @doc "This machine's compiler command: `CC` (or `cc`) and its arguments."
  def command, do: command(:os.type(), System.get_env("CC") || "cc", includes())

  @doc "The compiler command for an OS. Every OS but macOS gets the command used before macOS was supported."
  def command(os, cc, include_dirs) do
    link = if os == {:unix, :darwin}, do: ["-undefined", "dynamic_lookup"], else: []
    {cc, @flags ++ Enum.map(include_dirs, &"-I#{&1}") ++ link ++ ["-o", @so, @src]}
  end

  @doc "This machine's build identity."
  def identity, do: identity(:os.type(), arch(), command())

  @doc "A build identity, as text: the OS, the architecture and the compiler command."
  def identity(os, arch, {cc, args}) do
    all = [limit: :infinity, printable_limit: :infinity]
    "os: #{inspect(os)}\narch: #{arch}\ncommand: #{inspect([cc | args], all)}\n"
  end

  @doc "Where the record of an object's build sits: beside it."
  def identity_path(so), do: so <> ".identity"

  @doc "What a build records beside `so`: the identity it built under and the digest of the object it made."
  def record(identity, so) do
    digest = Base.encode16(:crypto.hash(:sha256, File.read!(so)), case: :lower)
    identity <> "object: sha256:" <> digest <> "\n"
  end

  @doc """
  Whether `so` must be rebuilt from `src` for a build whose identity is
  `identity`. Only an object this build recorded making, unchanged since,
  for this identity and newer than its source, is kept.
  """
  def stale?(so, src, identity) do
    with {:ok, %{mtime: so_time}} <- File.stat(so),
         {:ok, %{mtime: src_time}} <- File.stat(src),
         {:ok, recorded} <- File.read(identity_path(so)) do
      src_time > so_time or recorded != record(identity, so)
    else
      _ -> true
    end
  end

  defp arch, do: List.to_string(:erlang.system_info(:system_architecture))

  defp includes do
    root = List.to_string(:code.root_dir())
    erts = "erts-" <> List.to_string(:erlang.system_info(:version))
    Enum.filter([Path.join([root, erts, "include"]), Path.join([root, "usr", "include"])], &File.dir?/1)
  end
end

defmodule Ampd.MixProject do
  use Mix.Project

  def project do
    [app: :ampd, version: "0.1.0", elixir: "~> 1.14",
     compilers: [:ampd_fd] ++ Mix.compilers(),
     start_permanent: Mix.env() == :prod, deps: [],
     test_ignore_filters: [~r"fixtures/"]]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Ampd.Application, []}]
  end
end
