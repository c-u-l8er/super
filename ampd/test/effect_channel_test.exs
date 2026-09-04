defmodule Ampd.EffectChannelTest do
  @moduledoc """
  **D.1.3a's falsifiers.** The proposition, restated as something a machine
  can refuse:

      The trusted machine-effect mechanism is reachable through possession
      of a private channel rather than through an ambient executable name,
      and no authorization moved across that boundary.

  **Possession-addressed, not unforgeable.** See
  `Ampd.Worktree.EffectChannel` for why the weaker word is the accurate
  one: knowing a name is proved insufficient; resisting a hostile same-UID
  process is not proved and is not claimed.

  ## What the harness is, stated so nothing here is over-read

  `Host` plays the host end of a real socketpair. It is a stand-in for the
  Rust host's `effect::perform`, not a mock of the channel: the socket is
  a real `AF_UNIX` pair, the framing is the runtime's own four-byte
  prefix, `close` really delivers EOF, and the success paths run real
  `git worktree add`. What it is *not* is the production host process.

  **The production host now serves this channel too** — `super-host run`
  creates the pair and `serve_effects` answers out of `effect::perform`,
  proved end-to-end in `super-host verify`. These falsifiers keep the
  harness because fault injection needs an endpoint that can be told to
  die at a chosen instant, which a real host is not. The positive
  production path is proved over there; the fault matrix is proved here.

  The distinction that matters for every falsifier below: **`ampd` reaching
  the mechanism by possession is the property under test.** The harness is
  allowed to be the host, and the host is allowed to run git.

  ## Three-part rule, unchanged from D.1.1 and D.1.2

  A negative test asserts the call was refused, refused **by the expected
  name**, and that the world is **unchanged**. The third is the only one
  that can tell a real refusal from a failure for an unrelated reason.
  """

  use ExUnit.Case, async: false

  alias Ampd.{Authority, Bridge, Control, Loci, Locus, Peer, Receipts, Transport, Worktree}
  alias Ampd.Worktree.EffectChannel

  # ==================================================================
  # The host end of the channel.
  # ==================================================================
  defmodule Host do
    @moduledoc false
    # A process holding the far end of a socketpair, framing exactly as the
    # runtime does, with a scriptable reply policy. `requests` is the
    # falsifier for "did not merely receive and reject" — C10 asserts it is
    # empty, and C7 asserts it is exactly one.
    use GenServer

    def start(sock, policy), do: GenServer.start(__MODULE__, {sock, policy}, [])

    @doc "Every request this endpoint actually received, oldest first."
    def requests(h), do: GenServer.call(h, :requests, 10_000)

    @doc "Stop serving and close the socket — EOF for the other end."
    def close(h), do: GenServer.call(h, :close, 10_000)

    @impl true
    def init({sock, policy}) do
      me = self()
      reader = spawn_link(fn -> read_loop(sock, me) end)
      {:ok, %{sock: sock, policy: policy, seen: [], reader: reader}}
    end

    @impl true
    def handle_call(:requests, _f, st), do: {:reply, Enum.reverse(st.seen), st}

    def handle_call(:close, _f, st) do
      Process.unlink(st.reader)
      Process.exit(st.reader, :kill)
      :socket.close(st.sock)
      {:reply, :ok, %{st | sock: nil}}
    end

    @impl true
    def handle_info({:req, req}, st) do
      st = %{st | seen: [req | st.seen]}

      case st.policy.(req, length(st.seen)) do
        :no_reply -> {:noreply, st}
        :close -> {:noreply, close_now(st)}
        {:reply, obs} -> {:noreply, write(st, obs)}
        {:reply_then_close, obs} -> {:noreply, st |> write(obs) |> close_now()}
      end
    end

    def handle_info(_, st), do: {:noreply, st}

    defp close_now(st) do
      Process.unlink(st.reader)
      Process.exit(st.reader, :kill)
      if st.sock, do: :socket.close(st.sock)
      %{st | sock: nil}
    end

    defp write(%{sock: nil} = st, _), do: st

    defp write(st, obs) do
      body = Ampd.Core.canon(obs)
      :socket.send(st.sock, <<byte_size(body)::big-32>> <> body)
      st
    end

    defp read_loop(sock, owner) do
      with {:ok, <<n::big-32>>} <- :socket.recv(sock, 4),
           {:ok, body} <- :socket.recv(sock, n) do
        send(owner, {:req, :json.decode(body)})
        read_loop(sock, owner)
      else
        _ -> :ok
      end
    end
  end

  # ==================================================================
  setup do
    Ampd.reset()
    Bridge.reset()
    Peer.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.delete_env(:ampd, :worktree_effector)
    Process.sleep(120)
    Authority.install_worktree()

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "reach the mechanism"]), "goal")
    lane = ok!(Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]), "lane")

    w = ok!(Control.command(control, :open_worker, [lane["id"], "implement"]), "worker")
    ok!(Control.command(agent, :attach_worker, [w["id"]]), "worker")

    on_exit(fn -> Application.delete_env(:ampd, :worktree_effector) end)

    %{repo: repo, control: control, agent: agent, lane: lane, worker: w}
  end

  # ==================================================================== C1
  describe "C1 · the production effect resolves no executable by name" do
    test "a worktree is created while the host binary path is nonsense", ctx do
      {h, _inc} = channel!(perform_policy())
      grant!(ctx.lane["id"])

      # The ambient name is not merely unused — it is actively broken. If
      # anything on this path still resolved and executed it, this would
      # fail rather than pass quietly.
      prior = System.get_env("SUPER_HOST_BIN")
      System.put_env("SUPER_HOST_BIN", "/nonexistent/definitely-not-a-host")

      on_exit(fn ->
        # Restoring *absence* matters as much as restoring a value: leaving
        # the sabotage set makes `C2` pass for the wrong reason, which is
        # how a falsifier quietly stops falsifying anything.
        if prior, do: System.put_env("SUPER_HOST_BIN", prior), else: System.delete_env("SUPER_HOST_BIN")
      end)

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c1"])
      assert r["allow"] == true, "the channel effect failed: #{inspect(r["refusal"])}"

      assert [req] = Host.requests(h)
      assert req["schema"] == "worktree-effect-request@1"
      assert File.dir?(Path.join(Worktree.root(), "wt-c1"))
    end

    test "the channel effector's source contains no execution site" do
      # **Code only.** The moduledoc names the old path in order to say
      # what was replaced, and a grep over the whole file would fail on
      # the explanation rather than on the behaviour — which is a
      # falsifier that punishes documentation. Docstrings and comments are
      # stripped first, so what is left is what runs.
      src = code_only(File.read!("lib/ampd/worktree/effect_channel.ex"))

      for forbidden <- ["Port.open", "System.cmd", ":os.cmd", "spawn_executable", "find_executable"] do
        refute src =~ forbidden,
               "the channel effector reaches a program by name: #{forbidden}"
      end

      # And the stripper is not trusted either: it must still be able to
      # see the execution site in the effector that genuinely has one.
      assert code_only(File.read!("lib/ampd/worktree/effector.ex")) =~ "Port.open",
             "the comment stripper removed real code — this falsifier proves nothing"
    end
  end

  # ==================================================================== C2
  describe "C2 · possession, not naming" do
    test "knowing the host binary path without the channel produces no effect", ctx do
      # No channel is bound. The binary genuinely exists and is executable,
      # so the only thing missing is possession.
      assert Bridge.effect_endpoint() == nil
      assert File.exists?(Ampd.Worktree.Effector.Host.binary()),
             "this falsifier is vacuous unless the named binary is really there"

      use_channel_effector!()
      grant!(ctx.lane["id"])
      before = footprint()

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c2"])
      assert r["allow"] == false
      assert r["refusal"]["code"] == "worktree-create-failed"

      # The reason is topology and the agent does not get it — the same
      # projection rule the absent-binary refusal obeys.
      refute Map.has_key?(r["refusal"], "operator_detail")

      logged = Enum.find(Ampd.RefusalLog.recent(20), &(&1["code"] == "worktree-create-failed"))

      assert logged["operator_detail"]["reason"] =~ "no host effect channel is possessed",
             "the refusal must name the missing possession, not a missing pathname"

      refute logged["operator_detail"]["reason"] =~ "super-host",
             "a possession failure that names an executable is still reasoning about names"

      assert footprint().receipts == before.receipts
      assert footprint().active_caps == before.active_caps
      refute File.dir?(Path.join(Worktree.root(), "wt-c2"))
    end
  end

  # ==================================================================== C3
  describe "C3 · the Worker is handed no endpoint" do
    test "no descriptor, socket or epoch appears anywhere a Worker can see", ctx do
      {_h, inc} = channel!(perform_policy())
      grant!(ctx.lane["id"])
      ok!(Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c3"]), "resource")

      %{sock: sock} = Bridge.effect_endpoint()
      fd = Transport.fd_of(sock)
      epoch = inc["channel_epoch"]

      surfaces = %{
        "worker record" => Loci.workers(),
        "attachment" => Peer.attachment(ctx.agent),
        "attach reply" => Control.command(ctx.agent, :attach_worker, [ctx.worker["id"]]),
        "agent projection" => Control.command(ctx.agent, :agent_projection, []),
        "operator projection" => Control.command(ctx.control, :operator_projection, []),
        "caps" => Loci.caps(),
        "receipts" => Receipts.all(),
        "resources" => Worktree.resources()
      }

      for {name, term} <- surfaces do
        keys = every_key(term)

        for forbidden <- ~w(channel_epoch effect_endpoint effect_channel fd descriptor socket
                            endpoint sock request_id) do
          refute forbidden in keys, "#{name} carries a channel field: #{forbidden}"
        end

        vals = every_value(term)
        refute epoch in vals, "#{name} leaks the channel epoch"
        refute fd in vals, "#{name} leaks the raw descriptor number"

        refute Enum.any?(vals, &match?({:"$socket", _}, &1)),
               "#{name} leaks a socket handle"
      end
    end
  end

  # ==================================================================== C4
  describe "C4 · an observation cannot cross an incarnation" do
    test "a reply stamped with a prior epoch is never accepted", ctx do
      # The endpoint answers with a well-formed, successful observation for
      # the right request — carrying the wrong incarnation.
      stale = EffectChannel.new_epoch()

      {h, _inc} =
        channel!(fn req, _n ->
          {:reply, observation(req, stale, "0000000000000000000000000000000000000000")}
        end)

      grant!(ctx.lane["id"])
      before = footprint()

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c4"])
      assert r["allow"] == false
      assert r["refusal"]["code"] == "worktree-create-failed"

      # It was received — this is not a test that the message never arrived.
      assert length(Host.requests(h)) == 1
      assert footprint().receipts == before.receipts
      assert indeterminate?("wt-c4"), "a rejected cross-incarnation reply must not commit"
    end

    test "rebinding mints a new epoch and the old one stops being current" do
      {_h1, inc1} = channel!(perform_policy())
      assert EffectChannel.current_incarnation()["channel_epoch"] == inc1["channel_epoch"]

      {_h2, inc2} = channel!(perform_policy())
      refute inc2["channel_epoch"] == inc1["channel_epoch"]
      assert EffectChannel.current_incarnation()["channel_epoch"] == inc2["channel_epoch"]
    end
  end

  # ==================================================================== C5
  describe "C5 · two requests do not accept each other's observations" do
    test "swapped observations satisfy neither request" do
      # Both replies are well-formed and carry the right epoch. The only
      # thing wrong with either is which request it names.
      {h, _inc} =
        channel!(fn req, n ->
          other = if n == 1, do: "req-two-placeholder", else: "req-one-placeholder"
          {:reply, req |> observation(req["channel_epoch"], "deadbeef") |> Map.put("request_id", other)}
        end)

      t1 = Task.async(fn -> EffectChannel.submit(base_request("c5-a"), 1_500) end)
      t2 = Task.async(fn -> EffectChannel.submit(base_request("c5-b"), 1_500) end)

      assert {:error, _} = Task.await(t1, 5_000)
      assert {:error, _} = Task.await(t2, 5_000)
      assert length(Host.requests(h)) == 2

      ids = Host.requests(h) |> Enum.map(& &1["request_id"])
      assert length(Enum.uniq(ids)) == 2, "each submission must mint its own request_id"
    end
  end

  # ==================================================================== C6
  describe "C6 · the channel dies before the effect" do
    test "nothing is committed and no capability goes active", ctx do
      {h, _inc} = channel!(fn _req, _n -> :close end)
      grant!(ctx.lane["id"])
      before = footprint()

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c6"])
      assert r["allow"] == false
      assert r["refusal"]["code"] == "worktree-create-failed"

      assert length(Host.requests(h)) == 1
      assert footprint().receipts == before.receipts
      assert footprint().active_caps == before.active_caps
      refute File.dir?(Path.join(Worktree.root(), "wt-c6"))
      assert indeterminate?("wt-c6")
    end
  end

  # ==================================================================== C7
  describe "C7 · the channel dies after the effect may have happened" do
    test "the record is INDETERMINATE and the effect is never replayed", ctx do
      # The harness performs the real git effect and then dies without
      # answering — the exact shape that tempts a runtime to retry.
      {h, _inc} =
        channel!(fn req, _n ->
          _ = real_effect(req)
          :close
        end)

      grant!(ctx.lane["id"])
      before = footprint()

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c7"])
      assert r["allow"] == false

      # **The effect really happened.** This falsifier is worthless if it
      # did not, because then "no replay" is trivially true.
      assert File.dir?(Path.join(Worktree.root(), "wt-c7")),
             "the harness did not actually perform the effect"

      # Exactly one submission. Not two.
      assert length(Host.requests(h)) == 1, "the effect was resubmitted after channel loss"

      assert indeterminate?("wt-c7")
      assert footprint().receipts == before.receipts
      assert footprint().active_caps == before.active_caps
    end

    test "a wrong answer on a live channel is not retried", ctx do
      # **The replay shape a live channel can actually reach**, and the one
      # the first C7 case cannot test: there, the endpoint is dead, so a
      # resubmission has nowhere to land and the request count stays 1 for
      # a reason that has nothing to do with policy. Here the endpoint
      # stays up and keeps answering wrongly, so a runtime that responded
      # to a bad answer by asking again would be visible immediately.
      {h, _inc} =
        channel!(fn req, _n ->
          _ = real_effect(req)
          {:reply, req |> observation(req["channel_epoch"], "cafe") |> Map.put("request_id", "not-yours")}
        end)

      grant!(ctx.lane["id"])

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c7c"])
      assert r["allow"] == false

      assert File.dir?(Path.join(Worktree.root(), "wt-c7c")),
             "the harness did not actually perform the effect"

      assert length(Host.requests(h)) == 1,
             "a mis-correlated observation caused the effect to be submitted again"

      assert indeterminate?("wt-c7c")
    end

    test "binding a replacement channel does not resubmit anything", ctx do
      {h1, _} = channel!(fn req, _n -> _ = real_effect(req); :close end)
      grant!(ctx.lane["id"])
      Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c7b"])
      assert length(Host.requests(h1)) == 1

      # A fresh incarnation arrives. Nothing about that is evidence.
      {h2, _} = channel!(perform_policy())
      Process.sleep(200)

      assert Host.requests(h2) == [],
             "a replacement channel inherited in-flight work and replayed it"

      assert indeterminate?("wt-c7b")
    end
  end

  # ==================================================================== C8
  describe "C8 · a replacement channel does not inherit a pending request" do
    test "a reply on the new epoch cannot answer a request from the old one" do
      {h1, inc1} = channel!(fn _req, _n -> :no_reply end)

      t = Task.async(fn -> EffectChannel.submit(base_request("c8"), 1_200) end)
      Process.sleep(150)
      assert length(Host.requests(h1)) == 1

      {_h2, inc2} = channel!(perform_policy())
      refute inc1["channel_epoch"] == inc2["channel_epoch"]

      # The pending submission is bound to the epoch it was made under and
      # dies with it. It does not migrate.
      assert {:error, _} = Task.await(t, 5_000)
    end
  end

  # ==================================================================== C9
  describe "C9 · parity with the frozen reference effector" do
    test "the channel and the in-process effector produce the same worktree", ctx do
      grant!(ctx.lane["id"])

      # Reference path.
      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Git)
      Ampd.Embodiment.refresh()
      ok!(Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-ref"]), "resource")
      Application.delete_env(:ampd, :worktree_effector)

      # Channel path. A new grant, because switching effectors changes
      # `profile_basis` and every capability established under the old one
      # correctly stops being exercisable — F10.
      {_h, _inc} = channel!(perform_policy())
      grant!(ctx.lane["id"])
      ok!(Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-chan"]), "resource")

      ref_dir = Path.join(Worktree.root(), "wt-ref")
      chan_dir = Path.join(Worktree.root(), "wt-chan")

      assert File.dir?(ref_dir) and File.dir?(chan_dir)
      assert head_of(ref_dir) == head_of(chan_dir), "the two effectors resolved different commits"

      assert listing(ref_dir) == listing(chan_dir),
             "the two effectors materialised different contents"
    end
  end

  # =================================================================== C10
  describe "C10 · authority stays above the mechanism" do
    test "with no grant the host is never asked", ctx do
      {h, _inc} = channel!(perform_policy())
      # Deliberately no grant.
      before = footprint()

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c10a"])
      assert r["allow"] == false
      assert r["refusal"]["code"] == "worktree-authority-missing"

      # **Not "received and rejected".** The mechanism never saw it.
      assert Host.requests(h) == [], "an unauthorized request reached the mechanism"
      assert footprint() == before
    end

    test "an unattached Carrier is refused before the mechanism", ctx do
      {h, _inc} = channel!(perform_policy())
      grant!(ctx.lane["id"])
      ok!(Control.command(ctx.agent, :detach_worker, []), "worker")

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c10b"])
      assert r["allow"] == false
      assert r["refusal"]["code"] == "carrier-not-attached"
      assert Host.requests(h) == []
    end

    test "a revoked grant is refused before the mechanism", ctx do
      {h, _inc} = channel!(perform_policy())
      g = grant!(ctx.lane["id"])
      Authority.revoke_one(g["id"] || g["grant_id"])

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c10c"])
      assert r["allow"] == false
      assert Host.requests(h) == [], "a revoked grant reached the mechanism"
    end
  end

  # =================================================================== C11
  describe "C11 · the channel adds no durable authority" do
    test "the store count is unchanged and no store mentions the channel" do
      assert length(Ampd.World.authority_stores()) == 8

      {_h, inc} = channel!(perform_policy())
      epoch = inc["channel_epoch"]

      assert length(Ampd.World.authority_stores()) == 8

      for store <- Ampd.World.authority_stores() do
        path = Path.join(Ampd.Store.data_dir(), "#{store}.dets")

        if File.exists?(path) do
          refute File.read!(path) =~ epoch,
                 "the channel epoch reached the durable store #{store}"
        end
      end
    end

    test "the incarnation dies with the world" do
      {_h, _inc} = channel!(perform_policy())
      assert EffectChannel.current_incarnation() != nil

      Bridge.reset()
      assert EffectChannel.current_incarnation() == nil,
             "a possessed mechanism survived the world it was bound to"
    end
  end

  # =================================================================== C12
  describe "C12 · losing the channel cannot widen authority" do
    test "replacing the endpoint creates, refreshes and revalidates nothing", ctx do
      {_h, _inc} = channel!(perform_policy())
      grant!(ctx.lane["id"])
      before = footprint()
      caps_before = Loci.caps()

      Bridge.drop_effect_endpoint()
      {_h2, _inc2} = channel!(perform_policy())
      Bridge.drop_effect_endpoint()
      {_h3, _inc3} = channel!(perform_policy())

      assert footprint().active_caps == before.active_caps
      assert footprint().receipts == before.receipts

      assert Loci.caps() == caps_before,
             "a channel replacement mutated the capability table"
    end
  end

  # =================================================================== C13
  describe "C13 · there is no ambient production fallback" do
    test "the unconfigured default effector is the channel, not a named one" do
      # The test environment *selects* the reference effector in
      # config/config.exs. This asserts what the runtime does when nobody
      # has selected anything — which is what a deployed Super does.
      prior = Application.get_env(:ampd, :worktree_effector)
      Application.delete_env(:ampd, :worktree_effector)

      on_exit(fn ->
        if prior, do: Application.put_env(:ampd, :worktree_effector, prior)
      end)

      assert Ampd.Worktree.Effector.current() == Ampd.Worktree.Effector.Channel,
             "a deployed runtime would reach the mechanism by resolving a pathname"
    end

    test "neither SUPER_HOST_BIN nor PATH can make the production path exec by name", ctx do
      use_channel_effector!()
      grant!(ctx.lane["id"])
      assert Bridge.effect_endpoint() == nil

      # Point both ambient names at a real, working host binary. If any
      # fallback existed, this is precisely the configuration under which
      # it would fire — and the effect would succeed.
      prior_bin = System.get_env("SUPER_HOST_BIN")
      prior_path = System.get_env("PATH")
      real = Ampd.Worktree.Effector.Host.binary()
      System.put_env("SUPER_HOST_BIN", real)
      System.put_env("PATH", Path.dirname(real) <> ":" <> (prior_path || ""))

      on_exit(fn ->
        if prior_bin,
          do: System.put_env("SUPER_HOST_BIN", prior_bin),
          else: System.delete_env("SUPER_HOST_BIN")

        if prior_path, do: System.put_env("PATH", prior_path)
      end)

      before = footprint()
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c13"])

      assert r["allow"] == false,
             "a reachable host binary revived the named path when no channel was possessed"

      assert footprint() == before
      refute File.dir?(Path.join(Worktree.root(), "wt-c13"))
    end
  end

  # =================================================================== C14
  describe "C14 · machine latency cannot raise inside the total order" do
    test "every mechanism wait is strictly inside the deadline that encloses it" do
      # Read off the modules that own them, not typed here. A chain
      # maintained by hand is a chain that drifts; this one fails. It was
      # four numbers and is five — see `identity` below.
      channel = Ampd.Worktree.EffectChannel.deadline_ms()
      named = Ampd.Worktree.Effector.Host.deadline_ms()
      call = Ampd.Worktree.call_deadline_ms()
      budget = Ampd.AuthorityCoordinator.budget_ms()

      # **The fifth number, and it was 30_000 under a 15_000 budget.**
      # `Ampd.Embodiment.identity/0` is reachable from inside a transaction —
      # `Ampd.Carrier.admit_start/2` → `Ampd.Locus.profile_digest/0` →
      # `Ampd.Worktree.Effector.identity/0` → here — and this chain never read
      # it, so the one wait in the tree that outlived its own budget was the
      # one nothing checked. Found by the C1.0b·2·1 reachability census.
      identity = Ampd.Embodiment.identity_deadline_ms()

      assert channel < call,
             "the channel outlives the call that encloses it: #{channel} >= #{call}"

      assert named < call,
             "the named effector outlives the call that encloses it: #{named} >= #{call}"

      assert call < budget,
             "the effect call outlives its transaction budget: #{call} >= #{budget}"

      # Margin, not merely ordering. A chain that fits by a millisecond is
      # one scheduler hiccup away from the defect it is meant to close.
      assert identity < budget,
             "the embodiment measurement outlives the transaction that encloses it: " <>
               "#{identity} >= #{budget}"

      assert budget - call >= 2_000, "less than 2s of margin under the transaction budget"
      assert budget - identity >= 2_000, "less than 2s of margin for the embodiment measurement"

      # The embodiment handler is not a leaf: it reaches `Ampd.Bridge` through
      # the effect channel, so its own deadline encloses `channel` and at
      # 10_000 it exactly equalled it. Per wait, not per handler — the sum of
      # the two waits that handler can make exceeds the budget itself, and
      # what bounds that is this deadline rather than any arithmetic on it.
      assert channel < identity,
             "the embodiment deadline does not clear the channel wait: #{channel} >= #{identity}"

      assert identity - channel >= 2_000, "less than 2s of margin over the channel wait"
      assert call - channel >= 1_000, "less than 1s of margin under the effect call"
    end

    test "a mechanism that never answers yields a typed record, not a raised transaction", ctx do
      # The endpoint receives the request and says nothing, ever. Before the
      # bound this raised out of the coordinator; now it must come back as
      # an ordinary refusal with the record left INDETERMINATE.
      {h, _inc} = channel!(fn _req, _n -> :no_reply end)
      grant!(ctx.lane["id"])

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "wt-c14"])

      assert r["allow"] == false
      assert r["refusal"]["code"] == "worktree-create-failed"
      assert length(Host.requests(h)) == 1
      assert indeterminate?("wt-c14")

      # And the runtime is still serving — a raised transaction would have
      # taken the coordinator's caller down with it, and the next command
      # would time out rather than answer.
      proj = Control.command(ctx.control, :operator_projection, [])
      assert is_map(proj) and proj["refusal"] == nil, "the coordinator did not survive: #{inspect(proj)}"
      assert is_map(proj["projection"]) or is_map(proj["result"]) or map_size(proj) > 0
    end
  end

  # ==================================================================
  # helpers
  # ==================================================================
  defp channel!(policy) do
    {ampd_end, host_end} = Transport.socketpair(:stream)
    {:ok, h} = Host.start(host_end, policy)

    inc = EffectChannel.incarnation(EffectChannel.new_epoch(), host_identity())
    {:ok, ^inc} = Bridge.bind_effect_endpoint(ampd_end, inc)

    use_channel_effector!()
    {h, inc}
  end

  defp use_channel_effector! do
    Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Channel)
    Ampd.Embodiment.refresh()
  end

  # What a host says about itself when the channel is established. Shaped
  # like the real `host-identity@1` so the embodiment check upstream is
  # exercised rather than bypassed.
  defp host_identity do
    %{
      "schema" => "host-identity@1",
      "resolved" => true,
      "effect_protocol_version" => Ampd.Worktree.Effector.protocol_version(),
      "host_binary" => %{"resolved" => true, "sha256" => "harness", "bytes" => 0},
      "git" => %{"resolved" => true, "sha256" => "harness", "version" => "harness"}
    }
  end

  # The default policy: do the real thing and answer correctly.
  defp perform_policy do
    fn req, _n ->
      case real_effect(req) do
        {:ok, head} -> {:reply, observation(req, req["channel_epoch"], head)}
        {:error, why} -> {:reply, refusal_observation(req, why)}
      end
    end
  end

  # The harness standing in for the host's `effect::perform`.
  defp real_effect(req) do
    args = ["-C", req["repo_path"], "worktree", "add", "--detach", req["target"], req["revision"]]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, head_of(req["target"])}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp observation(req, epoch, head) do
    %{
      "schema" => "worktree-effect-observation@1",
      "request_id" => req["request_id"],
      "channel_epoch" => epoch,
      "ok" => true,
      "head" => head,
      "observed_dir" => true,
      "confinement" => %{"note" => "harness"},
      "identity" => host_identity()
    }
  end

  defp refusal_observation(req, why) do
    %{
      "schema" => "worktree-effect-observation@1",
      "request_id" => req["request_id"],
      "channel_epoch" => req["channel_epoch"],
      "ok" => false,
      "reason" => why,
      "confinement" => %{"note" => "harness"}
    }
  end

  defp base_request(name) do
    %{
      "op" => "create",
      "repo_path" => "/nonexistent-repo",
      "target" => Path.join(Worktree.root(), name),
      "revision" => "HEAD"
    }
  end

  defp grant!(lane_id) do
    g =
      Authority.mint(%{
        "capability" => Locus.create_capability(),
        "resource" => lane_id,
        "actor" => "kestrel",
        "duration" => "workspace"
      })

    refute match?({:refused, _}, g), "the grant was refused: #{inspect(g)}"
    g
  end

  defp indeterminate?(name) do
    Worktree.resources()
    |> Enum.any?(fn {_, r} -> r["name"] == name and r["state"] == "INDETERMINATE" end)
  end

  defp head_of(dir) do
    case System.cmd("git", ["-C", dir, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp listing(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.reject(&String.starts_with?(&1, ".git"))
    |> Enum.sort()
  end

  defp footprint do
    %{
      receipts: length(Receipts.all()),
      active_caps: Loci.caps() |> Enum.count(fn {_, c} -> c["status"] == "active" end)
    }
  end

  # Every key anywhere in a term — the recursive walk `D2-11` uses, because
  # a nested object inherits every disclosure rule of the record it is in.
  defp every_key(t) when is_map(t) do
    Enum.flat_map(t, fn {k, v} ->
      [to_string_safe(k) | every_key(v)]
    end)
  end

  defp every_key(t) when is_list(t), do: Enum.flat_map(t, &every_key/1)
  defp every_key({a, b}), do: every_key(a) ++ every_key(b)
  defp every_key(_), do: []

  defp every_value(t) when is_map(t), do: Enum.flat_map(t, fn {_, v} -> [v | every_value(v)] end)
  defp every_value(t) when is_list(t), do: Enum.flat_map(t, &[&1 | every_value(&1)])
  defp every_value({a, b}), do: [a, b | every_value(a) ++ every_value(b)]
  defp every_value(_), do: []

  # Drop `#` comments and `"""` heredocs, leaving only lines that execute.
  # Crude on purpose: it must be obviously right rather than clever, and
  # the test above proves it did not eat real code.
  defp code_only(src) do
    src
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_doc} ->
      cond do
        in_doc -> {acc, not String.contains?(line, ~s(""")) }
        String.contains?(line, ~s(""")) -> {acc, true}
        true -> {[String.replace(line, ~r/#.*$/, "") | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp to_string_safe(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_safe(k) when is_binary(k), do: k
  defp to_string_safe(k), do: inspect(k)

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key} to be allowed, got: #{inspect(Map.take(result, ["allow", "refusal"]))}"

    result[key]
  end

  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo-d13a")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "d13a\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "d13a@example.invalid"],
          ["config", "user.name", "D13a"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "git #{inspect(args)} failed: #{out}"
    end

    dir
  end
end
