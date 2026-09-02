defmodule Ampd.TerminalOwnerTest do
  @moduledoc """
  D.1.3c·2b — the PROVISIONAL owner, and the cuts its state machine exists
  for.

  The transport suite proves a descriptor arrives with an owner. This proves
  that owning it is **not yet possessing an attachment**, and that every way
  the setup can fall over ends with the stream closed and nothing published.

  Ownership is measured rather than asserted: `:socket.getopt(s, :otp, :fd)`
  answering `{:error, :closed}` is what "the stream is gone" means here.
  """
  use ExUnit.Case, async: false

  alias Ampd.TerminalAttachment, as: TA

  @identity %{
    "attachment_ref" => "ta_" <> String.duplicate("a", 32),
    "attachment_epoch" => String.duplicate("b", 32),
    "pty_epoch" => String.duplicate("c", 32),
    "carrier_ref" => "cr_0001",
    "carrier_epoch" => String.duplicate("d", 32)
  }

  defp closed?(s), do: :socket.getopt(s, :otp, :fd) == {:error, :closed}

  # A pair whose ends this test process owns.
  defp pair, do: Ampd.Transport.socketpair(:stream)

  # Start an owner from THIS process, then complete the handover the way the
  # real caller does. The transfer is a separate step on purpose: it is the
  # boundary every cut below is defined relative to.
  defp start_owner(sock) do
    {:ok, pid} = TA.Supervisor.start_owner(%{sock: sock, setup: self(), identity: @identity})
    pid
  end

  defp transfer(sock, pid), do: :socket.setopt(sock, {:otp, :controlling_process}, pid)

  # ------------------------------------------------------------- J.1 / J.2
  test "the current owner can transfer the stream, and nobody else can" do
    {mine, theirs} = pair()
    pid = start_owner(mine)

    # J.2 first, because doing it second would be testing a socket that has
    # already moved. A process that merely holds the term is not the owner.
    parent = self()
    spawn(fn -> send(parent, {:from_stranger, transfer(mine, pid)}) end)
    assert_receive {:from_stranger, {:error, {:invalid, :not_owner}}}, 2000

    # J.1
    assert :ok = transfer(mine, pid)
    assert TA.state(pid) == :provisional

    TA.close(pid)
    :socket.close(theirs)
  end

  # ----------------------------------------------------------------- J.3
  test "a provisional attachment refuses bytes in both directions" do
    {mine, theirs} = pair()
    pid = start_owner(mine)
    :ok = transfer(mine, pid)

    # Bytes that physically arrived before the commit. They are readable at
    # the kernel and are nobody's observation.
    :ok = :socket.send(theirs, "prompt$ ")

    assert {:error, :provisional} = TA.read(pid)
    assert {:error, :provisional} = TA.write(pid, "ls\n")
    assert TA.record(pid) == nil

    TA.close(pid)
    :socket.close(theirs)
  end

  # ----------------------------------------------------------------- J.4
  #
  # Before the transfer the caller still owns the stream, so its death closes
  # the socket on its own; the owner's monitor is what ends the process. Both
  # halves are asserted, because "the child stopped" without "the stream
  # closed" would be a leak with a tidy supervision tree.
  test "the setup caller dying BEFORE the transfer closes the stream and ends the owner" do
    {mine, theirs} = pair()
    parent = self()

    # The handover is staged: only the current owner may transfer, so THIS
    # process hands the stream to the caller and the caller waits until it
    # actually owns it before doing anything.
    caller = spawn(fn ->
      receive do :go -> :ok end
      {:ok, pid} = TA.Supervisor.start_owner(%{sock: mine, setup: self(), identity: @identity})
      send(parent, {:owner, pid})
      receive do :die -> :ok end
    end)

    :ok = transfer(mine, caller)
    send(caller, :go)

    pid = receive do {:owner, p} -> p after 2000 -> flunk("no owner") end
    ref = Process.monitor(pid)

    send(caller, :die)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3000
    assert closed?(mine)

    :socket.close(theirs)
  end

  # ----------------------------------------------------------------- J.5
  test "the owner dying BEFORE the transfer leaves the caller still able to close" do
    {mine, theirs} = pair()
    pid = start_owner(mine)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 3000

    # Never transferred, so this process is still the owner and the stream is
    # still open — which is the point: the failure did not strand it.
    refute closed?(mine)
    assert :ok = :socket.close(mine)
    assert closed?(mine)

    :socket.close(theirs)
  end

  # ----------------------------------------------------------------- J.6
  #
  # **The cut the state machine exists for.** After the transfer the caller's
  # death does NOT close the socket — measured on OTP 28.2 — so without the
  # monitor a provisional attachment would hold the Carrier's only slot open
  # until the VM exited.
  test "the setup caller dying AFTER the transfer, before commit, closes via the owner" do
    {mine, theirs} = pair()
    parent = self()

    caller = spawn(fn ->
      receive do :go -> :ok end
      {:ok, pid} = TA.Supervisor.start_owner(%{sock: mine, setup: self(), identity: @identity})
      # The caller owns it at this point, so this transfer is the real one.
      :ok = transfer(mine, pid)
      send(parent, {:owner, pid})
      receive do :die -> :ok end
    end)

    :ok = transfer(mine, caller)
    send(caller, :go)

    pid = receive do {:owner, p} -> p after 2000 -> flunk("no owner") end
    assert TA.state(pid) == :provisional
    refute closed?(mine)

    ref = Process.monitor(pid)
    send(caller, :die)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3000

    assert closed?(mine)
    :socket.close(theirs)
  end

  # ----------------------------------------------------------------- J.7
  test "an ORDERED B refusal closes the stream and publishes nothing" do
    {mine, theirs} = pair()
    pid = start_owner(mine)
    :ok = transfer(mine, pid)

    # The refusal path is not a message to this process — it is the caller
    # deciding not to activate and disposing of what it holds.
    assert TA.record(pid) == nil
    ref = Process.monitor(pid)
    TA.close(pid)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3000

    assert closed?(mine)
    :socket.close(theirs)
  end

  # ----------------------------------------------------------------- J.8
  test "ORDERED B success activates exactly once, and a second attempt is refused" do
    {mine, theirs} = pair()
    pid = start_owner(mine)
    :ok = transfer(mine, pid)

    record = Map.put(@identity, "schema", "terminal-attachment@1")
    assert :ok = TA.activate(pid, record)
    assert TA.state(pid) == :active
    assert TA.record(pid) == record

    assert {:error, {:not_provisional, :active}} = TA.activate(pid, record)

    # And only now do bytes mean anything.
    :ok = :socket.send(theirs, "hello\n")
    assert {:ok, "hello\n"} = TA.read(pid, 6, 2000)
    assert :ok = TA.write(pid, "ls\n")
    assert {:ok, "ls\n"} = :socket.recv(theirs, 3, 2000)

    TA.close(pid)
    :socket.close(theirs)
  end

  # ----------------------------------------------------------------- J.9
  test "an ACTIVE owner's death closes the stream — possession does not outlive its process" do
    {mine, theirs} = pair()
    pid = start_owner(mine)
    :ok = transfer(mine, pid)
    :ok = TA.activate(pid, Map.put(@identity, "schema", "terminal-attachment@1"))

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 3000

    # `terminate/2` does not run on a kill; the socket closes because it
    # died with its owner, which is the guarantee being relied on.
    assert closed?(mine)
    :socket.close(theirs)
  end

  # ---------------------------------------------------------------- bounded
  test "a provisional attachment that is never activated does not wait forever" do
    assert TA.setup_deadline_ms() > 0
    assert TA.setup_deadline_ms() <= 60_000
  end

  # ----------------------------------------------------------------- J.12
  #
  # A source census, not a behaviour: the public surface must not hand a bare
  # descriptor number to anything. `read/1` returns bytes, `write/2` returns
  # `:ok`, and nothing returns an integer that a caller could be expected to
  # own.
  test "no public runtime API returns a raw descriptor" do
    src = File.read!("lib/ampd/terminal_attachment.ex")

    refute src =~ ~r/def\s+fd\b/
    refute src =~ ~r/def\s+raw_fd/
    refute src =~ ~r/def\s+socket\b/
    # `getopt(:otp, :fd)` is how a TEST measures closedness; the module
    # itself must not be reaching for the number.
    refute src =~ ~r/:otp, :fd/
  end
end
