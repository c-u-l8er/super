defmodule Ampd.NativeFdTest do
  @moduledoc """
  **What this file can and cannot prove, stated first.**

  It cannot prove the leak is gone. A descriptor with no Erlang owner is
  reachable only from an `SCM_RIGHTS` receive, and nothing inside the BEAM
  can construct one — every descriptor a test can name belongs to an OTP
  socket, and taking that from OTP corrupts its bookkeeping rather than
  modelling the case. The residue measurement lives in `super-host verify`
  against `/proc/<ampd>/fd`, which is the only place the case exists.

  What it proves is the parts that *are* reachable: that the sink loaded,
  that it reports a descriptor's three states rather than two, that it
  will not take the VM's own descriptors, and the rule that a bridge
  without a sink is refused rather than opened.

  And, since T30, the build's half: that macOS links with `-undefined
  dynamic_lookup` while Linux's command is exactly what it was, that an
  object is kept only when this build recorded making it for this machine,
  and that the object loaded is that one. What it does not exercise is a
  compiler failure: running the real task here would remove the object the
  rest of this suite is using. That refusal is the lane's to plant.
  """
  use ExUnit.Case, async: false
  alias Ampd.NativeFd
  alias Mix.Tasks.Compile.AmpdFd

  @old {{2020, 1, 1}, {0, 0, 0}}
  @new {{2021, 1, 1}, {0, 0, 0}}

  test "the descriptor sink is loaded — a runtime without it cannot dispose of what it receives" do
    assert NativeFd.available?() == true
  end

  test "a descriptor has three states, and a closed one is not an inheritable one" do
    {:ok, sock} = :socket.open(:inet, :stream, :tcp)
    {:ok, fd} = :socket.getopt(sock, :otp, :fd)

    assert NativeFd.state(fd) in [:cloexec, :inheritable]
    assert :ok = NativeFd.set_cloexec(fd)
    assert NativeFd.state(fd) == :cloexec

    :socket.close(sock)
    # Poll: OTP closes on its own schedule and this is about the state,
    # not the timing.
    Enum.reduce_while(1..50, nil, fn _, _ ->
      if NativeFd.state(fd) == :closed, do: {:halt, :ok}, else: {:cont, Process.sleep(20)}
    end)

    assert NativeFd.state(fd) == :closed
  end

  test "the sink has no exceptions — only a negative descriptor is not a descriptor" do
    # This test used to assert the opposite: that 0, 1 and 2 were refused,
    # because a received descriptor is never one of them. That is a fact
    # about how the host spawns the runtime — stdin from /dev/null, stdout
    # and stderr inherited — and not a fact about Linux, which hands
    # `SCM_RIGHTS` the lowest free number like any other `dup`. A GUI
    # session guarantees nothing of the sort, and a sink with an exception
    # is a descriptor with no exit, which is the whole bug class.
    assert_raise ArgumentError, fn -> NativeFd.close_received(-1) end

    # The hazard the floor was worried about is real and is closed where it
    # arises: the host guarantees 0, 1 and 2 are open in the child before
    # `exec`, so a received channel can never land on the runtime's stdout.
    for fd <- [0, 1, 2], do: assert(NativeFd.state(fd) != :closed)
  end

  test "discarding a descriptor that is not there is not an error to recover from" do
    # Linux frees the number before `close(2)` can report anything, so
    # there is nothing to retry and nothing for a caller to do. The sink
    # says `:ok` because that is the truth: the descriptor is not open.
    assert :ok = NativeFd.discard(999_999)
  end

  test "a bridge with no descriptor sink is refused, not opened" do
    # The bridge is the only source of raw descriptors in the runtime and
    # `Ampd.NativeFd` is the only disposal. Opening one without the other
    # is a runtime that leaks a descriptor per command and cannot say so —
    # which is the state F.8.1 shipped in, having measured only successful
    # binds.
    assert Ampd.Bridge.admissible?(3, true)
    refute Ampd.Bridge.admissible?(3, false)
    refute Ampd.Bridge.admissible?(nil, true)
  end

  describe "the build (T30)" do
    test "macOS links with -undefined dynamic_lookup; Linux's command is exactly today's" do
      {"cc", mac} = AmpdFd.command({:unix, :darwin}, "cc", ["/erts/include"])
      assert ["-undefined", "dynamic_lookup"] in Enum.chunk_every(mac, 2, 1)

      assert AmpdFd.command({:unix, :linux}, "cc", ["/erts/include", "/usr/include"]) ==
               {"cc",
                ["-fPIC", "-shared", "-O2", "-Wall", "-Wextra", "-I/erts/include", "-I/usr/include",
                 "-o", "priv/ampd_fd_nif.so", "c_src/ampd_fd_nif.c"]}

      refute "dynamic_lookup" in elem(AmpdFd.command({:unix, :linux}, "cc", []), 1)
    end

    test "CC is still honoured" do
      assert {"clang-17", _} = AmpdFd.command({:unix, :linux}, "clang-17", [])
      assert elem(AmpdFd.command(), 0) == (System.get_env("CC") || "cc")
    end

    test "an object recorded under a different identity is stale, even when newer than the source" do
      darwin = AmpdFd.command({:unix, :darwin}, "cc", ["/erts/include"])

      others = [
        # another machine entirely: what a fresh clone on the MacBook carried
        AmpdFd.identity({:unix, :linux}, "x86_64-pc-linux-gnu",
          AmpdFd.command({:unix, :linux}, "cc", ["/erts/include"])),
        # the same OS, another architecture
        AmpdFd.identity({:unix, :darwin}, "x86_64-apple-darwin25.6.0", darwin),
        # the same machine, another compiler command
        AmpdFd.identity({:unix, :darwin}, "aarch64-apple-darwin25.6.0",
          AmpdFd.command({:unix, :darwin}, "clang-17", ["/erts/include"]))
      ]

      for other <- others do
        {so, src} = object(other, src: @old, so: @new)
        assert AmpdFd.stale?(so, src, here()), "kept an object built as:\n" <> other
      end
    end

    test "a missing object is stale, even with a record beside where it was" do
      {so, src} = object(here())
      File.rm!(so)
      assert AmpdFd.stale?(so, src, here())
    end

    test "an object with no recorded identity is stale, even when newer than the source" do
      {so, src} = object(nil, src: @old, so: @new)
      assert AmpdFd.stale?(so, src, here())
    end

    test "a source newer than the object is stale, even when the identity matches" do
      {so, src} = object(here(), src: @new, so: @old)
      assert AmpdFd.stale?(so, src, here())
    end

    test "an object replaced after its build was recorded is stale" do
      # The planted case: a foreign object dropped over one this build made.
      {so, src} = object(here())
      File.write!(so, "an x86-64 ELF planted afterwards\n")
      File.touch!(so, @new)
      assert AmpdFd.stale?(so, src, here())
    end

    test "one built here, for this machine, and newer than the source is kept" do
      {so, src} = object(here(), src: @old, so: @new)
      refute AmpdFd.stale?(so, src, here())
    end

    test "the loaded helper is this machine's" do
      assert NativeFd.available?() == true

      so = Path.join(:code.priv_dir(:ampd), "ampd_fd_nif.so")
      assert {:ok, recorded} = File.read(AmpdFd.identity_path(so))
      assert recorded == AmpdFd.record(AmpdFd.identity(), so)
    end
  end

  # The identity the staleness tests build "here": the MacBook's.
  defp here do
    AmpdFd.identity({:unix, :darwin}, "aarch64-apple-darwin25.6.0",
      AmpdFd.command({:unix, :darwin}, "cc", ["/erts/include"]))
  end

  # A source and an object in a scratch directory, the object recorded as
  # built under `identity` (or not recorded at all, for `nil`).
  defp object(identity, times \\ []) do
    dir = scratch()
    src = Path.join(dir, "ampd_fd_nif.c")
    so = Path.join(dir, "ampd_fd_nif.so")

    File.write!(src, "/* source */\n")
    File.touch!(src, Keyword.get(times, :src, @old))
    File.write!(so, "an object\n")
    File.touch!(so, Keyword.get(times, :so, @new))

    if identity, do: File.write!(AmpdFd.identity_path(so), AmpdFd.record(identity, so))
    {so, src}
  end

  defp scratch do
    name = "ampd-native-fd-test-#{System.pid()}-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), name)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
