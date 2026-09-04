defmodule Ampd.TerminalPresentationTest do
  @moduledoc """
  D.1.3c·2c·1a falsifiers — `T.1`..`T.13`.

  The proposition:

      The unique human-control role may resolve a terminal presentation for
      a current, open, occupied Worker whose Carrier possesses an ACTIVE
      terminal — designating it by `worker_ref` and the generation it saw,
      and by nothing else. Every broken link in that chain refuses by its
      own name, no derived identity crosses to the page, and a presentation
      does not follow a replacement.

  ## What these do not test, and why that is not an omission

  There is no byte plane in this slice. `Ampd.Terminal.Presentation`
  resolves an authority relation; the ordered `OUT(seq)/OUT_ACK(seq)` data
  plane, the descriptor transfer and the pane are D.1.3c·2c·1b. Nine of the
  eleven properties the ruling named are properties of the resolution, and
  they are here.

  ## The one that matters most is `T.4`

  A page that saw generation 3 and asks after the Worker was reopened is
  designating a position that no longer exists under that name. Without the
  comparison, the runtime would resolve the *current* incarnation and show
  the operator a different assignment under the row they clicked. `T.13`
  proves the comparison is load-bearing by removing it.
  """
  use ExUnit.Case, async: false

  alias Ampd.{Authority, Bridge, Carrier, Control, Loci, Peer, Worker}
  alias Ampd.Carrier.Machine.Harness
  alias Ampd.Carrier.Terminal, as: T
  alias Ampd.Terminal.Presentation, as: P
  alias Ampd.TerminalAttachment, as: TA

  # ==================================================================== setup
  setup do
    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()

    Ampd.reset()
    Bridge.reset()
    Peer.reset()
    Harness.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
    Application.put_env(:ampd, :carrier_machine, Harness)
    Ampd.Carrier.Machine.Gate.sync()

    {:ok, litter} = Agent.start(fn -> {[], []} end)

    on_exit(fn ->
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

    if Process.whereis(Ampd.Carrier.Reaper), do: Ampd.Carrier.Reaper.drain()
    Ampd.AuthorityCoordinator.transact(fn -> Loci.reset() end)
    Process.sleep(120)
    Authority.install_worktree()

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "present a terminal"]), "goal")
    lane = ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")
    w = ok!(Control.command(control, :open_worker, [lane["id"], "work"]), "worker")
    ok!(Control.command(agent, :attach_worker, [w["id"]]), "worker")

    {:ok, inc} = Carrier.start(agent, lane["id"])

    %{control: control, agent: agent, lane: lane, worker: w, inc: inc, litter: litter}
  end

  # ----------------------------------------------------------- fixture glue
  defp init_repo! do
    dir = Path.join(System.tmp_dir!(), "ampd-pres-#{:erlang.unique_integer([:positive])}")
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

  # `Ampd.Transport.socketpair/1`, the same primitive the possession suite
  # uses. A hand-rolled listen/connect pair yields a socket the transfer
  # refuses — `{:transfer_failed, :closed}` — which is a fact about the
  # fixture and not about the code under test.
  defp pair(ctx) do
    {mine, theirs} = Ampd.Transport.socketpair(:stream)
    track(ctx, {:sock, mine})
    track(ctx, {:sock, theirs})
    {mine, theirs}
  end

  defp obs do
    hex = fn n -> Base.encode16(:crypto.strong_rand_bytes(div(n, 2)), case: :lower) end
    %{
      "schema" => "carrier-pty-attach-observation@1",
      "attached" => true,
      "attachment_ref" => "ta_" <> hex.(32),
      "attachment_epoch" => hex.(32),
      "pty_epoch" => hex.(32)
    }
  end

  # A fully possessed terminal at the setup's Worker.
  defp possess!(ctx) do
    {:ok, ticket} = T.admit_attach(ctx.agent)
    {mine, _theirs} = pair(ctx)
    o = obs()
    {:ok, pid, identity} = T.own_stream(ticket, o, mine)
    track(ctx, {:pid, pid})
    {:ok, record} = T.commit_b1(ticket, o, pid)
    :ok = TA.prepare(pid, Map.merge(record, identity), Peer.owner_pid(ctx.agent))
    {:ok, active} = T.commit_b2(ticket, record, pid)
    %{pid: pid, record: record, active: active}
  end

  defp gen(worker_ref), do: (Loci.worker(worker_ref) || %{})["generation"] || 1

  # **The resolved record, because `Ampd.attach_pair/1` hands back ids.**
  # `Ampd.Control` resolves the binding before it dispatches, and the
  # relation is about the bound connection rather than about a string.
  defp bound(id), do: Peer.resolve(id)
  defp code({:refused, r}), do: r["code"]
  defp code(other), do: {:unexpected, other}

  # ===================================================================== T.1
  test "T.1 · the human-control role resolves a presentation for a possessed terminal", ctx do
    possess!(ctx)
    ref = ctx.worker["id"]

    assert {:ok, p} = P.resolve(bound(ctx.control), ref, gen(ref))
    assert p["schema"] == P.schema()
    assert p["worker_ref"] == ref
    assert p["worker_generation"] == gen(ref)
  end

  # ===================================================================== T.2
  test "T.2 · an agent channel may not request a presentation", ctx do
    possess!(ctx)
    ref = ctx.worker["id"]

    # The agent OCCUPIES this Worker and possesses this very terminal, which
    # is what makes this the sharp case: refusing a stranger proves little.
    assert code(P.resolve(bound(ctx.agent), ref, gen(ref))) ==
             "terminal-presentation-not-human-control"

    assert code(P.resolve(nil, ref, gen(ref))) == "terminal-presentation-not-human-control"
  end

  # ===================================================================== T.3
  test "T.3 · an unknown worker_ref is refused by its own name", ctx do
    possess!(ctx)
    assert code(P.resolve(bound(ctx.control), "wk_nope", 1)) == "worker-unknown"
  end

  # ===================================================================== T.4
  test "T.4 · a stale expected_worker_generation is refused, not silently followed", ctx do
    possess!(ctx)
    ref = ctx.worker["id"]
    saw = gen(ref)

    # The page saw generation N. Close and reopen: the position is now a
    # different incarnation under the same name.
    ok!(Control.command(ctx.control, :close_worker, [ref]), "worker")
    ok!(Control.command(ctx.control, :reopen_worker, [ref]), "worker")

    refute gen(ref) == saw, "close+reopen did not advance the generation"

    assert {:refused, r} = P.resolve(bound(ctx.control), ref, saw)
    assert r["code"] == "worker-generation-stale"
    assert r["operator_detail"]["expected"] == saw
    assert r["operator_detail"]["current"] == gen(ref)
  end

  # ===================================================================== T.5
  test "T.5 · a closed Worker is refused, and generation is checked first", ctx do
    possess!(ctx)
    ref = ctx.worker["id"]
    ok!(Control.command(ctx.control, :close_worker, [ref]), "worker")

    # Closing advances the generation, so a page holding the OLD one is
    # refused for staleness — which is correct and is the more specific
    # fact. Naming the current generation reaches the status check.
    assert code(P.resolve(bound(ctx.control), ref, gen(ref))) == "worker-not-open"
  end

  # ===================================================================== T.6
  test "T.6 · an open Worker that nothing occupies is refused", ctx do
    possess!(ctx)
    ref = ctx.worker["id"]

    ok!(Control.command(ctx.agent, :detach_worker, []), "occupancy")

    assert code(P.resolve(bound(ctx.control), ref, gen(ref))) == "worker-not-occupied"
  end

  # ===================================================================== T.7
  test "T.7 · an occupied Worker whose Carrier possesses no terminal is refused", ctx do
    # No `possess!/1` — the Carrier is running and holds no terminal.
    ref = ctx.worker["id"]
    assert code(P.resolve(bound(ctx.control), ref, gen(ref))) == "terminal-not-attached"
  end

  # ===================================================================== T.8
  test "T.8 · a presentation does not follow a replacement terminal", ctx do
    p0 = possess!(ctx)
    ref = ctx.worker["id"]
    {:ok, before} = P.resolve(bound(ctx.control), ref, gen(ref))

    assert P.current?(before)

    # Release the possession. The record the presentation was resolved from
    # is gone; a presentation that merely re-resolved would come back happy.
    _ = T.release(ctx.agent)
    refute P.current?(before), "the presentation survived the possession it names"

    # And a fresh possession is a DIFFERENT attachment incarnation, which the
    # old presentation must not adopt.
    _ = p0
    p1 = possess!(ctx)
    refute before["attachment_ref"] == p1.record["attachment_ref"]
    refute P.current?(before), "the presentation followed a replacement attachment"
  end

  # ===================================================================== T.9
  test "T.9 · nothing derived crosses to the page", ctx do
    possess!(ctx)
    ref = ctx.worker["id"]
    {:ok, p} = P.resolve(bound(ctx.control), ref, gen(ref))

    page = P.presentable(p)

    assert Map.keys(page) |> Enum.sort() ==
             ["schema", "worker_generation", "worker_ref"]

    # Asserted against the SERIALIZED payload, not the map, because a field
    # can be added to a struct and reach a wire without anyone editing the
    # list above.
    json = JSON.encode!(page)

    for forbidden <- ~w(peer_ref attachment_ref attachment_epoch pty_epoch
                        carrier_ref carrier_epoch peer_epoch locus_ref) do
      refute String.contains?(json, forbidden),
             "#{forbidden} crossed to the page: #{json}"
    end

    # And the values, not only the key names — an identity smuggled under a
    # different key is the same disclosure.
    for v <- [p["peer_ref"], p["attachment_ref"], p["attachment_epoch"], p["pty_epoch"]] do
      refute v != nil and String.contains?(json, v), "a derived identity crossed: #{json}"
    end
  end

  # ==================================================================== T.10
  test "T.10 · the policy's assumption — exactly one human-control role — still holds" do
    # **This test exists to expire.** The rule implemented here reads "the
    # unique human-control role may observe", and "unique" is what makes it
    # equivalent to "this person". If Super ever allows a second control
    # channel, the rule silently becomes "any human may watch any Worker",
    # which is a much larger claim than the one that was ruled.
    assert {:refused, r} = Peer.claim_control_channel()
    assert r["code"] == "control-channel-already-claimed"
  end

  # ==================================================================== T.11
  test "T.11 · world incarnation fencing still applies to the occupancy it rests on", ctx do
    possess!(ctx)
    ref = ctx.worker["id"]
    assert {:ok, _} = P.resolve(bound(ctx.control), ref, gen(ref))

    # Advancing the world ends every binding. Occupancy does not cross a
    # world discontinuity — `Ampd.Worker.still_standing/2` — so the
    # presentation cannot be resolved on the far side.
    {%{"generation" => _}, _} = Authority.advance_lineage("test-advance", %{})

    assert match?({:refused, _}, P.resolve(bound(ctx.control), ref, gen(ref))),
           "a presentation resolved across a world discontinuity"
  end

  # ==================================================================== T.12
  test "T.12 · the control plane discloses a status and never an identity", ctx do
    possess!(ctx)
    ref = ctx.worker["id"]

    assert P.status_of(Loci.worker(ref)) == "ACTIVE"

    _ = T.release(ctx.agent)
    assert P.status_of(Loci.worker(ref)) == "NONE"

    # The projected Worker carries the derived status and no terminal
    # identity, asserted against the serialized row.
    row = Worker.projected(Loci.workers())[ref]
    json = JSON.encode!(row)
    assert row["terminal"] in ["ACTIVE", "NONE"]

    for forbidden <- ~w(attachment_ref attachment_epoch pty_epoch peer_ref) do
      refute String.contains?(json, forbidden), "#{forbidden} is in the Worker projection"
    end
  end

  # ==================================================================== T.13
  test "T.13 · the generation is what makes the page's designation mean anything", ctx do
    # The falsifier for the freshness witness itself. Two designations of the
    # SAME `worker_ref` — one naming the incarnation the page saw, one naming
    # the current incarnation — must give different answers. With the
    # comparison removed they collapse into the same answer, and the page's
    # designation stops meaning anything at all: whatever it names, it gets
    # the position that exists now.
    possess!(ctx)
    ref = ctx.worker["id"]
    saw = gen(ref)

    ok!(Control.command(ctx.control, :close_worker, [ref]), "worker")
    ok!(Control.command(ctx.control, :reopen_worker, [ref]), "worker")

    now = gen(ref)
    refute now == saw, "close+reopen did not advance the generation"

    stale = P.resolve(bound(ctx.control), ref, saw)
    current = P.resolve(bound(ctx.control), ref, now)

    assert code(stale) == "worker-generation-stale"

    refute code(current) == "worker-generation-stale",
           "the current generation was refused as stale, so the comparison is inverted"

    refute code(stale) == code(current),
           "a stale designation and a current one gave the same answer — the generation " <>
             "comparison is not doing anything, and the page could name any incarnation"
  end
end
