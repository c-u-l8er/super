defmodule Ampd.T28HostBridgeFramedTest do
  @moduledoc """
  T28's laws on the runtime's side of the FRAMED bridge (`superlane/t28/TASK.md`), on a stream pair, as the bridge is on
  macOS and on Linux under the host's test feature: `HostBridge.start/1` reads a stream bridge with `framed_loop/2`.

    * L1 — frames several to a write are answered in that sequence; a zero-length frame is one frame, answered once;
      a reply is a big-endian u32 length and its body;
    * L2 — frames A (no rights), B (one) and C (two), written before the loop runs, each bind exactly their own rights;
      rights on a later byte than a frame's first are refused with that frame, and the next frame is unaffected;
    * L3 — after 100 frames of 0 to 16 rights, with refusals and violations, the runtime's descriptors are back at
      their baseline; an over-limit frame's rights are sunk;
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

  defp beam_fds, do: length(File.ls!("/proc/self/fd"))
  defp actors, do: Ampd.Bridge.list() |> Enum.map(&(&1["actor"] || &1[:actor]))

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
    stop(bridge, [host, runtime, b1x, b1y, c1x, c1y, c2x, c2y])
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
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
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
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
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
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
  end
end
