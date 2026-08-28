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
  """
  use ExUnit.Case, async: false
  alias Ampd.NativeFd

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
end
