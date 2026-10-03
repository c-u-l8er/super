defmodule Ampd.T27bHostBridgeTest do
  @moduledoc """
  T27b's laws on the runtime's side of the bridge (`superlane/t27b/TASK.md`):

    * B1 — the host's close ends the loop (it used to spin: ~340,000 answers a second, measured on the base);
    * B2 — an empty command that carries rights is still answered, not taken for the host's close;
    * B3, the runtime's half — exactly 8,192 bytes is a whole command, and it runs;
    * B4 — a command cut in transit is refused as `frame-too-large` and never run, even when its prefix is a whole,
      valid command;
    * B5, the runtime's half — a reply longer than the host reads whole is never sent; exactly 65,536 bytes is;
      and every reply the loop sends goes through `encode_reply` (a source law). Since round 3 (Codex review 2,
      finding 3) also on the loop's real path: `list_channels` answers with the whole registry, so real adopted
      channels make its reply exactly 65,536 bytes, received whole, and then one channel more, received as a named
      `reply-too-large` refusal.
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
      # Killed, not asked (T27b round 3f): HostBridge.stop sends :normal, which a running loop that does not trap
      # exits ignores. A build whose loop never ends on the host's close (B1's plant) must not leave a live loop beside
      # the sockets being closed; a law run hung there.
      ref = Process.monitor(bridge)
      Process.exit(bridge, :kill)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        2_000 -> :ok
      end

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
  # T27b round 3 (Codex review 2, finding 3): B5 through the loop's real sending path.
  #
  # The registry is filled with `Ampd.Bridge.adopt_channel/3` directly, not through `bind_agent_channel`, because the
  # bridge bounds an actor at 128 bytes and these are longer. That is setup only: the reply under test is the one the
  # HostBridge loop builds and sends for a real `list_channels` command.
  #
  # The reply to `list_channels` is `ok(%{"channels" => Ampd.Bridge.list()})`, so its exact length is computed here
  # from the registry the loop will read, and real adopted channels (stream pairs whose far ends this test holds)
  # grow it. The last channel's actor is sized so the reply is exactly 65,536 bytes; if the computed size misses,
  # that channel is released and the size retried.
  defp listed_bytes do
    byte_size(JSON.encode!(Map.merge(%{"schema" => "bridge-reply@1", "ok" => true}, %{"channels" => Ampd.Bridge.list()})))
  end

  defp adopt_agent(actor) do
    {mine, theirs} = Ampd.Transport.socketpair(:stream)
    {:ok, _pid, peer} = Ampd.Bridge.adopt_channel(mine, :agent, actor)
    {theirs, peer}
  end

  defp release_agent({theirs, peer}) do
    :socket.close(theirs)
    wait = fn wait, n ->
      cond do
        not Enum.any?(Ampd.Bridge.list(), &(&1["peer"] == peer)) -> :ok
        n == 0 -> flunk("channel #{peer} was never released")
        true -> Process.sleep(10); wait.(wait, n - 1)
      end
    end
    wait.(wait, 500)
  end

  defp list_over_the_bridge(host) do
    :ok = :socket.send(host, JSON.encode!(%{"schema" => "bridge-command@1", "command" => "list_channels"}))
    {:ok, %{iov: iov, flags: flags}} = :socket.recvmsg(host, 65_536, 0, [], 5_000)
    {IO.iodata_to_binary(iov), flags}
  end

  test "B5 · through the loop: a 65,536-byte list_channels reply arrives whole; one channel more is refused by name", ctx do
    held = for i <- 1..80, listed_bytes() < 65_536 - 3_000, do: adopt_agent("t27b-b5-#{i}-" <> String.duplicate("a", 900))
    assert listed_bytes() < 65_536 - 1_000, "the registry grew past its target: #{listed_bytes()} bytes"

    # The cost of one more channel, apart from its actor's own bytes, measured on one that is then released.
    before = listed_bytes()
    probe = adopt_agent("t27b-b5-probe")
    overhead = listed_bytes() - before - byte_size("t27b-b5-probe")
    release_agent(probe)

    exact =
      Enum.reduce_while(1..5, nil, fn attempt, _ ->
        size = 65_536 - listed_bytes() - overhead
        last = adopt_agent("t27b-b5-last-" <> String.duplicate("z", size - byte_size("t27b-b5-last-")))
        if listed_bytes() == 65_536,
          do: {:halt, last},
          else: (release_agent(last); {:cont, if(attempt == 5, do: flunk("never sized the reply to 65,536 bytes"))})
      end)

    {bytes, flags} = list_over_the_bridge(ctx.host)
    assert byte_size(bytes) == 65_536 and :trunc not in flags, "#{byte_size(bytes)} bytes, flags #{inspect(flags)}"
    whole = JSON.decode!(bytes)
    assert whole["ok"] == true and length(whole["channels"]) == length(held) + 1

    over = adopt_agent("t27b-b5-over")
    want = listed_bytes()
    assert want > 65_536
    {bytes, flags} = list_over_the_bridge(ctx.host)
    assert :trunc not in flags, "a reply longer than the host reads whole was sent: it arrived cut"
    refused = JSON.decode!(bytes)
    assert refused["ok"] == false and refused["refusal"]["code"] == "reply-too-large"
    assert refused["refusal"]["operator_detail"]["reply_bytes"] == want

    Enum.each([over, exact | held], fn {theirs, _} -> :socket.close(theirs) end)
  end
end
