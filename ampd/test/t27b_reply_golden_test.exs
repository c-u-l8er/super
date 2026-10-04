defmodule Ampd.T27bReplyGoldenTest do
  @moduledoc """
  T27b B8 on the runtime's side (Codex review 2, finding 4): every normal reply the bridge loop sends is, byte for
  byte, the base's.

  The same file runs in two trees. In a throwaway clone of the installed base, with `T27B_REPLY_GOLDEN_OUT` set, it
  CAPTURES each reply's raw bytes into that file (`superlane/t27b/golden-base-r4.sh`). In T27b it COMPARES against the
  committed capture, `test/data/t27b-reply-goldens.json`.

  The commands are every request shape the loop answers (round 4, Codex review 3, finding 2: each `run/3` clause), plus
  the malformed ones, all within the base's limits (T27b changes only commands over 8,192 bytes and replies over
  65,536). The state is controlled: the shapes that would change the world (a registration, a pack, a Carrier binding)
  are sent in their refused forms, which run each clause's own validation and reply encoding without writing anything.
  An empty command is left to B2, whose law it is.

  Run-to-run values (round 4, Codex review 3, finding 3): each named field must have its declared type, and only its
  own value's bytes are replaced, where it stands in the raw reply, by `"<field>"`. Every other byte is compared as
  sent, and a value of the wrong type fails the law instead of normalizing to the same golden.
  """
  use ExUnit.Case, async: false
  alias Ampd.Transport.HostBridge

  @golden Path.join(__DIR__, "data/t27b-reply-goldens.json")
  # field => the type its value must have
  @run_to_run %{
    "correlation_id" => :string,
    "peer" => :string,
    "opened_at" => :iso8601,
    "endpoint_ref" => :string,
    "world_incarnation" => :string_or_null,
    "world_generation" => :integer_or_null,
    "projection_epoch" => :string_or_null,
    "revision" => :integer,
    "view_revision" => :integer
  }

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

    carrier = %{inc | "protocol" => Ampd.Carrier.Machine.Channel.protocol()}
    stale = ["t27b-not-this-world", 0, "t27b-not-this-epoch"]
    dev = %{"attempt_ref" => "da_t27b_golden", "fields" => %{"world" => stale, "run_id" => "t27b-run"}}

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
      {"not JSON", "t27b: not json", 0},
      # ---- round 4 (Codex review 3, finding 2): every other clause of run/3
      {"runtime_status", cmd(%{"command" => "runtime_status"}), 0},
      {"bind_carrier_channel, not an incarnation", cmd(%{"command" => "bind_carrier_channel", "incarnation" => %{inc | "schema" => "t27b"}}), 1},
      {"bind_carrier_channel, short epoch", cmd(%{"command" => "bind_carrier_channel", "incarnation" => %{carrier | "channel_epoch" => "short"}}), 1},
      {"bind_carrier_channel, unknown protocol", cmd(%{"command" => "bind_carrier_channel", "incarnation" => inc}), 1},
      {"bind_carrier_channel, no execution basis", cmd(%{"command" => "bind_carrier_channel", "incarnation" => carrier}), 1},
      {"register_repository, empty path", cmd(%{"command" => "register_repository", "path" => ""}), 0},
      {"register_repository, not a repository", cmd(%{"command" => "register_repository", "path" => "/nonexistent/t27b-golden"}), 0},
      {"register_repository, path not a string", cmd(%{"command" => "register_repository", "path" => 7}), 0},
      {"registered_repository, unknown", cmd(%{"command" => "registered_repository", "repository_ref" => "rp_999999"}), 0},
      {"registered_repository, malformed", cmd(%{"command" => "registered_repository", "repository_ref" => "t27b"}), 0},
      {"install_pack, unknown", cmd(%{"command" => "install_pack", "pack" => "t27b"}), 0},
      {"prepare_development_acceptance, another world", cmd(Map.put(dev, "command", "prepare_development_acceptance")), 0},
      {"recover_development_tests, another world", cmd(%{"command" => "recover_development_tests", "attempt_ref" => "da_t27b_golden", "world" => stale}), 0},
      {"begin_development_test, another world", cmd(Map.put(dev, "command", "begin_development_test")), 0},
      {"finish_development_test, another world",
       cmd(%{"command" => "finish_development_test", "attempt_ref" => "da_t27b_golden", "run_id" => "t27b-run", "world" => stale, "outcome" => %{}}), 0},
      {"resolve_development_test, unknown attempt",
       cmd(%{"command" => "resolve_development_test", "attempt_ref" => "da_t27b_golden", "revision" => 1, "path" => "/nonexistent/t27b-golden", "world" => stale}), 0},
      {"match_development_repository, unknown task",
       cmd(%{"command" => "match_development_repository", "task_ref" => "dt_t27b_golden", "revision" => 1, "path" => "/nonexistent/t27b-golden", "world" => stale}), 0}
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
    # Both ends stay open (round 3g): :socket.close makes a socket's open file description blocking, and the runtime's
    # adopted copy shares it, so closing `mine` here would leave the runtime's reader blocking a scheduler.
    {:ok, %{iov: iov}} = :socket.recvmsg(host, 65_536, 0, [], 5_000)
    {IO.iodata_to_binary(iov), Enum.flat_map(pairs, fn {mine, theirs} -> [mine, theirs] end)}
  end

  # Each run-to-run field's value, checked against its declared type, then replaced IN THE RAW BYTES at that field
  # only: `"field":<value>` becomes `"field":"<field>"`. The number of replacements must equal the number of decoded
  # occurrences, so a value the scalar pattern cannot match (an object, a list) fails here too.
  defp normalized(shape, bytes) do
    case JSON.decode(bytes) do
      {:ok, v} ->
        found = collect(v)

        for {k, x} <- found do
          assert typed?(@run_to_run[k], x), "#{shape}: #{k} is #{inspect(x)}, not #{@run_to_run[k]}"
        end

        Enum.reduce(Map.keys(@run_to_run), bytes, fn k, acc ->
          want = Enum.count(found, fn {f, _} -> f == k end)
          re = ~r/"#{k}":("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|null|true|false)/
          got = length(Regex.scan(re, acc))
          assert got == want, "#{shape}: #{k} occurs #{want} times as a field, #{got} as a scalar"
          Regex.replace(re, acc, ~s("#{k}":"<#{k}>"))
        end)

      _ ->
        bytes
    end
  end

  defp collect(%{} = m),
    do: Enum.flat_map(m, fn {k, v} -> if Map.has_key?(@run_to_run, k), do: [{k, v}], else: collect(v) end)

  defp collect(l) when is_list(l), do: Enum.flat_map(l, &collect/1)
  defp collect(_), do: []

  defp typed?(:string, x), do: is_binary(x)
  defp typed?(:integer, x), do: is_integer(x)
  defp typed?(:string_or_null, x), do: is_nil(x) or is_binary(x)
  defp typed?(:integer_or_null, x), do: is_nil(x) or is_integer(x)
  defp typed?(:iso8601, x), do: is_binary(x) and match?({:ok, _, _}, DateTime.from_iso8601(x))

  test "B8 · every normal reply the loop sends is byte for byte the base's", ctx do
    {got, held} =
      Enum.map_reduce(shapes(), [], fn {name, bytes, n}, held ->
        {reply, ends} = exchange(ctx.host, bytes, n)
        {%{"shape" => name, "reply" => normalized(name, reply)}, ends ++ held}
      end)

    # The runtime releases what it adopted first; only then are the test's ends closed (round 3g).
    Ampd.Bridge.reset()

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
