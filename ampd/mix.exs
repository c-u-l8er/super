defmodule Mix.Tasks.Compile.AmpdFd do
  @moduledoc """
  Build `Ampd.NativeFd`'s shared object with the C compiler already on the
  box.

  **Not `elixir_make`, and this is the reason.** `ampd` has `deps: []`, and
  that is load-bearing rather than tidy: the runtime is the thing trusted
  to name identities, and the smaller the set of code that ships inside
  that boundary the smaller the claim. Three syscalls do not justify a
  dependency tree, and a twenty-line compiler task is readable in full —
  the same argument `host/src/fdpass.rs` makes for declaring `sendmsg` by
  hand rather than pulling in a crate.

  It **refuses** rather than degrades. A build that quietly produced a
  runtime with no descriptor sink would be a leaking runtime that says
  nothing, which is the failure mode this whole round exists to end.
  """
  use Mix.Task.Compiler

  @so "priv/ampd_fd_nif.so"
  @src "c_src/ampd_fd_nif.c"

  @impl true
  def run(_argv) do
    File.mkdir_p!("priv")

    if stale?() do
      cc = System.get_env("CC") || "cc"

      args =
        ["-fPIC", "-shared", "-O2", "-Wall", "-Wextra"] ++
          Enum.map(includes(), &"-I#{&1}") ++ ["-o", @so, @src]

      case System.cmd(cc, args, stderr_to_stdout: true) do
        {_, 0} ->
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
  def clean, do: File.rm(@so)

  defp includes do
    root = List.to_string(:code.root_dir())
    erts = "erts-" <> List.to_string(:erlang.system_info(:version))
    Enum.filter([Path.join([root, erts, "include"]), Path.join([root, "usr", "include"])], &File.dir?/1)
  end

  defp stale? do
    case {File.stat(@so), File.stat(@src)} do
      {{:ok, so}, {:ok, src}} -> src.mtime > so.mtime
      _ -> true
    end
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
