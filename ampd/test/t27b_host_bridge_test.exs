defmodule Ampd.T27bHostBridgeTest do
  @moduledoc """
  T27b's laws on the runtime's side of the bridge (`superlane/t27b/TASK.md`):

    * B1 — the host's close ends the loop (it used to spin: ~340,000 answers a second, measured on the base);
    * B2 — an empty command that carries rights is still answered, not taken for the host's close;
    * B3, the runtime's half — exactly 8,192 bytes is a whole command, and it runs;
    * B4 — a command cut in transit is refused as `frame-too-large` and never run, even when its prefix is a whole,
      valid command;
    * B5, the runtime's half — a reply longer than the host reads whole is never sent; exactly 65,536 bytes is;
      and every reply the loop sends goes through `encode_reply` (a source law: no bridge command can produce a
      reply that long in a test, so the loop's path is held to the encoder by name).
  B2 and B4 also count the runtime's descriptors over 50 sends: rights that arrive are sunk, never kept.

  On a SEQPACKET pair, as the host's bridge is (the other bridge tests use a stream pair).
  """
  use ExUnit.Case, async: false
  alias Ampd.Transport.HostBridge

  setup do
    Ampd.Bridge.reset()
    {runtime, host} = Ampd.Transport.socketpair(:seqpacket)
    {:ok, bridge} = HostBridge.start(runtime)

    on_exit(fn ->
      HostBridge.stop(bridge)
      :socket.close(host)
      :socket.close(runtime)
    end)

    %{host: host, bridge: bridge}
  end

  # A command whose JSON is exactly `size` bytes: `map` plus a "pad" string of spaces.
  defp padded(map, size) do
    base = byte_size(JSON.encode!(Map.put(map, "pad", "")))
    bytes = JSON.encode!(Map.put(map, "pad", String.duplicate(" ", size - base)))
    ^size = byte_size(bytes)
    bytes
  end

  defp reply(host), do: host |> :socket.recv(0, 3_000) |> then(fn {:ok, b} -> JSON.decode!(b) end)

  defp rights(sock) do
    {:ok, fd} = :socket.getopt(sock, {:otp, :fd})
    [%{level: :socket, type: :rights, data: <<fd::native-32>>}]
  end

  defp beam_fds, do: length(File.ls!("/proc/self/fd"))

  defp channels(host) do
    :ok = :socket.send(host, JSON.encode!(%{"schema" => "bridge-command@1", "command" => "list_channels"}))
    length(reply(host)["channels"])
  end

  test "B1 · the host's close ends the loop within a second", ctx do
    ref = Process.monitor(ctx.bridge)
    :ok = :socket.close(ctx.host)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
  end

  test "B2 · an empty command carrying rights is answered, not taken for the host's close", ctx do
    {x, y} = Ampd.Transport.socketpair(:stream)
    :ok = :socket.sendmsg(ctx.host, %{iov: [""], ctrl: rights(x)})
    r = reply(ctx.host)
    assert r["ok"] == false and r["refusal"]["code"] == "unknown-bridge-command"
    assert Process.alive?(ctx.bridge)
    :socket.close(x)
    :socket.close(y)
  end

  test "B2 · the rights of an empty command are sunk, never kept", ctx do
    {x, y} = Ampd.Transport.socketpair(:stream)
    before = beam_fds()

    for _ <- 1..50 do
      :ok = :socket.sendmsg(ctx.host, %{iov: [""], ctrl: rights(x)})
      assert reply(ctx.host)["refusal"]["code"] == "unknown-bridge-command"
    end

    assert beam_fds() <= before + 20, "50 empty commands left #{beam_fds() - before} descriptors open"
    :socket.close(x)
    :socket.close(y)
  end

  test "B3 · exactly 8,192 bytes is a whole command, and it runs", ctx do
    :ok = :socket.send(ctx.host, padded(%{"schema" => "bridge-command@1", "command" => "list_channels"}, 8_192))
    assert reply(ctx.host)["ok"] == true
  end

  test "B4 · a command cut in transit is refused as frame-too-large and never run", ctx do
    # Its first 8,192 bytes are a whole, valid bind: a runtime that read the prefix would bind the channel.
    {x, y} = Ampd.Transport.socketpair(:stream)
    before = channels(ctx.host)
    whole = padded(%{"schema" => "bridge-command@1", "command" => "bind_agent_channel", "actor" => "t27b-b4"}, 8_192)
    :ok = :socket.sendmsg(ctx.host, %{iov: [whole <> String.duplicate(" ", 64)], ctrl: rights(y)})
    r = reply(ctx.host)
    assert r["ok"] == false and r["refusal"]["code"] == "frame-too-large"
    assert r["refusal"]["operator_detail"]["limit_bytes"] == 8_192
    assert channels(ctx.host) == before, "the cut command bound a channel"
    :socket.close(x)
    :socket.close(y)
  end

  test "B4 · the rights of a cut command are sunk, never kept", ctx do
    {x, y} = Ampd.Transport.socketpair(:stream)
    cut = :binary.copy("x", 8_300)
    before = beam_fds()

    for _ <- 1..50 do
      :ok = :socket.sendmsg(ctx.host, %{iov: [cut], ctrl: rights(y)})
      assert reply(ctx.host)["refusal"]["code"] == "frame-too-large"
    end

    assert beam_fds() <= before + 20, "50 cut commands left #{beam_fds() - before} descriptors open"
    :socket.close(x)
    :socket.close(y)
  end

  test "B5 · every reply the loop sends goes through encode_reply" do
    src = File.read!(Path.join(__DIR__, "../lib/ampd/transport.ex"))
    [_, bridge] = String.split(src, "defmodule HostBridge do", parts: 2)
    all = length(Regex.scan(~r/:socket\.send\(/, bridge))
    via = length(Regex.scan(~r/:socket\.send\(sock, encode_reply\(/, bridge))
    assert via >= 2 and all == via, "#{all - via} of #{all} bridge sends bypass encode_reply"
  end

  test "B5 · a reply longer than the host reads whole is never sent; exactly 65,536 bytes is" do
    sized = fn n ->
      base = byte_size(JSON.encode!(%{"schema" => "bridge-reply@1", "ok" => true, "pad" => ""}))
      %{"schema" => "bridge-reply@1", "ok" => true, "pad" => String.duplicate("x", n - base)}
    end

    at = HostBridge.encode_reply(sized.(65_536))
    assert byte_size(at) == 65_536 and JSON.decode!(at)["ok"] == true

    over = JSON.decode!(HostBridge.encode_reply(sized.(65_537)))
    assert over["ok"] == false and over["refusal"]["code"] == "reply-too-large"
    assert over["refusal"]["operator_detail"]["reply_bytes"] == 65_537
  end
end
