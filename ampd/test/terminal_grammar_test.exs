defmodule Ampd.TerminalGrammarTest do
  @moduledoc """
  D.1.3c·2b·0a — the attach answer's grammar, and the lifetimes either side
  of activation.

  Every malformed shape here is one a real host will never produce. That is
  precisely why none of them was refused until now: the valid cases were
  tested and the invalid ones were unreachable from any test that used a
  real host. `Ampd.Carrier.Terminal.interpret/2` is a total function over
  the answer so they become reachable.
  """
  use ExUnit.Case, async: false

  alias Ampd.Carrier.Terminal
  alias Ampd.TerminalAttachment, as: TA

  @identity %{
    "attachment_ref" => "ta_" <> String.duplicate("a", 32),
    "attachment_epoch" => String.duplicate("b", 32),
    "pty_epoch" => String.duplicate("c", 32),
    "carrier_ref" => "cr_0001",
    "carrier_epoch" => String.duplicate("d", 32)
  }

  defp fds, do: length(File.ls!("/proc/self/fd"))
  defp closed?(s), do: :socket.getopt(s, :otp, :fd) == {:error, :closed}
  defp sock, do: (fn {:ok, s} -> s end).(:socket.open(:inet, :stream, :tcp))

  defp attached(extra \\ %{}),
    do: Map.merge(Map.put(@identity, "attached", true), extra)

  defp refused(why \\ "no such carrier"),
    do: %{"schema" => Terminal.observation_schema(), "refused" => why}

  # ------------------------------------------------------- A · cardinality
  test "attached with exactly one descriptor is the only success" do
    s = sock()
    assert {:ok, obs, ^s} = Terminal.interpret(attached(), [s])
    assert obs["attached"] == true
    refute closed?(s)
    :socket.close(s)
  end

  test "a refusal with no descriptor is a refusal, not an error" do
    assert {:refused, obs} = Terminal.interpret(refused(), [])
    assert obs["refused"] == "no such carrier"
  end

  test "attached with ZERO descriptors is refused as a protocol failure" do
    before = fds()
    assert {:error, why} = Terminal.interpret(attached(), [])
    assert why =~ "reported an attachment and sent no stream descriptor"
    assert fds() == before
  end

  test "attached with TWO descriptors is refused, and both are closed" do
    a = sock()
    b = sock()
    assert {:error, why} = Terminal.interpret(attached(), [a, b])
    assert why =~ "sent 2 stream descriptors"

    # The census is the assertion. A rejection that returned without closing
    # would be a protocol error that leaks — which is the shape this lane
    # keeps finding.
    assert closed?(a)
    assert closed?(b)
  end

  test "a refusal that nonetheless carries a descriptor is refused, and it is closed" do
    s = sock()
    assert {:error, why} = Terminal.interpret(refused(), [s])
    assert why =~ "refused the attach and sent 1 stream descriptor"
    assert closed?(s)
  end

  test "an answer that is both attached and refused is refused" do
    s = sock()
    assert {:error, why} = Terminal.interpret(Map.merge(attached(), refused()), [s])
    assert why =~ "both attached and refused"
    assert closed?(s)
  end

  test "an answer that is neither attached nor refused is refused" do
    s = sock()
    assert {:error, why} = Terminal.interpret(%{"schema" => "x"}, [s])
    assert why =~ "neither attached nor refused"
    assert closed?(s)
  end

  # ------------------------------------------------------------- E · identity
  #
  # A record that describes a different attachment must not activate a
  # process that physically owns this one. A trusted caller should not make
  # that mistake; the point of a local invariant is that trusted mistakes
  # stay falsifiable.
  describe "activation binds the record to the stream it owns" do
    setup do
      {mine, theirs} = Ampd.Transport.socketpair(:stream)
      {:ok, pid} = TA.Supervisor.start_owner(%{sock: mine, setup: self(), identity: @identity})
      :ok = :socket.setopt(mine, {:otp, :controlling_process}, pid)
      on_exit(fn -> _ = :socket.close(theirs) end)
      {:ok, pid: pid, mine: mine, theirs: theirs}
    end

    test "a record for another attachment is refused and nothing activates", %{
      pid: pid,
      theirs: theirs
    } do
      other = Map.put(@identity, "attachment_ref", "ta_" <> String.duplicate("f", 32))

      assert {:error, {:identity_mismatch, ["attachment_ref"]}} = TA.activate(pid, other, self())
      assert TA.state(pid) == :provisional
      assert TA.record(pid) == nil

      # And it is still not a way to read the terminal.
      :ok = :socket.send(theirs, "secret\n")
      assert {:error, :provisional} = TA.read(pid)

      TA.close(pid)
    end

    test "every bound field is checked, not just the ref", %{pid: pid} do
      wrong = Map.put(@identity, "pty_epoch", String.duplicate("9", 32))
      assert {:error, {:identity_mismatch, ["pty_epoch"]}} = TA.activate(pid, wrong, self())
      assert TA.state(pid) == :provisional
      TA.close(pid)
    end

    test "the matching record activates", %{pid: pid} do
      assert :ok = TA.activate(pid, @identity, self())
      assert TA.state(pid) == :active
      TA.close(pid)
    end
  end

  # ---------------------------------------------------------- D · lifetimes
  #
  # The defect: the setup monitor was kept after activation, so an ACTIVE
  # attachment died with the transaction that created it rather than with
  # the Peer that possesses it.
  test "an ACTIVE attachment survives the setup caller and dies with its owner" do
    {mine, theirs} = Ampd.Transport.socketpair(:stream)
    parent = self()

    owner = spawn(fn -> receive do :stop -> :ok end end)

    setup_caller =
      spawn(fn ->
        receive do :go -> :ok end
        {:ok, pid} = TA.Supervisor.start_owner(%{sock: mine, setup: self(), identity: @identity})
        :ok = :socket.setopt(mine, {:otp, :controlling_process}, pid)
        :ok = TA.activate(pid, @identity, owner)
        send(parent, {:owner, pid})
        receive do :die -> :ok end
      end)

    :ok = :socket.setopt(mine, {:otp, :controlling_process}, setup_caller)
    send(setup_caller, :go)
    pid = receive do {:owner, p} -> p after 2000 -> flunk("no owner") end

    assert TA.state(pid) == :active

    # The setup transaction ends. The attachment must NOT.
    ref = Process.monitor(setup_caller)
    send(setup_caller, :die)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3000
    Process.sleep(150)

    assert Process.alive?(pid), "an ACTIVE attachment died with its setup caller"
    assert TA.state(pid) == :active
    refute closed?(mine)

    # The possessing Peer ends. The attachment must.
    aref = Process.monitor(pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^aref, :process, _, _}, 3000
    assert closed?(mine)

    :socket.close(theirs)
  end

  # ------------------------------------------------------------- B · ancillary
  #
  # **A real-socket falsifier is not producible here, and that is measured
  # rather than assumed.** On Linux, `sendmsg` refuses every control message
  # other than `SCM_RIGHTS` on an AF_UNIX stream socket:
  #
  #     :timestamp {:error, :einval} · :credentials {:error, :einval}
  #     :origdstaddr {:error, {:invalid, ...}} · raw 99 {:error, :einval}
  #
  # So the kernel will not manufacture this case, and the branch is
  # defensive. These drive the **production** parser with the control list
  # OTP would have decoded — not a copy of it, which would prove nothing
  # about the one in the receive path.
  describe "the ancillary shape is validated as a whole" do
    alias Ampd.Worktree.EffectChannel, as: EC

    test "a control list of only rights is accepted, and unpacked" do
      assert {:ok, [7, 9]} = EC.ancillary([%{level: :socket, type: :rights, data: <<7::native-32, 9::native-32>>}])
      assert {:ok, []} = EC.ancillary([])
    end

    test "rights PLUS an unknown control message is refused — and carries the rights out to be sunk" do
      ctrl = [
        %{level: :socket, type: :rights, data: <<11::native-32>>},
        %{level: :socket, type: :timestamp, data: <<0::64, 0::64>>}
      ]

      assert {:error, {:unexpected_ancillary, [{:socket, :timestamp}]}, [11]} = EC.ancillary(ctrl)
    end

    test "an unknown control message alone is refused" do
      assert {:error, {:unexpected_ancillary, _}, []} =
               EC.ancillary([%{level: :ip, type: :pktinfo, data: <<0::32>>}])
    end

    # A rights payload is a whole number of descriptors. The comprehension
    # this replaced silently dropped the tail of a ragged one, which is the
    # sender and this reader disagreeing about the encoding and nobody
    # noticing.
    test "a ragged rights payload is refused, and what did parse is carried out" do
      assert {:error, :ragged_rights, [3]} =
               EC.ancillary([%{level: :socket, type: :rights, data: <<3::native-32, 0, 0>>}])
    end

    test "a rights message whose data is not a binary is refused" do
      assert {:error, :malformed_rights, []} =
               EC.ancillary([%{level: :socket, type: :rights, data: :not_a_binary}])
    end

    test "anything that is not a control list at all is refused" do
      assert {:error, :unreadable_ancillary, []} = EC.ancillary(:nonsense)
    end
  end
end
