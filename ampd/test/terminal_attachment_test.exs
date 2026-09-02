defmodule Ampd.TerminalAttachmentTest do
  @moduledoc """
  D.1.3c·2b — the receive contract for the one answer that carries a
  descriptor.

  These do not need a host. They need a socketpair and something willing to
  send ancillary data badly, which is the point: the failures guarded against
  here are *transport* failures, and a real host is the one thing that will
  never produce them on purpose.

  Every test asserts on the **descriptor census** and not only on the return
  value. A receiver that answers correctly and leaks one descriptor per call
  is the exact defect this path exists to make impossible, and it is
  invisible to a test that only reads the tuple.
  """
  use ExUnit.Case, async: false

  alias Ampd.Worktree.EffectChannel

  @epoch "c2b00000000000000000000000000000"
  @schema "carrier-pty-attach-observation@1"

  setup do
    {mine, host} = Ampd.Transport.socketpair(:stream)

    on_exit(fn ->
      _ = :socket.close(mine)
      _ = :socket.close(host)
    end)

    {:ok, mine: mine, host: host}
  end

  # How many descriptors this OS process holds. The census the whole file
  # rests on — `/proc/self/fd` is where `super-host`'s own master census
  # reads too, so both halves of this lane count the same way.
  defp fds, do: length(File.ls!("/proc/self/fd"))

  # A descriptor worth passing: a real socket, so that the receiver's
  # `:socket.open(fd, %{dup: true})` auto-detect has something to accept.
  defp spare do
    {:ok, s} = :socket.open(:inet, :stream, :tcp)
    {:ok, fd} = :socket.getopt(s, :otp, :fd)
    {s, fd}
  end

  defp read_request(host) do
    {:ok, <<n::big-32>>} = :socket.recv(host, 4, 3000)
    {:ok, body} = :socket.recv(host, n, 3000)
    :json.decode(body)
  end

  defp frame(obs) do
    b = Ampd.Core.canon(obs)
    <<byte_size(b)::big-32>> <> b
  end

  defp ctrl([]), do: []

  defp ctrl(fds),
    do: [%{level: :socket, type: :rights, data: for(fd <- fds, into: <<>>, do: <<fd::native-32>>)}]

  defp send_obs(host, obs, fd_list),
    do: :socket.sendmsg(host, %{iov: [frame(obs)], ctrl: ctrl(fd_list)})

  defp obs(req, extra \\ %{}) do
    Map.merge(
      %{
        "schema" => @schema,
        "request_id" => req["request_id"],
        "channel_epoch" => req["channel_epoch"],
        "attached" => true,
        "attachment_ref" => "ta_" <> String.duplicate("a", 32),
        "attachment_epoch" => String.duplicate("b", 32),
        "pty_epoch" => String.duplicate("c", 32)
      },
      extra
    )
  end

  defp attach(mine) do
    EffectChannel.request_with_fd(
      mine,
      %{"channel_epoch" => @epoch},
      %{"schema" => "carrier-pty-attach-request@1", "op" => "pty-attach"},
      3000,
      @schema
    )
  end

  # A host stand-in: read the one request, hand it to the test, and let the
  # test decide what to send back.
  defp answering(host, fun), do: Task.async(fn -> fun.(read_request(host)) end)

  # -------------------------------------------------------- the happy path
  test "an attach answered with one descriptor hands exactly that one over", %{
    mine: mine,
    host: host
  } do
    {holder, fd} = spare()
    t = answering(host, fn req -> send_obs(host, obs(req), [fd]) end)

    assert {:ok, o, [got]} = attach(mine)
    Task.await(t)

    assert o["attached"] == true
    assert o["attachment_ref"] == "ta_" <> String.duplicate("a", 32)

    # **Already adopted.** Not a raw number the caller must remember to
    # own — a managed socket, which closes when its owner dies. That is the
    # whole difference between a descriptor with an exit under every branch
    # and one that has an exit only if the next line runs.
    assert is_tuple(got) and :socket.getopt(got, :otp, :fd) != :error

    :ok = :socket.close(got)
    :ok = :socket.close(holder)
  end

  test "a refusal carries no descriptor, and none is invented", %{mine: mine, host: host} do
    before = fds()
    t = answering(host, fn req ->
      send_obs(host, obs(req, %{"attached" => nil, "refused" => "no such carrier"}), [])
    end)

    assert {:ok, o, []} = attach(mine)
    Task.await(t)

    assert o["refused"] == "no such carrier"
    assert fds() == before
  end

  # ------------------------------------------------------------- truncation
  #
  # The measured failure this contract exists for: `ctrunc` is destructive
  # **and partial**, so a truncated receive can still have installed
  # descriptors. A receiver that failed on `ctrunc` without sinking them
  # would leak whatever landed — and would pass a test that only checked the
  # error.
  test "a control message too large to fit is refused AND leaves nothing behind", %{
    mine: mine,
    host: host
  } do
    spares = for _ <- 1..40, do: spare()
    before = fds()

    t = answering(host, fn req -> send_obs(host, obs(req), Enum.map(spares, &elem(&1, 1))) end)

    assert {:error, why} = attach(mine)
    Task.await(t)

    # Named as a truncation and not as a generic channel fault: the repair
    # for "the control buffer was too small" is not the repair for "the
    # socket broke", and a flattened sentence cannot tell them apart.
    assert why =~ "truncated the attach's ancillary data"
    assert why =~ "were closed"
    assert why =~ "no attachment was taken"

    # Whatever the kernel installed before truncating is gone again. Not
    # "no descriptors arrived" — the point is that some may have, and the
    # census is back where it started either way.
    assert fds() == before

    Enum.each(spares, fn {s, _} -> :socket.close(s) end)
  end

  # -------------------------------------------------------- correlation
  #
  # `match/6`'s discipline, with the addition that makes it safe here: a
  # skipped observation's descriptors are sunk before the skip. Without
  # that, a channel producing mismatches leaks one per frame until the
  # deadline.
  test "an observation for another request is skipped AND its descriptor sunk", %{
    mine: mine,
    host: host
  } do
    {h1, stale} = spare()
    {h2, good} = spare()
    before = fds()

    t =
      answering(host, fn req ->
        # Same channel, a request_id that was never asked for.
        send_obs(host, obs(req, %{"request_id" => "rq-not-this-one"}), [stale])
        send_obs(host, obs(req), [good])
      end)

    assert {:ok, _o, [got]} = attach(mine)
    Task.await(t)

    # One descriptor was handed over; the stale frame's was not, and did not
    # accumulate either. Net: exactly one more than before.
    assert fds() == before + 1

    :socket.close(got)
    :socket.close(h1)
    :socket.close(h2)
  end

  # ------------------------------------------------------------- framing
  #
  # `BufSz` is a ceiling, not a demand. The first receive asks for exactly
  # the four-byte prefix so that it cannot read past this frame into the
  # next one — the endpoint is shared and must be left aligned for whoever
  # reads it next.
  test "the receive does not read past its own frame", %{mine: mine, host: host} do
    {holder, fd} = spare()

    t =
      answering(host, fn req ->
        send_obs(host, obs(req), [fd])
        # A second, unrelated frame written immediately behind the first.
        # If the fd receive over-read, this is what it swallowed.
        :socket.send(host, frame(%{"schema" => "the-next-frame@1", "n" => 7}))
      end)

    assert {:ok, _o, [got]} = attach(mine)
    Task.await(t)

    assert {:ok, <<n::big-32>>} = :socket.recv(mine, 4, 3000)
    assert {:ok, body} = :socket.recv(mine, n, 3000)
    assert :json.decode(body)["schema"] == "the-next-frame@1"

    :socket.close(got)
    :socket.close(holder)
  end

  test "a length prefix that arrives in pieces is completed, not misread", %{
    mine: mine,
    host: host
  } do
    {holder, fd} = spare()

    t =
      answering(host, fn req ->
        full = frame(obs(req))
        <<head::binary-size(2), rest::binary>> = full
        # The rights ride the FIRST bytes — here, two of them.
        :socket.sendmsg(host, %{iov: [head], ctrl: ctrl([fd])})
        Process.sleep(30)
        :socket.send(host, rest)
      end)

    assert {:ok, o, [got]} = attach(mine)
    Task.await(t)

    assert o["schema"] == @schema
    :socket.close(got)
    :socket.close(holder)
  end

  # ------------------------------------------------- ownership before I/O
  #
  # **The falsifier for the seam's width.** The first draft carried bare
  # descriptor numbers through `complete_frame/4` — which performs blocking
  # `:socket.recv` calls with the remaining deadline — so a host that sent
  # the ancillary data and the length prefix and then stopped left a
  # descriptor owned by nobody for the whole timeout.
  #
  # Adoption now happens before any of that, so the same hostile silence
  # ends with the socket closed rather than leaked. This test fails against
  # the first draft and passes against the second, which is the only reason
  # to have it.
  test "a body that never arrives still leaves no descriptor outstanding", %{
    mine: mine,
    host: host
  } do
    {holder, fd} = spare()
    before = fds()

    t =
      answering(host, fn req ->
        full = frame(obs(req))
        <<head::binary-size(4), _rest::binary>> = full
        # The prefix and the rights, and then nothing at all.
        :socket.sendmsg(host, %{iov: [head], ctrl: ctrl([fd])})
      end)

    result =
      EffectChannel.request_with_fd(
        mine,
        %{"channel_epoch" => @epoch},
        %{"schema" => "carrier-pty-attach-request@1", "op" => "pty-attach"},
        300,
        @schema
      )

    assert {:error, _} = result
    Task.await(t)
    assert fds() == before

    :socket.close(holder)
  end

  # --------------------------------------------------- the seam, declared
  #
  # **This is not a defect being tested; it is a boundary being stated.**
  #
  # `recvmsg` installs the descriptor into the OS process's table before any
  # Erlang code runs. Between that instant and `adopt_socket/1` the
  # descriptor is owned by nobody: OTP will not close it, and a `:socket`
  # handle does not exist yet to die with anyone. Killing the receiving
  # process in that interval leaks one descriptor for the life of the VM.
  #
  # Closing it entirely would mean performing the `recvmsg` inside a NIF,
  # on a descriptor OTP is simultaneously polling — a second implementation
  # of OTP's readiness handling, on a dirty scheduler, duplicating framing
  # this module already has. That is refused, and this test is what refusing
  # it costs, written down.
  #
  # The consequence is bounded and it is DENIAL, not escalation: a leaked
  # endpoint keeps the host's pump from seeing EOF, so one Carrier's single
  # attachment slot stays occupied. No semantic record was committed, no
  # Peer possesses anything, and no Erlang code holds the number.
  test "an unadopted descriptor stays open and its peer sees no EOF — the seam, measured", %{
    mine: _mine,
    host: _host
  } do
    {a, b} = Ampd.Transport.socketpair(:stream)
    {:ok, raw} = :socket.getopt(b, :otp, :fd)
    before = fds()

    # Stand in for "the receive happened and the adoption did not": OTP is
    # asked to forget its handle without closing the number, which is
    # exactly the state `recvmsg` leaves behind.
    {:ok, dup} = :socket.open(raw, %{dup: true})
    after_receive = fds()
    assert after_receive == before + 1

    # The peer is still connected — no EOF — which is the whole
    # consequence: the host pump would not end.
    assert {:error, :timeout} = :socket.recv(a, 1, 50)

    # And the only thing that ends it is the sink this runtime owns.
    {:ok, dup_fd} = :socket.getopt(dup, :otp, :fd)
    :ok = :socket.close(dup)
    assert fds() == before
    assert Ampd.NativeFd.state(dup_fd) == :closed

    :socket.close(a)
    :socket.close(b)
  end

  # --------------------------------------------------------------- endings
  test "a channel that closes before answering is indeterminate, not a failure to attach", %{
    mine: mine,
    host: host
  } do
    t = answering(host, fn _req -> :socket.close(host) end)

    assert {:error, why} = attach(mine)
    Task.await(t)

    assert why =~ "closed before the attach was answered"
    assert why =~ "will not be resubmitted"
  end

  test "an observation of an unexpected schema is refused AND its descriptor sunk", %{
    mine: mine,
    host: host
  } do
    {holder, fd} = spare()
    before = fds()

    t =
      answering(host, fn req ->
        send_obs(host, obs(req, %{"schema" => "carrier-start-observation@1"}), [fd])
      end)

    assert {:error, why} = attach(mine)
    Task.await(t)

    assert why =~ "unknown observation schema"
    assert fds() == before

    :socket.close(holder)
  end
end
