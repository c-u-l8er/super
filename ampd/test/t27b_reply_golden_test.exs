defmodule Ampd.T27bReplyGoldenTest do
  @moduledoc """
  T27b B8 on the runtime's side (Codex review 2, finding 4): every normal reply the bridge loop sends is, byte for
  byte, the base's.

  The same file runs in two trees. In a throwaway clone of the installed base, with `T27B_REPLY_GOLDEN_OUT` set, it
  CAPTURES each reply's raw bytes into that file (`superlane/t27b/golden-base-r3.sh`). In T27b it COMPARES against the
  committed capture, `test/data/t27b-reply-goldens.json`.

  The commands are the existing request shapes a host sends, plus the malformed ones the loop answers, all within the
  base's limits (T27b changes only commands over 8,192 bytes and replies over 65,536). An empty command is left to B2,
  whose law it is. Run-to-run values are replaced
  by placeholders IN THE RAW BYTES (`correlation_id`, `peer`, `opened_at`, `endpoint_ref`), so every other byte is
  compared as sent.
  """
  use ExUnit.Case, async: false
  alias Ampd.Transport.HostBridge

  @golden Path.join(__DIR__, "data/t27b-reply-goldens.json")
  @run_to_run ~w(correlation_id peer opened_at endpoint_ref)

  setup do
    Ampd.Bridge.reset()
    {runtime, host} = Ampd.Transport.socketpair(:seqpacket)
    {:ok, bridge} = HostBridge.start(runtime)

    on_exit(fn ->
      HostBridge.stop(bridge)
      :socket.close(host)
      :socket.close(runtime)
    end)

    %{host: host}
  end

  defp cmd(map), do: JSON.encode!(Map.put(map, "schema", "bridge-command@1"))

  # `{name, bytes, rights}`: rights is how many fresh stream-pair ends go with the command (their far ends are kept).
  defp shapes do
    inc = %{
      "schema" => "effect-channel@1",
      "channel_epoch" => "t27b-golden-epoch",
      "protocol" => "worktree-effect",
      "protocol_version" => 1,
      "host_identity" => %{"t27b" => "golden"}
    }

    [
      {"list_channels, empty", cmd(%{"command" => "list_channels"}), 0},
      {"bind_agent_channel", cmd(%{"command" => "bind_agent_channel", "actor" => "t27b-golden"}), 1},
      {"bind_agent_channel, actor over 128 bytes", cmd(%{"command" => "bind_agent_channel", "actor" => String.duplicate("a", 129)}), 1},
      {"bind_agent_channel, no rights", cmd(%{"command" => "bind_agent_channel", "actor" => "t27b-golden"}), 0},
      {"bind_agent_channel, two surplus rights", cmd(%{"command" => "bind_agent_channel", "actor" => "t27b-golden-2"}), 3},
      {"bind_control_channel", cmd(%{"command" => "bind_control_channel"}), 1},
      {"bind_control_channel, taken", cmd(%{"command" => "bind_control_channel"}), 1},
      {"list_channels, three", cmd(%{"command" => "list_channels"}), 0},
      {"bind_effect_channel", cmd(%{"command" => "bind_effect_channel", "incarnation" => inc}), 1},
      {"bind_terminal_endpoint", cmd(%{"command" => "bind_terminal_endpoint"}), 1},
      {"unknown command", cmd(%{"command" => "t27b-unknown"}), 0},
      {"unknown command with rights", cmd(%{"command" => "t27b-unknown"}), 2},
      {"no schema", JSON.encode!(%{"command" => "list_channels"}), 0},
      {"not JSON", "t27b: not json", 0}
    ]
  end

  defp exchange(host, bytes, n) do
    pairs = for _ <- 1..n//1, do: Ampd.Transport.socketpair(:stream)
    ctrl =
      for {mine, _} <- pairs do
        {:ok, fd} = :socket.getopt(mine, {:otp, :fd})
        %{level: :socket, type: :rights, data: <<fd::native-32>>}
      end

    :ok = :socket.sendmsg(host, %{iov: [bytes], ctrl: ctrl})
    Enum.each(pairs, fn {mine, _} -> :socket.close(mine) end)
    {:ok, %{iov: iov}} = :socket.recvmsg(host, 65_536, 0, [], 5_000)
    {IO.iodata_to_binary(iov), Enum.map(pairs, &elem(&1, 1))}
  end

  # Each run-to-run value, wherever it appears, replaced in the raw bytes by "<key>".
  defp normalized(bytes) do
    values =
      case JSON.decode(bytes) do
        {:ok, v} -> collect(v)
        _ -> []
      end

    Enum.reduce(values, bytes, fn {k, v}, acc -> String.replace(acc, JSON.encode!(v), ~s("<#{k}>")) end)
  end

  defp collect(%{} = m), do: Enum.flat_map(m, fn {k, v} -> if k in @run_to_run, do: [{k, v}], else: collect(v) end)
  defp collect(l) when is_list(l), do: Enum.flat_map(l, &collect/1)
  defp collect(_), do: []

  test "B8 · every normal reply the loop sends is byte for byte the base's", ctx do
    {got, held} =
      Enum.map_reduce(shapes(), [], fn {name, bytes, n}, held ->
        {reply, theirs} = exchange(ctx.host, bytes, n)
        {%{"shape" => name, "reply" => normalized(reply)}, theirs ++ held}
      end)

    Enum.each(held, &:socket.close/1)

    case System.get_env("T27B_REPLY_GOLDEN_OUT") do
      nil ->
        want = @golden |> File.read!() |> JSON.decode!()
        assert length(want) == length(got)

        for {w, g} <- Enum.zip(want, got) do
          assert w["shape"] == g["shape"]
          assert g["reply"] == w["reply"], "#{g["shape"]}: the reply differs from the base's"
        end

      out ->
        File.write!(out, JSON.encode!(got))
    end
  end
end
