defmodule Ampd.T28HostBridgeFramedTest do
  @moduledoc """
  T28's laws on the runtime's side of the FRAMED bridge (`superlane/t28/TASK.md`), on a stream pair, as the bridge is on
  macOS and on Linux under the host's test feature: `HostBridge.start/1` reads a stream bridge with `framed_loop/2`.

    * L1 — frames several to a write are answered in that sequence; a zero-length frame is one frame, answered once;
      a reply is a big-endian u32 length and its body;
    * L2 — frames A (no rights), B (one) and C (two), written before the loop runs, each bind exactly their own rights
      (traffic proves which socket each actor holds); rights on a later byte than a frame's first, prefix bytes 2-4
      included, are refused with that frame, and the next frame is unaffected;
    * L3 — after 100 frames of 0 to 16 rights, with refusals and violations, the runtime's descriptors are back at
      their baseline; an over-limit frame's rights are sunk;
    * L4 — an arrival that cannot be marked is closed with every other arrival, and `take/3` ends the read on it;
    * L5 — a frame delivered a byte at a time is one frame with its rights;
    * L6 — the host's close at a frame boundary ends the loop; a close inside a frame runs nothing and sinks its rights;
    * L7 — exactly 8,192 bytes is a command; 8,193 announced is refused before its body is read, and the bridge ends.

  Each test asserts only what its law says (L3 alone counts descriptors), so a plant is caught by its own law alone.
  """
  use ExUnit.Case, async: false
  alias Ampd.Transport.HostBridge

  setup do
    Ampd.Bridge.reset()
    {runtime, host} = Ampd.Transport.socketpair(:stream)
    {:ok, bridge} = HostBridge.start(runtime)
    on_exit(fn -> stop(bridge, [host, runtime]) end)
    %{host: host, runtime: runtime, bridge: bridge}
  end

  defp stop(bridge, socks) do
    # Unlinked first: HostBridge.start/1 links the loop to whoever started it, and that may be the test itself.
    Process.unlink(bridge)
    ref = Process.monitor(bridge)
    Process.exit(bridge, :kill)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      2_000 -> :ok
    end

    Enum.each(socks, &:socket.close/1)
  end

  defp cmd(name, extra \\ %{}), do: Map.merge(%{"schema" => "bridge-command@1", "command" => name}, extra)
  defp frame(%{} = m), do: frame(JSON.encode!(m))
  defp frame(bytes) when is_binary(bytes), do: <<byte_size(bytes)::big-32>> <> bytes

  # A command whose JSON is exactly `size` bytes: `map` plus a "pad" string of spaces.
  defp padded(map, size) do
    base = byte_size(JSON.encode!(Map.put(map, "pad", "")))
    bytes = JSON.encode!(Map.put(map, "pad", String.duplicate(" ", size - base)))
    ^size = byte_size(bytes)
    bytes
  end

  defp reply(host) do
    {:ok, <<n::big-32>>} = :socket.recv(host, 4, 3_000)
    {:ok, body} = :socket.recv(host, n, 3_000)
    JSON.decode!(body)
  end

  defp rights(socks) do
    data = for s <- socks, into: <<>>, do: (fn {:ok, fd} -> <<fd::native-32>> end).(:socket.getopt(s, {:otp, :fd}))
    [%{level: :socket, type: :rights, data: data}]
  end

  # /proc on Linux; /dev/fd on macOS (MP2; the Mac lane's finding C). A listing's own descriptor cancels out.
  defp beam_fds, do: length(File.ls!(if :os.type() == {:unix, :darwin}, do: "/dev/fd", else: "/proc/self/fd"))
  defp actors, do: Ampd.Bridge.list() |> Enum.map(&(&1["actor"] || &1[:actor]))

  # The socket the runtime adopted for `actor`, from the bridge's own state.
  defp adopted(actor) do
    :sys.get_state(Ampd.Bridge).channels |> Map.values() |> Enum.find_value(&(&1.meta["actor"] == actor && &1.sock))
  end

  # Whether `probe`, written on `from`, comes out of `at` within 2 s (whatever else the channel says first).
  defp heard(at, from, probe) do
    :ok = :socket.send(from, probe)
    listen(at, probe, <<>>, System.monotonic_time(:millisecond) + 2_000)
  end

  defp listen(at, probe, acc, until) do
    left = until - System.monotonic_time(:millisecond)

    cond do
      String.contains?(acc, probe) -> true
      left <= 0 -> false
      true ->
        case :socket.recv(at, 0, left) do
          {:ok, b} -> listen(at, probe, acc <> b, until)
          _ -> false
        end
    end
  end

  # ---- L1

  test "L1 · frames several to a write are answered in that sequence", ctx do
    :ok = :socket.send(ctx.host, frame(cmd("runtime_status")) <> frame(cmd("not-a-command")) <> frame(cmd("list_channels")))
    a = reply(ctx.host)
    assert a["ok"] == true and Map.has_key?(a, "runtime")
    assert reply(ctx.host)["refusal"]["code"] == "invalid-bridge-command"
    assert is_list(reply(ctx.host)["channels"])
  end

  test "L1 · a zero-length frame is one frame, answered once", ctx do
    :ok = :socket.send(ctx.host, <<0::32>> <> frame(cmd("runtime_status")))
    assert reply(ctx.host)["refusal"]["code"] == "unknown-bridge-command"
    assert reply(ctx.host)["ok"] == true
  end

  test "L1 · a reply is a big-endian u32 length and its body", ctx do
    :ok = :socket.send(ctx.host, frame(cmd("runtime_status")))
    {:ok, <<n::big-32>>} = :socket.recv(ctx.host, 4, 3_000)
    {:ok, body} = :socket.recv(ctx.host, n, 3_000)
    assert JSON.decode!(body)["ok"] == true
  end

  # ---- L2

  test "L2 · frames A, B and C written before the loop runs each bind exactly their own rights" do
    Ampd.Bridge.reset()
    {runtime, host} = Ampd.Transport.socketpair(:stream)
    {b1x, b1y} = Ampd.Transport.socketpair(:stream)
    {c1x, c1y} = Ampd.Transport.socketpair(:stream)
    {c2x, c2y} = Ampd.Transport.socketpair(:stream)
    :ok = :socket.send(host, frame(cmd("runtime_status")))
    :ok = :socket.sendmsg(host, %{iov: [frame(cmd("bind_agent_channel", %{"actor" => "t28-b"}))], ctrl: rights([b1y])})
    :ok = :socket.sendmsg(host, %{iov: [frame(cmd("bind_agent_channel", %{"actor" => "t28-c"}))], ctrl: rights([c1y, c2y])})
    {:ok, bridge} = HostBridge.start(runtime)
    a = reply(host)
    b = reply(host)
    c = reply(host)
    assert a["ok"] == true and Map.has_key?(a, "runtime"), "A: #{inspect(a)}"
    assert b["ok"] == true and b["actor"] == "t28-b", "B: #{inspect(b)}"
    assert c["ok"] == true and c["actor"] == "t28-c", "C: #{inspect(c)}"
    # Traffic proves which socket each actor holds (Codex review 1, finding 6): bytes written on an actor's adopted end
    # come out of the other end of the pair whose right was sent: b1x for B, c1x (C's first right) for C.
    assert heard(b1x, adopted("t28-b"), "probe-b"), "t28-b does not hold the right B sent"
    assert heard(c1x, adopted("t28-c"), "probe-c"), "t28-c does not hold C's first right"
    stop(bridge, [host, runtime, b1x, b1y, c1x, c1y, c2x, c2y])
  end

  test "L2 · rights on prefix byte 2, 3 or 4 are refused with that frame; the next frame is unaffected" do
    for k <- 1..3 do
      Ampd.Bridge.reset()
      {runtime, host} = Ampd.Transport.socketpair(:stream)
      {x, y} = Ampd.Transport.socketpair(:stream)
      body = JSON.encode!(cmd("bind_agent_channel", %{"actor" => "t28-prefix-#{k}"}))
      <<pre::binary-size(k), rest::binary>> = <<byte_size(body)::big-32>>
      # Queued before the loop runs, so on Linux one longer read would collect the right with the frame's first byte.
      :ok = :socket.send(host, pre)
      :ok = :socket.sendmsg(host, %{iov: [rest <> body], ctrl: rights([y])})
      :ok = :socket.send(host, frame(cmd("runtime_status")))
      {:ok, bridge} = HostBridge.start(runtime)
      assert reply(host)["refusal"]["code"] == "invalid-bridge-frame", "prefix byte #{k + 1}"
      refute "t28-prefix-#{k}" in actors(), "a right on prefix byte #{k + 1} was bound"
      assert reply(host)["ok"] == true, "prefix byte #{k + 1}: the next frame"
      stop(bridge, [host, runtime, x, y])
    end
  end

  test "L2 · rights on a later byte than a frame's first are refused with that frame; the next frame is unaffected", ctx do
    {x, y} = Ampd.Transport.socketpair(:stream)
    body = JSON.encode!(cmd("bind_agent_channel", %{"actor" => "t28-late"}))
    :ok = :socket.send(ctx.host, <<byte_size(body)::big-32>>)
    :ok = :socket.sendmsg(ctx.host, %{iov: [body], ctrl: rights([y])})
    assert reply(ctx.host)["refusal"]["code"] == "invalid-bridge-frame"
    refute "t28-late" in actors(), "a late right was bound"
    :ok = :socket.send(ctx.host, frame(cmd("runtime_status")))
    assert reply(ctx.host)["ok"] == true
    :socket.close(x)
    :socket.close(y)
  end

  # ---- L3

  test "L3 · after 100 frames of 0 to 16 rights, refusals and violations, the descriptors are back at baseline", ctx do
    {x, y} = Ampd.Transport.socketpair(:stream)
    before = beam_fds()

    for i <- 0..99 do
      n = rem(i, 17)
      ctrl = if n > 0, do: rights(List.duplicate(y, n)), else: nil
      body = JSON.encode!(cmd("not-a-command", %{"i" => i}))

      cond do
        ctrl == nil ->
          :ok = :socket.send(ctx.host, frame(body))

        rem(i, 2) == 0 ->
          :ok = :socket.sendmsg(ctx.host, %{iov: [frame(body)], ctrl: ctrl})

        true ->
          :ok = :socket.send(ctx.host, <<byte_size(body)::big-32>>)
          :ok = :socket.sendmsg(ctx.host, %{iov: [body], ctrl: ctrl})
      end

      _ = reply(ctx.host)
    end

    assert beam_fds() <= before, "100 frames left #{beam_fds() - before} descriptors open"
    :socket.close(x)
    :socket.close(y)
  end

  test "L3 · an over-limit frame's rights are sunk" do
    Ampd.Bridge.reset()
    {runtime, host} = Ampd.Transport.socketpair(:stream)
    {x, y} = Ampd.Transport.socketpair(:stream)
    {:ok, bridge} = HostBridge.start(runtime)
    before = beam_fds()
    :ok = :socket.sendmsg(host, %{iov: [<<9_000::32>>], ctrl: rights([y, y, y])})
    assert reply(host)["refusal"]["code"] == "frame-too-large"
    Process.sleep(100)
    assert beam_fds() <= before, "an over-limit frame left #{beam_fds() - before} descriptors open"
    stop(bridge, [host, runtime, x, y])
  end

  # ---- L4

  test "L4 · an arrival that cannot be marked is closed with every other arrival, and the read ends" do
    {a, b} = Ampd.Transport.socketpair(:stream)
    {x, y} = Ampd.Transport.socketpair(:stream)
    {p, q} = Ampd.Transport.socketpair(:stream)
    :ok = :socket.sendmsg(a, %{iov: ["r"], ctrl: rights([y, q])})
    {:ok, msg} = :socket.recvmsg(b, 1, 64, [], 3_000)
    fds = for %{type: :rights, data: d} <- msg.ctrl, <<fd::native-32 <- d>>, do: fd
    assert length(fds) == 2
    assert HostBridge.mark_arrivals(fds, fn _fd -> {:error, :eio} end) == :closed
    assert Enum.all?(fds, &(Ampd.NativeFd.state(&1) == :closed)), "an arrival that could not be marked was kept"
    assert HostBridge.mark_arrivals([], fn _fd -> {:error, :eio} end) == :ok
    Enum.each([a, b, x, y, p, q], &:socket.close/1)
  end

  test "L4 · the framed reader's take/3 ends the read when an arrival cannot be marked (its text)" do
    src = File.read!(Path.join(__DIR__, "../lib/ampd/transport.ex"))
    [_, from_take] = String.split(src, "    defp take(sock, <<>>, want) do\n", parts: 2)
    [take, _] = String.split(from_take, "\n    end\n", parts: 2)
    assert take =~ "with :ok <- mark_arrivals(fds) do", "take/3 does not end the read on a failed mark"
  end

  # ---- L5

  test "L5 · a frame delivered a byte at a time is one frame with its rights", ctx do
    {x, y} = Ampd.Transport.socketpair(:stream)
    <<first, rest::binary>> = frame(cmd("bind_agent_channel", %{"actor" => "t28-slow"}))
    :ok = :socket.sendmsg(ctx.host, %{iov: [<<first>>], ctrl: rights([y])})

    for <<b <- rest>> do
      Process.sleep(3)
      :ok = :socket.send(ctx.host, <<b>>)
    end

    r = reply(ctx.host)
    assert r["ok"] == true and r["actor"] == "t28-slow", inspect(r)
    :socket.close(x)
    :socket.close(y)
  end

  # ---- L6

  test "L6 · the host's close at a frame boundary ends the loop", ctx do
    ref = Process.monitor(ctx.bridge)
    :ok = :socket.close(ctx.host)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
  end

  test "L6 · a close inside a frame runs nothing and sinks its rights" do
    Ampd.Bridge.reset()
    {runtime, host} = Ampd.Transport.socketpair(:stream)
    {x, y} = Ampd.Transport.socketpair(:stream)
    {:ok, bridge} = HostBridge.start(runtime)
    ref = Process.monitor(bridge)
    before = beam_fds()
    body = JSON.encode!(cmd("bind_agent_channel", %{"actor" => "t28-cut"}))
    # A whole, valid bind, announced 50 bytes longer than it is: a loop that ran what it had would bind the channel.
    :ok = :socket.sendmsg(host, %{iov: [<<byte_size(body) + 50::big-32>> <> body], ctrl: rights([y])})
    Process.sleep(100)
    :ok = :socket.close(host)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
    refute "t28-cut" in actors(), "a truncated frame ran"
    assert beam_fds() <= before, "a truncated frame left #{beam_fds() - before} descriptors open"
    Enum.each([runtime, x, y], &:socket.close/1)
  end

  # ---- L7

  test "L7 · exactly 8,192 bytes to the runtime is a command", ctx do
    :ok = :socket.send(ctx.host, frame(padded(cmd("runtime_status"), 8_192)))
    assert reply(ctx.host)["ok"] == true
  end

  test "L7 · 8,193 bytes announced is refused before its body is read, and the bridge ends", ctx do
    ref = Process.monitor(ctx.bridge)
    :ok = :socket.send(ctx.host, <<8_193::32>>)
    r = reply(ctx.host)
    assert r["refusal"]["code"] == "frame-too-large", inspect(r)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
  end
end
