defmodule Ampd.T27bReplyGoldenTest do
  @moduledoc """
  T27b B8 on the runtime's side (Codex review 2, finding 4): every normal reply the bridge loop sends is, byte for
  byte, the base's.

  The same file runs in two trees. In a throwaway clone of the installed base, with `T27B_REPLY_GOLDEN_OUT` set, it
  CAPTURES each reply's raw bytes into that file (`superlane/t27b/golden-base-r5.sh`). In T27b it COMPARES against the
  committed capture, `test/data/t27b-reply-goldens.json`.

  The commands are every request shape the loop answers (round 4, Codex review 3, finding 2: each `run/3` clause), plus
  the malformed ones, all within the base's limits (T27b changes only commands over 8,192 bytes and replies over
  65,536). The state is controlled: the shapes that would change the world (a registration, a pack, a Carrier binding)
  are sent in their refused forms, which run each clause's own validation and reply encoding without writing anything.
  An empty command is left to B2, whose law it is.

  Run-to-run values (round 4, Codex review 3, finding 3): each named field must have its declared type, and only its
  own value's bytes are replaced, where it stands in the raw reply, by `"<field>"`. Every other byte is compared as
  sent, and a value of the wrong type fails the law instead of normalizing to the same golden.

  Round 5 (Codex review 4):
  - **Every successful reply form** has its own test and golden (`t27b-reply-goldens-success.json`, finding 1): a world
    this file resets and builds, as `development_attempt_test.exs` does, then every clause that can succeed.
  - **Each test declares only the fields measured to vary between runs** (finding 2). No type admits null, and every
    declared field must occur in that test's capture, so no rule is dormant.
  """
  use ExUnit.Case, async: false
  alias Ampd.Transport.HostBridge

  @golden Path.join(__DIR__, "data/t27b-reply-goldens.json")
  # The fields that vary between runs, per test (round 5: two runs diffed field by field; every other field is the same
  # in every run and is compared as sent): field => the type its value must have. No type admits null.
  # `frame_revision` is not a key: a projection frame's cursor (`revision`, `view_revision`) counts every ordered
  # operation since the runtime started, so it depends on what ran before. In the sorted encoding the frame's own
  # `revision` is the one immediately before `view_revision`; a content `revision` with a key between (a task's, before
  # `task_ref`) is not the cursor and is compared as sent.
  @refusal_volatile %{
    "correlation_id" => :string,
    "peer" => :string,
    "opened_at" => :iso8601,
    "endpoint_ref" => :string
  }
  @success_volatile %{
    "world_incarnation" => {:hex, 32},
    "projection_epoch" => {:hex, 8},
    "runtime_epoch" => {:hex, 8},
    "installation_id" => :installation,
    "token" => {:hex, 48},
    "checked_at" => :iso8601,
    "started_at" => :iso8601,
    "finished_at" => :iso8601,
    "at" => :iso8601,
    "expires_at" => :integer,
    "world" => :world,
    "view_revision" => :integer,
    "frame_revision" => :integer
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
  # only. The number of replacements must equal the number of decoded occurrences, so a value the declared form cannot
  # match (an object, a null, a list of another shape) fails here too.
  defp normalized(table, shape, bytes) do
    case JSON.decode(bytes) do
      {:ok, v} ->
        found = collect(table, v)

        for {k, x} <- found do
          assert typed?(table[k], x), "#{shape}: #{k} is #{inspect(x)}, not #{inspect(table[k])}"
        end

        Enum.reduce(Map.keys(table), bytes, fn k, acc ->
          want = Enum.count(found, fn {f, _} -> f == k end)
          {re, to} = form(k, table[k])
          got = length(Regex.scan(re, acc))
          assert got == want, "#{shape}: #{k} occurs #{want} times as a field, #{got} in its declared form"
          Regex.replace(re, acc, to)
        end)

      _ ->
        bytes
    end
  end

  # A scalar's raw value becomes "<field>"; `null` is never matched. A `world` list keeps its generation as sent: only
  # its incarnation and epoch become placeholders.
  defp form("world", :world) do
    {~r/"world":\["[0-9a-f]{32}",(\d+)(,"[0-9a-f]{8}")?\]/,
     fn _, gen, epoch ->
       ~s("world":["<world_incarnation>",#{gen}) <> if(epoch == "", do: "", else: ~s(,"<projection_epoch>")) <> "]"
     end}
  end

  defp form("frame_revision", _), do: {~r/"revision":(-?\d+)(?=,"view_revision":)/, ~s("revision":"<frame_revision>")}

  defp form(k, _), do: {~r/"#{k}":("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false)/, ~s("#{k}":"<#{k}>")}

  defp collect(t, %{} = m) do
    own = Enum.flat_map(m, fn {k, v} -> if Map.has_key?(t, k), do: [{k, v}], else: collect(t, v) end)
    if Map.has_key?(t, "frame_revision") and frame_cursor?(m), do: [{"frame_revision", m["revision"]} | own], else: own
  end

  # A frame whose own revision is its cursor: it carries both, with no key sorting between them.
  defp frame_cursor?(m),
    do: Map.has_key?(m, "revision") and Map.has_key?(m, "view_revision") and
          not Enum.any?(Map.keys(m), &(&1 > "revision" and &1 < "view_revision"))

  defp collect(t, l) when is_list(l), do: Enum.flat_map(l, &collect(t, &1))
  defp collect(_, _), do: []

  defp typed?(:string, x), do: is_binary(x)
  defp typed?(:integer, x), do: is_integer(x)
  defp typed?(:iso8601, x), do: is_binary(x) and match?({:ok, _, _}, DateTime.from_iso8601(x))
  defp typed?({:hex, n}, x), do: is_binary(x) and byte_size(x) == n and x =~ ~r/^[0-9a-f]+$/
  defp typed?(:installation, x), do: is_binary(x) and x =~ ~r/^w-[0-9a-f]{16}$/
  defp typed?(:world, [i, g]), do: typed?({:hex, 32}, i) and is_integer(g)
  defp typed?(:world, [i, g, e]), do: typed?({:hex, 32}, i) and is_integer(g) and typed?({:hex, 8}, e)
  defp typed?(:world, _), do: false

  # No rule is dormant (round 5): every declared run-to-run field occurs in this test's capture.
  defp assert_every_field_seen(table, replies) do
    seen = for r <- replies, {:ok, v} <- [JSON.decode(r)], {k, _} <- collect(table, v), into: MapSet.new(), do: k
    missing = MapSet.difference(MapSet.new(Map.keys(table)), seen) |> Enum.sort()
    assert missing == [], "declared run-to-run fields that never occur: #{inspect(missing)}"
  end

  test "B8 · every normal reply the loop sends is byte for byte the base's", ctx do
    {pairs, held} =
      Enum.map_reduce(shapes(), [], fn {name, bytes, n}, held ->
        {reply, ends} = exchange(ctx.host, bytes, n)
        {{%{"shape" => name, "reply" => normalized(@refusal_volatile, name, reply)}, reply}, ends ++ held}
      end)

    got = Enum.map(pairs, &elem(&1, 0))
    assert_every_field_seen(@refusal_volatile, Enum.map(pairs, &elem(&1, 1)))

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

  # ---- T27b round 5 (Codex review 4, finding 1): the SUCCESSFUL reply of every clause that can succeed, in a world
  # this test resets and builds (as development_attempt_test.exs does): a workspace, a goal, a bot, a registered
  # repository, a lane, a task and a recorded attempt. Captured from the base like the refusals, into its own golden.

  @golden_success Path.join(__DIR__, "data/t27b-reply-goldens-success.json")

  defp hash(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)

  # Fixed names, so the paths in the replies are the same in every tree that runs this (the base capture included).
  defp git_repo!(name) do
    repo = Path.join(System.tmp_dir!(), "t27b-golden-" <> name)
    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "--quiet", repo])
    repo
  end

  defp world_now, do: Enum.map(~w(world_incarnation world_generation projection_epoch), &Ampd.Projection.continuity()[&1])

  defp attempt_fixture! do
    alias Ampd.{Authority, Control}
    Ampd.reset()
    {human, _agent} = Ampd.attach_pair("t27b-golden")
    %{"workspace" => ws} = Control.command(human, :open_workspace, ["Super"])
    %{"goal" => goal} = Control.command(human, :open_goal, [ws["id"], "T27b golden"])

    bot =
      Authority.register_bot(%{
        "client_ref" => "t27b-golden",
        "workspace_ref" => ws["id"],
        "name" => "Golden",
        "role" => "Developer",
        "group" => "Super",
        "instructions" => "T27b golden",
        "provider" => "ollama"
      })

    repo = git_repo!("lane")
    {:ok, registered} = Authority.register_repository(repo)
    %{"lane" => lane} = Control.command(human, :open_lane, [goal["id"], bot["actor"], registered["ref"], "HEAD"])

    task =
      Authority.create_development_task(%{
        "client_ref" => "t27b-golden-task",
        "lane_ref" => lane["id"],
        "title" => "T27b golden",
        "criteria" => "The bridge replies are the base's."
      })

    draft = "before\r\n"
    proposed = "after\n"
    head = String.duplicate("a", 40)

    source = %{
      "schema" => "selected-file-basis@1",
      "scope" => "selected-file-only",
      "basis_id" => hash(JSON.encode!(["selected-file-basis@1", head, "index.html", hash(draft), hash(draft)])),
      "head" => head,
      "path" => "index.html",
      "disk_sha256" => hash(draft),
      "draft_sha256" => hash(draft),
      "draft_bytes" => byte_size(draft),
      "unsaved" => false,
      "result_sha256" => hash(proposed),
      "result_bytes" => byte_size(proposed),
      "task_ref" => task["id"],
      "task_revision" => 1,
      "repository_ref" => task["repository_ref"],
      "world" => world_now()
    }

    a =
      Authority.record_development_attempt(%{
        "client_ref" => "t27b-golden-attempt",
        "task_ref" => task["id"],
        "task_revision" => 1,
        "source" => source,
        "shared_draft" => draft,
        "proposed_text" => proposed
      })

    {a, task, repo}
  end

  defp success_shapes(a, task, repo, extra_repo) do
    start = %{"run_id" => "t27b-run", "revision" => a["revision"], "path" => repo, "world" => a["source"]["world"]}

    outcome = %{
      "state" => "completed",
      "verdict" => "pass",
      "reason" => nil,
      "source_basis_id" => a["source"]["basis_id"],
      "result_sha256" => a["source"]["result_sha256"],
      "snapshot_sha256" => hash("snapshot"),
      "node_sha256" => hash("node"),
      "test_count" => 1,
      "output" => "one test passed",
      "output_omitted" => false
    }

    carrier = %{
      "schema" => "effect-channel@1",
      "channel_epoch" => "t27b-golden-carrier-epoch",
      "protocol" => Ampd.Carrier.Machine.Channel.protocol(),
      "protocol_version" => Ampd.Carrier.Machine.Channel.protocol_version(),
      "host_identity" => %{"t27b" => "golden"},
      "carrier_basis" => %{
        "schema" => "carrier-execution-basis@1",
        "payload_digest" => hash("t27b-golden-payload"),
        "carrier_protocol" => Ampd.Carrier.Machine.Channel.protocol(),
        "carrier_protocol_version" => Ampd.Carrier.Machine.Channel.protocol_version()
      }
    }

    accept = Map.merge(Map.drop(start, ["run_id"]), %{"run_id" => "t27b-run", "snapshot_sha256" => hash("snapshot"),
      "result_sha256" => a["source"]["result_sha256"], "head" => a["source"]["head"]})

    [
      {"register_repository, a git repository", fn _ -> cmd(%{"command" => "register_repository", "path" => extra_repo}) end, 0},
      {"registered_repository, that repository", fn prev -> cmd(%{"command" => "registered_repository", "repository_ref" => prev["repository"]["ref"]}) end, 0},
      {"install_pack, worktree", fn _ -> cmd(%{"command" => "install_pack", "pack" => "worktree"}) end, 0},
      {"bind_carrier_channel, a well-formed incarnation and basis", fn _ -> cmd(%{"command" => "bind_carrier_channel", "incarnation" => carrier}) end, 1},
      {"begin_development_test, the current world", fn _ -> cmd(%{"command" => "begin_development_test", "attempt_ref" => a["id"], "fields" => start}) end, 0},
      {"finish_development_test, a pass", fn _ -> cmd(%{"command" => "finish_development_test", "attempt_ref" => a["id"], "run_id" => "t27b-run", "world" => start["world"], "outcome" => outcome}) end, 0},
      {"recover_development_tests, the current world", fn _ -> cmd(%{"command" => "recover_development_tests", "attempt_ref" => a["id"], "world" => start["world"]}) end, 0},
      {"prepare_development_acceptance, the passing run", fn _ -> cmd(%{"command" => "prepare_development_acceptance", "attempt_ref" => a["id"], "fields" => accept}) end, 0},
      {"resolve_development_test, the attempt", fn _ -> cmd(%{"command" => "resolve_development_test", "attempt_ref" => a["id"], "revision" => a["revision"], "path" => repo, "world" => start["world"]}) end, 0},
      {"match_development_repository, the task", fn _ -> cmd(%{"command" => "match_development_repository", "task_ref" => task["id"], "revision" => task["revision"], "path" => repo, "world" => start["world"]}) end, 0}
    ]
  end

  test "B8 · every successful reply form the loop sends is byte for byte the base's", ctx do
    {a, task, repo} = attempt_fixture!()
    extra = git_repo!("extra")

    {pairs, {held, _}} =
      Enum.map_reduce(success_shapes(a, task, repo, extra), {[], %{}}, fn {name, make, n}, {held, prev} ->
        {reply, ends} = exchange(ctx.host, make.(prev), n)

        decoded =
          case JSON.decode(reply) do
            {:ok, v} -> v
            _ -> %{}
          end

        {{%{"shape" => name, "reply" => normalized(@success_volatile, name, reply)}, reply}, {ends ++ held, decoded}}
      end)

    got = Enum.map(pairs, &elem(&1, 0))
    assert_every_field_seen(@success_volatile, Enum.map(pairs, &elem(&1, 1)))

    Ampd.Bridge.reset()
    Enum.each(held, &:socket.close/1)
    File.rm_rf!(repo)
    File.rm_rf!(extra)

    case System.get_env("T27B_REPLY_GOLDEN_SUCCESS_OUT") do
      nil ->
        want = @golden_success |> File.read!() |> JSON.decode!()
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
