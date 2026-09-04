defmodule Ampd.TerminalPlaneTest do
  @moduledoc """
  D.1.3c·2c·1b falsifiers — `B.1`..`B.16`.

  The proposition:

      Terminal output reaches the operator over a descriptor of its own,
      losslessly and in order, pulled by the page's acknowledgement and by
      nothing else — bound to one presentation incarnation, one reader per
      terminal, authorised on the control channel and never on the bridge,
      and ended rather than migrated when any part of its basis moves.

  ## The fixture stands in for the cockpit, and says where the seam is

  In production the socketpair is created by the cockpit's Rust side and one
  end reaches ampd over the bridge as `SCM_RIGHTS`; `Ampd.Transport.HostBridge`
  adopts it with `Ampd.NativeFd.adopt_socket/1` and parks it. Here the pair is
  `Ampd.Transport.socketpair/1` and the park is direct.

  **What that skips is the descriptor transfer and nothing else.** Every
  property below is about what happens *after* a socket is parked, and the
  transfer's own laws — one fd on success, zero on refusal, `MSG_CTRUNC`
  refused, every surplus right sunk — are D.1.3c·2a's and are already
  falsified where they live. `B.13` covers the one thing this seam adds: a
  parked endpoint nobody claims must be closed rather than forgotten.
  """
  use ExUnit.Case, async: false

  alias Ampd.{Authority, Carrier, Control, Loci, Peer, Worker}
  alias Ampd.Carrier.Machine.Harness
  alias Ampd.Carrier.Terminal, as: T
  alias Ampd.Terminal.{Plane, Presentations}
  alias Ampd.Terminal.Presentation, as: P
  alias Ampd.TerminalAttachment, as: TA

  @out 1
  @ack 2
  @close 3

  # ==================================================================== setup
  setup do
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()

    Ampd.reset()
    Ampd.Bridge.reset()
    Peer.reset()
    Harness.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
    Application.put_env(:ampd, :carrier_machine, Harness)
    Ampd.Carrier.Machine.Gate.sync()

    {:ok, litter} = Agent.start(fn -> {[], []} end)

    on_exit(fn ->
      Presentations.reset()
      if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
      Peer.reset()
      if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    end)

    on_exit(fn ->
      {socks, pids} = Agent.get(litter, & &1)
      for p <- pids, Process.alive?(p), do: TA.close(p)
      for s <- socks, do: :socket.close(s)
      Agent.stop(litter)
    end)

    Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)
    Process.sleep(120)
    Authority.install_worktree()

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    # **The control channel is claimed by a process this test may kill.**
    # `Ampd.attach_pair/1` claims it from the *caller*, so `Peer.owner_pid/1`
    # would be the test process and `B.12` would kill itself — which it did.
    # A binding is a socket held by a process; to falsify "the plane ends
    # when the connection does", the connection has to be somebody else.
    control = claim_control!()
    {:ok, agent} = Peer.attach_agent("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "watch a terminal"]), "goal")

    lane =
      ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")

    w = ok!(Control.command(control, :open_worker, [lane["id"], "work"]), "worker")
    ok!(Control.command(agent, :attach_worker, [w["id"]]), "worker")

    {:ok, inc} = Carrier.start(agent, lane["id"])

    %{
      control: control,
      agent: agent,
      goal: goal,
      repo: r["ref"],
      lane: lane,
      worker: w,
      inc: inc,
      litter: litter
    }
  end

  # ----------------------------------------------------------- fixture glue
  defp claim_control! do
    me = self()

    spawn(fn ->
      {:ok, id} = Peer.claim_control_channel()
      send(me, {:control, id})
      Process.sleep(:infinity)
    end)

    receive do
      {:control, id} -> id
    after
      5_000 -> flunk("no control channel")
    end
  end

  # **The agent's process printing, and it must be its own process.**
  # In production this write is the host's PTY pump. Writing from the test
  # process is what made `B.5`/`B.6`/`B.7` hang for sixty seconds each — and
  # that hang was not a fixture bug so much as the mechanism arriving at the
  # fixture: with the page not acking, the plane stops pulling, the
  # attachment stops selecting, the socketpair fills, and `:socket.send/2`
  # blocks in whoever called it. That is the whole chain this slice claims,
  # observed from the wrong end.
  #
  # It reports progress as it goes, so a test can measure how far upstream
  # the stall reached instead of tripping over it.
  defp printer!(sock, payload, chunk \\ 8_192) do
    me = self()

    spawn(fn ->
      total = write_all(sock, payload, chunk, 0, me)
      send(me, {:printer_done, total})
    end)
  end

  defp write_all(_sock, <<>>, _chunk, n, _me), do: n

  defp write_all(sock, rest, chunk, n, me) do
    take = min(chunk, byte_size(rest))
    piece = binary_part(rest, 0, take)
    send(me, {:printer_at, n})

    case :socket.send(sock, piece) do
      :ok -> write_all(sock, binary_part(rest, take, byte_size(rest) - take), chunk, n + take, me)
      _ -> n
    end
  end

  # How many bytes the writer had offered before it stopped making progress.
  defp printed_upto(quiet_ms \\ 700), do: printed_upto(quiet_ms, 0)

  defp printed_upto(quiet_ms, n) do
    receive do
      {:printer_at, m} -> printed_upto(quiet_ms, max(n, m))
      {:printer_done, m} -> {:done, max(n, m)}
    after
      quiet_ms -> {:stalled, n}
    end
  end

  defp init_repo! do
    dir = Path.join(System.tmp_dir!(), "ampd-plane-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "commit", "-q", "--allow-empty", "-m", "root"])
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp ok!({:ok, v}, _), do: v
  defp ok!(%{"allow" => true} = r, key), do: r[key] || r
  defp ok!(other, key), do: flunk("expected #{key}, got #{inspect(other, limit: 5)}")

  defp track(ctx, {:sock, s}), do: Agent.update(ctx.litter, fn {a, b} -> {[s | a], b} end)
  defp track(ctx, {:pid, p}), do: Agent.update(ctx.litter, fn {a, b} -> {a, [p | b]} end)

  defp pair(ctx) do
    {mine, theirs} = Ampd.Transport.socketpair(:stream)
    track(ctx, {:sock, mine})
    track(ctx, {:sock, theirs})
    {mine, theirs}
  end

  defp hex(n), do: Base.encode16(:crypto.strong_rand_bytes(div(n, 2)), case: :lower)

  defp obs do
    %{
      "schema" => "carrier-pty-attach-observation@1",
      "attached" => true,
      "attachment_ref" => "ta_" <> hex(32),
      "attachment_epoch" => hex(32),
      "pty_epoch" => hex(32)
    }
  end

  # A possessed terminal whose FAR end this test can write to — that socket
  # is the host's pump in production, and writing to it here is the agent's
  # process printing.
  defp possess!(ctx) do
    {:ok, ticket} = T.admit_attach(ctx.agent)
    {mine, theirs} = pair(ctx)
    o = obs()
    {:ok, pid, identity} = T.own_stream(ticket, o, mine)
    track(ctx, {:pid, pid})
    {:ok, record} = T.commit_b1(ticket, o, pid)
    :ok = TA.prepare(pid, Map.merge(record, identity), Peer.owner_pid(ctx.agent))
    {:ok, active} = T.commit_b2(ticket, record, pid)
    %{pid: pid, record: record, active: active, pty: theirs}
  end

  defp gen(ref), do: (Loci.worker(ref) || %{})["generation"] || 1

  # The resolved record, because `Ampd.Peer.claim_control_channel/0` hands
  # back an id and the relation is about the bound connection.
  defp bound(id), do: Peer.resolve(id)

  # The cockpit's half: a socketpair, one end parked as if it had arrived
  # over the bridge.
  defp endpoint(ctx) do
    {mine, theirs} = pair(ctx)
    {:ok, ref} = Presentations.park(theirs)
    {mine, ref}
  end

  defp bind(ctx, ref \\ nil) do
    {mine, endpoint} = endpoint(ctx)
    w = ref || ctx.worker["id"]
    {mine, Control.command(ctx.control, :terminal_bind, [w, gen(w), endpoint])}
  end

  # ---------------------------------------------------------------- framing
  defp decode(buf, acc \\ [])

  defp decode(<<@out, seq::big-64, len::big-32, body::binary-size(len), rest::binary>>, acc),
    do: decode(rest, [{:out, seq, body} | acc])

  defp decode(<<@close, l::big-16, code::binary-size(l), rest::binary>>, acc),
    do: decode(rest, [{:close, code} | acc])

  defp decode(buf, acc), do: {Enum.reverse(acc), buf}

  defp drain(sock, buf \\ <<>>, acc \\ [], budget \\ 250) do
    case :socket.recv(sock, 0, budget) do
      {:ok, data} ->
        {frames, rest} = decode(buf <> data)
        drain(sock, rest, acc ++ frames, budget)

      _ ->
        {acc, buf}
    end
  end

  defp bytes(frames),
    do:
      frames
      |> Enum.filter(&match?({:out, _, _}, &1))
      |> Enum.map(&elem(&1, 2))
      |> IO.iodata_to_binary()

  defp seqs(frames), do: for({:out, s, _} <- frames, do: s)
  defp closes(frames), do: for({:close, c} <- frames, do: c)

  # ===================================================================== B.1
  test "B.1 · the page designates a position and an incarnation, and receives neither more nor less",
       ctx do
    possess!(ctx)
    {_mine, reply} = bind(ctx)

    assert reply["allow"] == true
    p = reply["presentation"]

    assert p == %{
             "schema" => "terminal-presentation@1",
             "worker_ref" => ctx.worker["id"],
             "worker_generation" => gen(ctx.worker["id"])
           },
           "the reply carries something other than the two identifiers the page supplied"

    # The sharp form: asserted against the serialized reply, because a
    # derived identifier reaching a page is how an unguessable name becomes a
    # bearer token, and it reaches it by being added to the wrong struct.
    json = JSON.encode!(reply)

    for forbidden <- ~w(peer_ref attachment_ref attachment_epoch carrier_ref carrier_epoch
                        pty_epoch locus_ref endpoint_ref presentation_ref) do
      refute String.contains?(json, forbidden), "#{forbidden} crossed to the page"
    end
  end

  # ===================================================================== B.2
  test "B.2 · an agent channel may not open a data plane", ctx do
    possess!(ctx)
    {_mine, e} = endpoint(ctx)
    ref = ctx.worker["id"]

    # The agent OCCUPIES this Worker and possesses this very terminal. It is
    # refused for the channel it is on, before anything about the terminal is
    # considered.
    r = Control.command(ctx.agent, :terminal_bind, [ref, gen(ref), e])
    assert r["allow"] == false
    assert Presentations.live() == %{}, "a plane was opened on the agent channel"
  end

  # ===================================================================== B.3
  test "B.3 · the bridge cannot name a Worker, so it cannot make a presentation", _ctx do
    # **The structural claim, checked against the source of the one arm that
    # takes a descriptor.** The reason a bridge command cannot obtain a
    # presentation basis is not that the bridge is trusted — it is that
    # `bind_terminal_endpoint`'s entire vocabulary is "here is a socket".
    # There is no argument it could carry that would designate a position.
    src = File.read!("lib/ampd/transport.ex")

    [arm] =
      Regex.run(~r/defp run\("bind_terminal_endpoint".*?\n    end\n/s, src) ||
        flunk("the bridge arm is gone")

    # `Presentations.park` contains the substring `Presentation`, so a naive
    # word list reports the arm breaking a law it holds. The names that
    # matter are the ones that would let it DESIGNATE something.
    for named <- ~w(worker_ref expected_worker_generation Presentation.resolve
                    Presentation.current peer_ref actor) do
      refute String.contains?(arm, named),
             "the bridge arm names #{named} — the authority decision has moved onto the " <>
               "channel that carries no operator identity"
    end

    assert String.contains?(arm, "Presentations.park")
  end

  # ===================================================================== B.4
  test "B.4 · one presentation per terminal attachment; the second is refused by name", ctx do
    possess!(ctx)
    {_m1, first} = bind(ctx)
    assert first["allow"] == true

    {_m2, second} = bind(ctx)
    assert second["allow"] == false
    assert second["refusal"]["code"] == "terminal-already-presented"

    assert map_size(Presentations.live()) == 1,
           "a second reader was admitted — both would receive an arbitrary half of the stream"
  end

  # ===================================================================== B.5
  test "B.5 · output arrives in order, without gaps, without duplicates", ctx do
    p = possess!(ctx)
    {mine, reply} = bind(ctx)
    assert reply["allow"] == true

    # 240 KiB — larger than the socket buffer and far larger than the window,
    # so it can only arrive by acking, and the writer is its own process
    # because it WILL block.
    payload = for i <- 1..2_000, into: "", do: String.pad_leading("#{i}", 120, ".")
    printer!(p.pty, payload)

    {got, _} = pump_all(mine, byte_size(payload))

    assert bytes(got) == payload, "the byte stream is not what was written"

    s = seqs(got)

    assert s == Enum.to_list(1..length(s)),
           "sequence numbers are not 1..n with no gaps: #{inspect(Enum.take(s, 12))}"

    assert length(Enum.uniq(s)) == length(s), "a sequence number was delivered twice"
  end

  # Read and ack until `total` bytes have arrived or the stream goes quiet.
  defp pump_all(sock, total, buf \\ <<>>, acc \\ [], got \\ 0) do
    case :socket.recv(sock, 0, 800) do
      {:ok, data} ->
        {frames, rest} = decode(buf <> data)
        n = got + (frames |> bytes() |> byte_size())

        case List.last(seqs(frames)) do
          nil -> :ok
          last -> :socket.send(sock, <<@ack, last::big-64>>)
        end

        if n >= total,
          do: {acc ++ frames, rest},
          else: pump_all(sock, total, rest, acc ++ frames, n)

      _ ->
        {acc, buf}
    end
  end

  # ===================================================================== B.6
  test "B.6 · with no acknowledgement the stream stops, bounded, all the way upstream", ctx do
    p = possess!(ctx)
    {mine, reply} = bind(ctx)
    assert reply["allow"] == true

    offered = 512_000
    [{_ref, _}] = Map.to_list(Presentations.live())
    printer!(p.pty, :binary.copy("x", offered))

    {state, produced} = printed_upto(900)
    {got, _} = drain(mine)
    delivered = byte_size(bytes(got))
    window = Plane.credits() * TA.chunk_bytes()

    # **`:erlang.memory(:total)` was the wrong instrument and it said so.**
    # The first version of this assertion measured whole-VM memory and read
    # +670 448 bytes against 512 000 offered — which is true and means
    # nothing: the payload binary itself is allocated in *this* process, and
    # ExUnit, the printer and the refc binary are all inside that total. The
    # question is whether anything ON THE PATH buffers, and the path is two
    # processes. Measure those.
    [{_a, plane}] = Map.to_list(Presentations.live())
    owner = Process.info(p.pid, [:memory, :message_queue_len])
    pl = Process.info(plane, [:memory, :message_queue_len])
    on_path = owner[:memory] + pl[:memory]

    IO.puts(
      "\n    B.6 backpressure · offered #{offered} · writer stalled at #{produced} (#{state}) · " <>
        "delivered #{delivered} · window #{window}" <>
        "\n        attachment owner  #{owner[:memory]} bytes, mailbox #{owner[:message_queue_len]}" <>
        "\n        plane             #{pl[:memory]} bytes, mailbox #{pl[:message_queue_len]}" <>
        "\n        on-path total     #{on_path} bytes\n"
    )

    assert delivered > 0, "nothing was delivered at all"

    assert delivered <= window,
           "#{delivered} bytes arrived with nothing acked, over a window of #{window} — " <>
             "the credit is not bounding the stream"

    # **The stall reaches the writer**, which is the claim that matters. In
    # production that writer is the host's pump and the next link is the
    # Carrier blocking in `write(2)`.
    assert state == :stalled,
           "the writer completed #{produced} of #{offered} bytes with nothing acked — " <>
             "something between it and the page is absorbing the stream"

    assert produced < offered,
           "the writer got the whole payload away with nothing acked"

    # **Nothing on this path may buffer.** The one buffer that exists by
    # design is the attachment's undelivered tail of a single socket read, so
    # the bound is a socket read plus the window, generously — not a fraction
    # of what was offered, which would pass for a path that buffered a third
    # of it.
    assert on_path < 256_000,
           "the two processes on the path hold #{on_path} bytes — something is queueing"

    # A mailbox is where an unbounded byte buffer would actually appear: the
    # attachment sends one message per chunk and the plane forwards it, so a
    # plane that stopped forwarding would grow a queue rather than a heap.
    assert pl[:message_queue_len] <= Plane.credits(),
           "the plane's mailbox holds #{pl[:message_queue_len]} messages, over a window of " <>
             "#{Plane.credits()} — the credit is not reaching the attachment"

    assert owner[:message_queue_len] < 50,
           "the attachment owner's mailbox is growing (#{owner[:message_queue_len]})"

    # Where the bytes actually are: not in the BEAM. Between the writer and
    # the reader sit two kernel socket buffers, and they are bounded by
    # SO_SNDBUF/SO_RCVBUF rather than by anything here — which is the point.
    # The runtime is not holding a person's terminal output.
    IO.puts(
      "    in kernel socket buffers: #{produced - delivered} bytes " <>
        "(offered #{produced}, delivered #{delivered})\n"
    )

    # And a stream that has stopped is not a process that has stopped: this
    # is the property the `:nowait` pull exists for, and it is what
    # D.1.3c·2c·1a's A2 repair depends on staying true.
    assert TA.state(p.pid, 1_000) == :active
  end

  # ===================================================================== B.7
  test "B.7 · acknowledging resumes it, exactly where it stopped, losing nothing", ctx do
    p = possess!(ctx)
    {mine, _} = bind(ctx)

    payload = :binary.copy("abcdefgh", 40_000)
    printer!(p.pty, payload)
    Process.sleep(400)

    {first, buf} = drain(mine)
    stalled = byte_size(bytes(first))
    last = List.last(seqs(first))
    assert is_integer(last)

    {nothing, buf} = drain(mine, buf, [], 250)
    assert nothing == [], "the stream did not stop when the credit ran out"

    :socket.send(mine, <<@ack, last::big-64>>)
    {more, _} = drain(mine, buf, [], 600)

    resumed = seqs(more)
    refute resumed == [], "acking returned no credit"

    assert resumed == Enum.to_list((last + 1)..(last + length(resumed))),
           "the resumed stream did not continue from #{last}"

    all = bytes(first) <> bytes(more)
    assert byte_size(all) > stalled

    assert binary_part(payload, 0, byte_size(all)) == all,
           "the bytes after the resume are not the bytes that follow — the stall lost or " <>
             "reordered something"
  end

  # ===================================================================== B.8
  test "B.8 · a forged acknowledgement ends the presentation rather than inflating the window",
       ctx do
    p = possess!(ctx)
    {mine, _} = bind(ctx)
    :socket.send(p.pty, "hello")
    Process.sleep(200)
    {got, _} = drain(mine)
    refute got == []

    :socket.send(mine, <<@ack, 9_999_999::big-64>>)
    Process.sleep(300)

    assert Presentations.live() == %{},
           "a page that acked what was never sent kept its plane, and its window is now a fiction"

    # The possession is untouched — this ended a presentation, not a terminal.
    assert TA.state(p.pid, 1_000) == :active
  end

  # ==================================================================== B.19
  #
  # **D.1.3c·2c·1b·1.** `consume/1` read
  #
  #     if seq > s.seq or seq < s.acked, do: bad_ack
  #
  # and the second half of that disjunction is wrong. The page issues one
  # `terminal_ack` invoke per consumed chunk; each is its own
  # `async_runtime::spawn` and its own `spawn_blocking`, so two issued in
  # order can reach the `SyncSender` in either order — which
  # `cockpit/src/main.rs` documents for `bind`/`unbind` and this module then
  # did not apply. A cumulative ack cannot invent credit by being old: the
  # newer one already said everything the older one says.
  #
  # The old law turned an ordinary scheduling outcome into a killed
  # presentation, and there was no falsifier because the BEAM probe drives
  # the socket directly and therefore always in order.
  test "B.19 · cumulative acknowledgements may arrive out of order without ending the stream",
       ctx do
    p = possess!(ctx)
    {mine, _} = bind(ctx)

    payload = :binary.copy("abcdefgh", 40_000)
    printer!(p.pty, payload)
    Process.sleep(400)

    {first, buf} = drain(mine)
    last = List.last(seqs(first))
    assert is_integer(last) and last >= 2, "the window did not fill, so there is nothing to reorder"

    {nothing, buf} = drain(mine, buf, [], 250)
    assert nothing == [], "the stream did not stop when the credit ran out"

    # The reordering, deliberately: the NEWER cumulative ack first.
    :socket.send(mine, <<@ack, last::big-64>>)
    :socket.send(mine, <<@ack, last - 1::big-64>>)
    Process.sleep(300)

    refute Presentations.live() == %{},
           "an older cumulative ack arriving after a newer one ended the presentation — " <>
             "a page that acknowledges two chunks in order can produce exactly this"

    [{_ref, plane}] = Map.to_list(Presentations.live())
    info = Plane.info(plane)

    assert info.acked == last,
           "the stale ack moved the cumulative mark backwards to #{info.acked} — " <>
             "an old ack must be ignored, not applied"

    {more, _} = drain(mine, buf, [], 600)
    resumed = seqs(more)
    refute resumed == [], "the reordered acks returned no credit at all"

    assert resumed == Enum.to_list((last + 1)..(last + length(resumed))),
           "the stream did not continue from #{last} after the reordered acks"

    all = bytes(first) <> bytes(more)

    assert binary_part(payload, 0, byte_size(all)) == all,
           "the bytes after the reordered acks are not the bytes that follow"
  end

  # ==================================================================== B.20
  #
  # **An invariant, not a falsifier of B.19's repair — and saying so is the
  # point.** The old law refused `seq < acked`, so an ack of exactly `acked`
  # passed under it too and this test is green either way. It is here
  # because `ui/terminal.js` now re-sends its high-water on a timer, so that
  # hearing nothing from the pane means something, and a beat that could
  # buy credit would be a liveness signal with a side effect on the window.
  # B.19 is the falsifier; this is the property the beat rides on.
  test "B.20 · a repeated cumulative acknowledgement is ordinary, and invents no credit", ctx do
    p = possess!(ctx)
    {mine, _} = bind(ctx)

    payload = :binary.copy("abcdefgh", 40_000)
    printer!(p.pty, payload)
    Process.sleep(400)

    {first, buf} = drain(mine)
    last = List.last(seqs(first))
    assert is_integer(last)

    :socket.send(mine, <<@ack, last::big-64>>)
    Process.sleep(200)
    {resumed, buf} = drain(mine, buf, [], 400)
    after_first = length(seqs(resumed))
    refute after_first == 0, "the first ack returned no credit"

    # The same mark again — the beat. It must move nothing.
    [{_ref, plane}] = Map.to_list(Presentations.live())
    before = Plane.info(plane)
    :socket.send(mine, <<@ack, last::big-64>>)
    :socket.send(mine, <<@ack, last::big-64>>)
    Process.sleep(300)

    refute Presentations.live() == %{}, "a repeated cumulative ack ended the presentation"

    {extra, _} = drain(mine, buf, [], 300)
    now = Plane.info(plane)

    assert now.acked == before.acked,
           "a repeated ack moved the cumulative mark from #{before.acked} to #{now.acked}"

    assert now.seq - now.acked <= Plane.credits(),
           "the window grew past #{Plane.credits()} chunks — repeated acks bought credit"

    # It may deliver more, because the FIRST ack's credit is still being
    # spent; what it must not do is deliver more than the window allows.
    assert length(seqs(extra)) <= Plane.credits(),
           "more than one window arrived after two repeated acks"
  end

  # ==================================================================== B.21
  test "B.21 · an acknowledgement one past what was sent still ends the presentation", ctx do
    p = possess!(ctx)
    {mine, _} = bind(ctx)
    :socket.send(p.pty, "hello")
    Process.sleep(200)
    {got, _} = drain(mine)
    refute got == []
    last = List.last(seqs(got))

    # **The tight boundary, and B.8 only had the loose one.** `9_999_999` is
    # refused by any rule that looks at the number at all; `sent + 1` is
    # refused only by a rule that compares it with what was actually sent,
    # which is the property being claimed.
    :socket.send(mine, <<@ack, last + 1::big-64>>)
    Process.sleep(300)

    assert Presentations.live() == %{},
           "a page acknowledged one chunk more than was ever sent and kept its plane"

    assert TA.state(p.pid, 1_000) == :active
  end

  # ===================================================================== B.9
  test "B.9 · closing the presentation leaves the terminal possessed", ctx do
    p = possess!(ctx)
    {_mine, _} = bind(ctx)
    [{_ref, plane}] = Map.to_list(Presentations.live())

    :ok = Plane.close(plane)
    Process.sleep(200)

    assert Presentations.live() == %{}
    assert TA.state(p.pid, 1_000) == :active, "closing a presentation closed the terminal"

    record = Peer.terminal_attachment(Peer.resolve(ctx.agent)["id"])
    assert record["status"] == "ACTIVE", "the World record did not survive the presentation"

    # And a new one can be opened over the same terminal.
    {_m2, again} = bind(ctx)
    assert again["allow"] == true
  end

  # ==================================================================== B.10
  test "B.10 · the stream owner dying ends the plane, and says so", ctx do
    p = possess!(ctx)
    {mine, _} = bind(ctx)

    Process.exit(p.pid, :kill)
    Process.sleep(300)

    {got, _} = drain(mine)
    assert "terminal-stream-gone" in closes(got), "the page was not told why its stream ended"
    assert Presentations.live() == %{}
  end

  # ==================================================================== B.11
  test "B.11 · the Worker's generation advancing ends the plane, and it does not follow", ctx do
    possess!(ctx)
    {mine, _} = bind(ctx)
    ref = ctx.worker["id"]
    before = gen(ref)

    ok!(Control.command(ctx.control, :close_worker, [ref]), "worker")
    ok!(Control.command(ctx.control, :reopen_worker, [ref]), "worker")
    refute gen(ref) == before

    # **Bounded, and measured rather than assumed.** Re-derivation runs on a
    # tick, so the claim is that the plane ends within a stated interval —
    # not instantly. A generous multiple of that interval makes this a
    # falsifier for the mechanism rather than a race.
    closed =
      Enum.find_value(1..40, fn _ ->
        Process.sleep(Plane.revalidate_ms())
        if Presentations.live() == %{}, do: true
      end)

    assert closed, "the plane outlived the incarnation it was bound to"

    # **Either reason, and the first version of this test demanded the wrong
    # one.** `close_worker` runs `Ampd.Carrier.converge/1`, which reaps the
    # Carrier — so the stream owner's death usually wins the race against the
    # revalidation tick, and the plane closes `terminal-stream-gone` rather
    # than `presentation-basis-moved`. Both are the basis moving; asserting
    # one of them was asserting which of two correct mechanisms got there
    # first. What must hold is that the page is TOLD, by name.
    told = closes(drain(mine) |> elem(0))

    assert told != [], "the plane ended without telling the page anything"

    assert Enum.all?(told, &(&1 in ~w(presentation-basis-moved terminal-stream-gone))),
           "the plane closed for an unadjudicated reason: #{inspect(told)}"
  end

  # ==================================================================== B.12
  test "B.12 · the control channel closing ends the plane", ctx do
    possess!(ctx)
    {_mine, _} = bind(ctx)
    refute Presentations.live() == %{}

    # The process holding the control socket is the connection. Its death is
    # the channel closing, and there is no person watching after it.
    owner = Peer.owner_pid(ctx.control)
    assert is_pid(owner)
    Process.exit(owner, :kill)
    Process.sleep(400)

    assert Presentations.live() == %{},
           "a data plane outlived the control connection that opened it"
  end

  # ==================================================================== B.13
  test "B.13 · a parked endpoint nobody claims is closed, not forgotten", ctx do
    {mine, ref} = endpoint(ctx)

    # An adopted descriptor with no owner and no exit is the one thing the
    # adoption contract exists to make hard to write. The far end noticing
    # EOF is how a caller learns its offer expired.
    Process.sleep(Presentations.ttl_ms() + 400)

    assert {:error, :unknown_terminal_endpoint} = Presentations.claim_endpoint(ref)

    assert :socket.recv(mine, 0, 500) in [{:error, :closed}, {:ok, ""}],
           "the parked endpoint was forgotten rather than closed — its descriptor has no exit"
  end

  # ==================================================================== B.14
  test "B.14 · an endpoint is claimed once, and a refused bind does not consume one", ctx do
    possess!(ctx)
    {_mine, e} = endpoint(ctx)
    ref = ctx.worker["id"]

    # A designation that cannot be authorised must not cost the caller its
    # descriptor: otherwise a page could exhaust a cockpit's endpoints by
    # asking about Workers it may not see.
    stale = Control.command(ctx.control, :terminal_bind, [ref, gen(ref) + 7, e])
    assert stale["allow"] == false
    assert stale["refusal"]["code"] == "worker-generation-stale"

    good = Control.command(ctx.control, :terminal_bind, [ref, gen(ref), e])
    assert good["allow"] == true, "the refused attempt consumed the endpoint"

    # And it is gone now.
    again = Control.command(ctx.control, :terminal_bind, [ref, gen(ref), e])
    assert again["allow"] == false
    assert again["refusal"]["code"] == "terminal-endpoint-unknown"
  end

  # ==================================================================== B.15
  test "B.15 · a data plane is not reachable through the projection stream", ctx do
    possess!(ctx)
    {_mine, _} = bind(ctx)

    # The whole reason for a second descriptor. If terminal bytes could
    # travel on the control plane, the first slow page would coalesce a
    # transcript into a plausible and wrong one — silently, because
    # coalescing is that plane's correct behaviour.
    row = Worker.projected(Loci.workers())[ctx.worker["id"]]
    json = JSON.encode!(row)

    assert row["terminal"] == "PRESENT"

    for forbidden <- ~w(bytes out seq endpoint attachment_ref peer_ref) do
      refute String.contains?(json, "\"#{forbidden}\""), "#{forbidden} is on the control plane"
    end

    src = File.read!("lib/ampd/projection.ex")

    refute String.contains?(src, "Terminal.Plane"),
           "the projection names the data plane"
  end

  # ==================================================================== B.18
  test "B.18 · the data plane's authority is not on a read path" do
    # **The premise an ordered-boundary exclusion rests on, made falsifiable.**
    #
    # `tools/ordered-reachability.exs` builds a FUNCTION-level call graph, so
    # the closure `Ampd.Control.in_lineage/4` hands to `Projection.framed/2`
    # for read commands admits every clause of `dispatch/3` — including
    # `terminal_bind`, which reaches `Plane.open/2`,
    # `Presentations.claim_endpoint/1` and the terminal stream probe. Four
    # crossings are excluded on the ground that the program does not reach
    # them that way: a `:mutation` runs `run.()` directly, outside the order.
    #
    # Change `terminal_bind` to `kind: :read` and every one of those
    # exclusions becomes silently wrong while the census output looks
    # identical — the call graph does not change. So the classification is
    # read here rather than trusted.
    spec = Ampd.CommandSpec.get("terminal_bind")

    assert spec.kind == :mutation,
           "terminal_bind is #{inspect(spec.kind)}: four ordered-boundary exclusions rest on " <>
             "it being a mutation, and the reachability census cannot tell the difference"

    assert spec.channel == :human_control

    # And the other half of the premise: reads are what `framed/2` wraps.
    src = File.read!("lib/ampd/control.ex")

    assert String.contains?(src, "cmd in @reads -> Projection.framed(lineage, run)"),
           "`Ampd.Control.in_lineage/4` no longer routes reads through the seqlock — the " <>
             "exclusions' reasoning is about a dispatch shape that has changed"
  end

  # ==================================================================== B.17
  test "B.17 · a basis that moved between the authority and the bind is refused", ctx do
    # **The window `terminal_bind` opens by not being ordered.** It is a
    # mutation, and mutations run outside the total order — so between
    # `resolve/3` establishing the basis and the plane binding to it, another
    # transaction can close the Worker or replace the occupant. Without a
    # re-derivation at bind, the plane would stream that stale basis until
    # the first revalidation tick, which is `revalidate_ms/0` of output the
    # operator is no longer entitled to.
    #
    # The two halves are called separately here because `Ampd.Control` calls
    # them back to back and the race is microseconds wide. Splitting them is
    # what makes it a falsifier rather than a hope.
    possess!(ctx)
    ref = ctx.worker["id"]
    {_mine, e} = endpoint(ctx)

    assert {:ok, p} = P.resolve(bound(ctx.control), ref, gen(ref))

    ok!(Control.command(ctx.control, :close_worker, [ref]), "worker")
    ok!(Control.command(ctx.control, :reopen_worker, [ref]), "worker")

    # **`:presentation_stale` specifically, and the first version of this got
    # `:terminal_stream_gone`.** `close_worker` reaps the Carrier, so the
    # stream owner is usually dead too, and a plane that asked about the
    # owner first answered a true statement that is not the reason: the
    # operator may no longer see this position at all. Both checks stayed;
    # the order changed.
    assert {:error, :presentation_stale} = Plane.open(e, p),
           "a presentation resolved against a Worker incarnation that no longer exists " <>
             "was bound to a live stream, or was refused for the wrong reason"

    assert Presentations.live() == %{}
  end

  # ==================================================================== B.16
  test "B.16 · the plane never migrates to a replacement occupant", ctx do
    p = possess!(ctx)
    {_mine, _} = bind(ctx)
    [{aref, plane}] = Map.to_list(Presentations.live())
    assert aref == p.record["attachment_ref"]

    # The occupant leaves. A plane that followed the position rather than the
    # incarnation would now be showing whoever arrives next — possibly a
    # different actor — under the row the operator clicked.
    _ = T.release(ctx.agent)

    closed =
      Enum.find_value(1..40, fn _ ->
        Process.sleep(Plane.revalidate_ms())
        if not Process.alive?(plane), do: true
      end)

    assert closed, "the plane survived the terminal possession it was bound to"
    assert Presentations.live() == %{}
  end
end
