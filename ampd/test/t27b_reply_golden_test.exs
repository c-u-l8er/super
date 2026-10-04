defmodule Ampd.T27bReplyGoldenTest do
  @moduledoc """
  T27b B8 on the runtime's side (Codex review 2, finding 4): every normal reply the bridge loop sends is, byte for
  byte, the base's.

  The same file runs in two trees. In a throwaway clone of the installed base, with `T27B_REPLY_GOLDEN_OUT` set, it
  CAPTURES each reply's raw bytes into that file (`superlane/t27b/golden-base-r7.sh`). In T27b it COMPARES against the
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

  Round 6 (Codex review 5): the fixture's repositories are directories this run alone owns, and every resource is
  released on every exit (`release_all!/3`, called from `after`).

  Round 7 (Codex review 6): the teardown's steps are independent and its errors are reported together; each socket is
  recorded the moment it exists; the bridge loop stops before the runtime releases what it adopted; the repository
  replies must carry the owned path. B9's law here injects a failure at each of five points and checks that nothing
  the fixture made survives.
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

    %{host: host, bridge: bridge}
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
    pairs =
      for k <- 1..n//1 do
        if k == 2, do: inject!(:after_first_pair)
        pair!()
      end

    ctrl =
      for {mine, _} <- pairs do
        {:ok, fd} = :socket.getopt(mine, {:otp, :fd})
        %{level: :socket, type: :rights, data: <<fd::native-32>>}
      end

    :ok = :socket.sendmsg(host, %{iov: [bytes], ctrl: ctrl})
    # Both ends stay open (round 3g): :socket.close makes a socket's open file description blocking, and the runtime's
    # adopted copy shares it, so closing `mine` here would leave the runtime's reader blocking a scheduler.
    {:ok, %{iov: iov}} = :socket.recvmsg(host, 65_536, 0, [], if(injected?(:recv_timeout), do: 0, else: 5_000))
    reply = IO.iodata_to_binary(iov)
    raw!(reply)
    reply
  end

  # ---- Round 6 (Codex review 5, finding 2) and round 7 (Codex review 6): what a test makes is recorded the moment it
  # exists, in the test's own process, and released on every exit by `release_all!/3` in its `after`.
  defp held!(socks), do: Process.put(:t27b_held, socks ++ Process.get(:t27b_held, []))
  defp owned!(dir), do: Process.put(:t27b_owned, [dir | Process.get(:t27b_owned, [])])

  # The test's own socket pair (round 7, finding 2): its temporary directory is owned before it is used, and each
  # socket is recorded the moment it exists, so a failure part-way through leaks nothing. The shape is
  # `Ampd.Transport.socketpair(:stream)`'s: an accepted end and a connected end over a path that only this run made.
  defp pair! do
    dir = Path.join(System.tmp_dir!(), "t27b-pair-#{System.pid()}-#{System.unique_integer([:positive])}")
    :ok = File.mkdir(dir)
    owned!(dir)
    path = Path.join(dir, "p.sock")
    {:ok, l} = :socket.open(:local, :stream, :default)
    held!([l])
    :ok = :socket.bind(l, %{family: :local, path: path})
    :ok = :socket.listen(l)
    {:ok, c} = :socket.open(:local, :stream, :default)
    held!([c])
    inject!(:pair_construction)
    me = self()
    spawn(fn -> send(me, {:t27b_connected, c, :socket.connect(c, %{family: :local, path: path})}) end)
    {:ok, a} = :socket.accept(l, 2_000)
    held!([a])

    receive do
      {:t27b_connected, ^c, :ok} -> :ok
    after
      2_000 -> flunk("pair: the connect never landed")
    end

    {a, c}
  end

  # The teardown (rounds 3g, 6 and 7). Each step runs whatever an earlier one did, and every error is reported at the
  # end. The order: the bridge loop stops first, so nothing is adopted after disposal begins; then the runtime releases
  # what it adopted (round 3g: before the test closes its copies); then every recorded test socket closes; then every
  # owned directory goes; then a test that built a world resets it; and only then is any evidence written.
  defp release_all!(bridge, reset_world?, evidence) do
    errors = step([], "stop the bridge loop", fn -> stop_loop!(bridge) end)
    errors = step(errors, "release the runtime's adoptions", fn -> Ampd.Bridge.reset() end)
    held = Process.delete(:t27b_held) || []
    errors = Enum.reduce(held, errors, fn sock, e -> step(e, "close a test socket", fn -> close!(sock) end) end)
    dirs = Process.delete(:t27b_owned) || []
    errors = Enum.reduce(dirs, errors, fn dir, e -> step(e, "remove #{dir}", fn -> remove!(dir) end) end)
    errors = if reset_world?, do: step(errors, "reset the world", fn -> Ampd.reset() end), else: errors
    errors = step(errors, "write the evidence", evidence)

    if log = System.get_env("T27B_GOLDEN_CLEANUP_LOG") do
      left = Enum.filter(dirs, &File.exists?/1)
      line = "released #{length(held)} test sockets; removed #{length(dirs) - length(left)} of #{length(dirs)} owned dirs; " <>
        "world reset #{reset_world?}; errors #{inspect(errors)}\n"
      File.write(log, line, [:append])
    end

    if errors != [], do: flunk("cleanup errors: " <> Enum.join(errors, "; "))
    :ok
  end

  defp step(errors, what, f) do
    f.()
    errors
  rescue
    e -> errors ++ ["#{what}: #{Exception.message(e)}"]
  end

  # Unlinked first: the loop was linked to this test process at setup, and a linked kill would take the test with it.
  defp stop_loop!(bridge) do
    Process.unlink(bridge)
    ref = Process.monitor(bridge)
    Process.exit(bridge, :kill)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      2_000 -> raise "the bridge loop did not stop"
    end
  end

  defp close!(sock) do
    case :socket.close(sock) do
      :ok -> :ok
      {:error, :closed} -> :ok
      other -> raise "close: #{inspect(other)}"
    end
  end

  defp remove!(dir) do
    inject!(:remove)

    case File.rm_rf(dir) do
      {:ok, _} -> :ok
      {:error, reason, file} -> raise "#{file}: #{inspect(reason)}"
    end
  end

  # Verification knobs, inert unless set (rounds 6 and 7): an injected failure fires once per process, at the named
  # point, from `T27B_GOLDEN_INJECT` or from B9's law below (which sets it in its own process).
  defp injected?(point) do
    want = Process.get(:t27b_inject) || System.get_env("T27B_GOLDEN_INJECT")

    if want == Atom.to_string(point) and not Process.get({:t27b_injected, point}, false) do
      Process.put({:t27b_injected, point}, true)
      true
    else
      false
    end
  end

  defp inject!(point), do: if(injected?(point), do: raise("injected failure: #{point}"))

  defp raw_out, do: Process.get(:t27b_raw_out) || System.get_env("T27B_REPLY_RAW_OUT")
  defp raw!(reply), do: if(raw_out(), do: Process.put(:t27b_raw, Process.get(:t27b_raw, []) ++ [reply]))

  defp fail_at!(name),
    do: if(System.get_env("T27B_GOLDEN_FAIL_AT") == name, do: flunk("intentional failure after #{name} (T27B_GOLDEN_FAIL_AT)"))

  defp write_raw!(test) do
    if out = raw_out(), do: File.write!("#{out}.#{test}.json", JSON.encode!(Process.get(:t27b_raw, [])))
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


  defp collect(t, l) when is_list(l), do: Enum.flat_map(l, &collect(t, &1))
  defp collect(_, _), do: []

  # A frame whose own revision is its cursor: it carries both, with no key sorting between them.
  defp frame_cursor?(m),
    do: Map.has_key?(m, "revision") and Map.has_key?(m, "view_revision") and
          not Enum.any?(Map.keys(m), &(&1 > "revision" and &1 < "view_revision"))

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
    pairs =
      try do
        for {name, bytes, n} <- shapes() do
          reply = exchange(ctx.host, bytes, n)
          fail_at!(name)
          {%{"shape" => name, "reply" => normalized(@refusal_volatile, name, reply)}, reply}
        end
      after
        release_all!(ctx.bridge, false, fn -> write_raw!("refusals") end)
      end

    got = Enum.map(pairs, &elem(&1, 0))
    assert_every_field_seen(@refusal_volatile, Enum.map(pairs, &elem(&1, 1)))

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

  # Round 6 (Codex review 5, finding 1): a directory this run alone owns. `File.mkdir` refuses one that already exists,
  # so nothing anyone else made is ever deleted; the name is unique to this OS process and this call. It is recorded as
  # owned before anything is put in it, so `release_all!/1` removes it on every exit.
  defp git_repo!(name) do
    repo = Path.join(System.tmp_dir!(), "t27b-golden-#{name}-#{System.pid()}-#{System.unique_integer([:positive])}")
    :ok = File.mkdir(repo)
    owned!(repo)
    {_, 0} = System.cmd("git", ["init", "--quiet", repo])
    repo
  end

  # An owned repository's exact path, replaced only where it is a repository's `path` value. Validated: it is replaced
  # as often as it is decoded there, and it may not appear anywhere else in the reply.
  defp fixture_paths(shape, bytes, paths) do
    decoded = case JSON.decode(bytes) do
      {:ok, v} -> v
      _ -> nil
    end

    Enum.reduce(paths, bytes, fn {path, label}, acc ->
      want = Enum.count(collect(%{"path" => :string}, decoded), fn {_, p} -> p == path end)
      re = ~r/"path":#{Regex.escape(JSON.encode!(path))}/
      got = length(Regex.scan(re, acc))
      assert got == want, "#{shape}: #{label} occurs #{want} times as a path, #{got} in the raw reply"
      out = Regex.replace(re, acc, ~s("path":"#{label}"))
      refute String.contains?(out, path), "#{shape}: #{label} appears outside a path value"
      out
    end)
  end

  # Round 7 (Codex review 6, finding 4): the two repository replies must carry the owned repository's real path, and no
  # reply may already carry a fixture placeholder; only then is the path replaced.
  @repository_replies ["register_repository, a git repository", "registered_repository, that repository"]

  defp expect_repository_path!(shape, decoded, raw, extra) do
    for label <- ["<lane_repo>", "<extra_repo>"], do: refute(String.contains?(raw, label), "#{shape}: the reply already carries #{label}")

    if shape in @repository_replies,
      do: assert(get_in(decoded, ["repository", "path"]) == extra, "#{shape}: repository.path is not the owned repository")
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
    pairs =
      try do
        {a, task, repo} = attempt_fixture!()
        extra = git_repo!("extra")
        paths = [{repo, "<lane_repo>"}, {extra, "<extra_repo>"}]

        {pairs, _} =
          Enum.map_reduce(success_shapes(a, task, repo, extra), %{}, fn {name, make, n}, prev ->
            reply = exchange(ctx.host, make.(prev), n)
            fail_at!(name)

            decoded =
              case JSON.decode(reply) do
                {:ok, v} -> v
                _ -> %{}
              end

            expect_repository_path!(name, decoded, reply, extra)
            normal = reply |> then(&normalized(@success_volatile, name, &1)) |> then(&fixture_paths(name, &1, paths))
            {{%{"shape" => name, "reply" => normal}, reply}, decoded}
          end)

        pairs
      after
        release_all!(ctx.bridge, true, fn -> write_raw!("success") end)
      end

    got = Enum.map(pairs, &elem(&1, 0))
    assert_every_field_seen(@success_volatile, Enum.map(pairs, &elem(&1, 1)))

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

  # ---- B9 for the fixture itself (round 7, Codex review 6): whatever fails, and wherever, the teardown leaves nothing
  # the fixture made. Each scenario runs on its own runtime socket pair and bridge loop, injects one failure, and then
  # checks: the injected failure (or the cleanup error it causes) is what surfaced; every socket the fixture recorded is
  # closed; the BEAM holds exactly the descriptors it held before; no fixture directory remains (a removal that failed
  # on purpose leaves exactly its one, which the law then removes); and the runtime holds no adopted channel.

  # The open socket descriptors, as {fd, inode}: what the fixture can leak (it makes only sockets and directories).
  # Read once the table is settled, because background work after a world reset can open and close other files.
  defp open_sockets do
    read = fn ->
      for fd <- File.ls!("/proc/self/fd"), {:ok, t} <- [File.read_link("/proc/self/fd/" <> fd)],
          String.starts_with?(t, "socket:"), into: MapSet.new(), do: {fd, t}
    end

    Enum.reduce_while(1..30, read.(), fn _, prev ->
      Process.sleep(100)
      now = read.()
      if now == prev, do: {:halt, now}, else: {:cont, now}
    end)
  end
  defp fixture_dirs, do: Path.wildcard(Path.join(System.tmp_dir!(), "t27b-{pair,golden}-#{System.pid()}-*"))

  test "B9 · the reply fixture leaves nothing it made, whatever fails" do
    # Binds only: an unknown command's rights are B2's law, and its plant must stay that law's alone.
    bind = cmd(%{"command" => "bind_agent_channel", "actor" => "t27b-b9"})

    scenarios = [
      {"a failure while a pair is built", :pair_construction, nil, fn h -> exchange(h, bind, 2) end, "injected failure: pair_construction"},
      {"a failure after the first of three pairs", :after_first_pair, nil, fn h -> exchange(h, bind, 3) end, "injected failure: after_first_pair"},
      {"a bind whose reply outlives the receive", :recv_timeout, nil, fn h -> exchange(h, bind, 1) end, "MatchError"},
      {"a removal that fails, with another after it", :remove, nil, fn h -> exchange(h, bind, 2) end, "cleanup errors: remove"},
      {"an evidence file that cannot be written", :none, "/proc/t27b-unwritable/raw", fn h -> exchange(h, bind, 1) end, "cleanup errors: write the evidence"}
    ]

    for {what, point, raw_to, run, surfaced} <- scenarios do
      Ampd.Bridge.reset()
      sockets = open_sockets()
      dirs = fixture_dirs()
      {runtime, host} = Ampd.Transport.socketpair(:seqpacket)
      {:ok, bridge} = HostBridge.start(runtime)
      Process.put(:t27b_inject, Atom.to_string(point))
      if raw_to, do: Process.put(:t27b_raw_out, raw_to)
      ledger = fn -> Process.get(:t27b_held, []) end

      {recorded, outcome} =
        try do
          run.(host)
          {ledger.(), :ran}
        rescue
          e -> {ledger.(), {:failed, Exception.format_banner(:error, e)}}
        end

      cleaned =
        try do
          release_all!(bridge, false, fn -> write_raw!("b9") end)
          :clean
        rescue
          e -> {:cleanup, Exception.message(e)}
        end

      for key <- [:t27b_inject, :t27b_raw_out, :t27b_raw, {:t27b_injected, point}], do: Process.delete(key)
      :socket.close(host)
      :socket.close(runtime)
      left = fixture_dirs() -- dirs

      if point == :remove do
        assert length(left) == 1, "#{what}: #{length(left)} fixture directories remain, not the one whose removal failed"
        File.rm_rf!(hd(left))
      else
        assert left == [], "#{what}: fixture directories remain: #{inspect(left)}"
      end

      assert inspect({outcome, cleaned}) =~ surfaced, "#{what}: #{inspect({outcome, cleaned})}"
      assert recorded != [], "#{what}: the fixture recorded no socket, so the law saw nothing"

      for sock <- recorded,
          do: assert(:socket.getopt(sock, {:otp, :fd}) == {:error, :closed}, "#{what}: a recorded socket is still open")

      assert Ampd.Bridge.list() == [], "#{what}: an adopted channel survived the teardown"
      extra = MapSet.difference(open_sockets(), sockets) |> Enum.to_list()
      assert extra == [], "#{what}: the BEAM holds socket descriptors it did not hold before: #{inspect(extra)}"
    end
  end
end
