defmodule Ampd.BoundaryTest do
  @moduledoc """
  The C1.1 transport acceptance battery, run against the semantics before
  the socket exists.

  Every test here was a defect first, reproduced on the BEAM before it was
  fixed. Four came out of a review that could read the source but not run
  it; the fifth came out of running it, and is worse than the version that
  was reported.
  """
  use ExUnit.Case, async: false
  alias Ampd.{Control, Authority, Core, GrantRegistry, Gateway, Peer, Refusal, Wire}

  defp fresh(actor \\ "kestrel") do
    Ampd.reset_demo()
    Ampd.attach_pair(actor)
  end

  # ------------------------------------------- a singular action, one object
  test "revoking Kestrel's grant leaves Mallory's alone" do
    {human, _k} = fresh()
    Authority.mint(%{"capability" => "github.repo.read", "actor" => "mallory"})

    kestrel_g =
      Enum.find(GrantRegistry.list(),
        &(&1["actor"] == "kestrel" and &1["capability"] == "github.repo.read" and &1["status"] == "active"))

    mallory_g =
      Enum.find(GrantRegistry.list(),
        &(&1["actor"] == "mallory" and &1["capability"] == "github.repo.read" and &1["status"] == "active"))

    assert Control.command(human, :revoke_grant, [kestrel_g["id"]])["revoked"] == kestrel_g["id"]

    # The whole defect in one assertion: `revoke_grant` took a *capability*
    # and revoked every actor's grant naming it, so an operator revoking the
    # row in front of them silently took someone else's.
    assert Enum.find(GrantRegistry.list(), &(&1["id"] == mallory_g["id"]))["status"] == "active",
           "revoking one actor's grant revoked another actor's"

    assert Enum.find(GrantRegistry.list(), &(&1["id"] == kestrel_g["id"]))["status"] == "revoked"
  end

  test "revoking a grant that is not there refuses instead of reporting success" do
    {human, _k} = fresh()
    r = Control.command(human, :revoke_grant, ["gr_nope"])
    refute r["allow"]
    assert r["refusal"]["code"] == "grant-unknown"
  end

  test "bulk revocation must be said on purpose, and must name the exact set" do
    {human, _k} = fresh()
    Authority.mint(%{"capability" => "github.repo.read", "actor" => "mallory"})
    scope = %{"capability" => "github.repo.read"}
    ids = GrantRegistry.matching(scope) |> Enum.map(& &1["id"]) |> Enum.sort()
    assert length(ids) == 2

    # Unscoped is refused outright, whatever set is offered.
    r = Control.command(human, :revoke_capability_domain, [%{}, ids])
    refute r["allow"]
    assert r["refusal"]["code"] == "bulk-scope-unbounded"

    # A set that is not what the scope matches is refused, naming the
    # difference in both directions rather than only that it changed.
    stale = Control.command(human, :revoke_capability_domain, [scope, [hd(ids)]])
    refute stale["allow"]
    assert stale["refusal"]["code"] == "bulk-scope-changed"
    assert stale["refusal"]["operator_detail"]["appeared"] == tl(ids)
    assert stale["refusal"]["operator_detail"]["gone"] == []
    assert stale["refusal"]["operator_detail"]["matches_now"] == ids

    # Nothing was revoked by the refusal.
    assert GrantRegistry.matching(scope) |> length() == 2

    # Said correctly, it does exactly what it says.
    ok = Control.command(human, :revoke_capability_domain, [scope, ids])
    assert ok["count"] == 2
    assert ok["revoked"] == ids
    assert GrantRegistry.matching(scope) == []
  end

  # **The defect a count could not detect.** Two grants disappear and two
  # appear between the render and the click; the count is still 2, and the
  # old confirmation passed. Reproduced before it was fixed: six shown, six
  # matched, and the set revoked contained a grant nobody had looked at.
  test "a bulk revocation confirmed by count alone revokes grants nobody saw" do
    {human, _k} = fresh()
    scope = %{"actor" => "kestrel"}

    shown = GrantRegistry.matching(scope) |> Enum.map(& &1["id"]) |> Enum.sort()
    assert length(shown) >= 2

    # The world moves. Same count, different set.
    Authority.revoke_one(List.last(shown))
    minted = Authority.mint(%{"capability" => "github.pr.create", "actor" => "kestrel"})
    now = GrantRegistry.matching(scope) |> Enum.map(& &1["id"]) |> Enum.sort()

    assert length(now) == length(shown), "the count must be unchanged or this proves nothing"
    assert now != shown
    assert minted["id"] in now
    refute minted["id"] in shown

    r = Control.command(human, :revoke_capability_domain, [scope, shown])
    refute r["allow"], "a stale confirmation revoked a set the operator never saw"
    assert r["refusal"]["code"] == "bulk-scope-changed"
    assert r["refusal"]["operator_detail"]["appeared"] == [minted["id"]]

    # The grant that was never confirmed is still active.
    assert Enum.find(GrantRegistry.list(), &(&1["id"] == minted["id"]))["status"] == "active"
  end

  # -------------------------------------------------------- duration is closed
  test "a duration this system cannot enforce is never minted" do
    {human, kestrel} = fresh()

    # Refused at **creation**, not at approval. A pending request that can
    # never become a valid grant is a trap with a human's click at the end
    # of it — and the guard that was supposed to catch it at approval was
    # silently open (see the nil-rank test below).
    q = Control.command(kestrel, :request_grant, ["github.pr.draft", "traaviis/trvm", %{"duration" => "forever"}])
    refute q["allow"]
    refute q["grant_request"], "an unenforceable duration must not create a durable request"
    assert q["refusal"]["code"] == "invalid-grant-duration"
    assert GrantRegistry.requests() == []

    # The agent is told the name of its mistake and nothing else — the
    # allowed set is topology. The operator pastes the same correlation id
    # and sees it. One stored object, two answers.
    refute q["refusal"]["operator_detail"]
    full = Control.command(human, :inspect_refusal, [q["refusal"]["correlation_id"]])
    assert full["refusal"]["operator_detail"]["allowed"] == ~w(once run agent workspace)

    # Nothing was written down.
    refute Enum.any?(GrantRegistry.list(), &(&1["duration"] == "forever"))


    # Nor through the raw mint path, nor the draft duration.
    assert {:refused, m} = Authority.mint(%{"capability" => "github.pr.draft", "duration" => "forever"})
    assert m["code"] == "invalid-grant-duration"
    assert {:refused, d} = Authority.set_dur("forever")
    assert d["code"] == "invalid-grant-duration"
  end

  # **The hole the widening guard could not close, because `nil` outranks
  # every integer.**
  #
  # `Core.duration_rank/1` returns `nil` outside the enum, and in Elixir's
  # term order numbers sort below atoms — so `rank("workspace") > nil` is
  # `false`, and the guard was silently open for *every* approval of a
  # malformed request, not merely the widening ones. Reproduced: a request
  # for `"forever"` approved as `"once"` minted a grant, and `"workspace"`
  # would have too.
  #
  # New requests can no longer carry one. This is the store written before
  # that rule existed — the case that has to be handled rather than
  # prevented, because it is already on disk.
  test "a malformed request already on disk cannot be approved into a grant" do
    {human, _k} = fresh()

    # The comparison the guard performs, in isolation, so what follows is
    # not mistaken for a claim about `>`.
    assert Core.duration_rank("workspace") > Core.duration_rank("forever") == false
    assert Core.duration_rank("forever") == nil

    legacy = %{"schema" => "grant-request@1", "id" => "gq_legacy", "status" => "pending",
               "actor" => "kestrel", "capability" => "github.pr.draft",
               "resource" => "traaviis/trvm", "requested_duration" => "forever"}

    Ampd.AuthorityCoordinator.transact(fn ->
      s = %{GrantRegistry.demo_state() | "requests" => [legacy]}
      GrantRegistry.load_state(s)
    end)

    assert Enum.find(GrantRegistry.requests(), &(&1["id"] == "gq_legacy"))

    # Every duration, including the ones that are narrower and would
    # therefore "pass" the ranking comparison.
    for attempt <- [nil, "once", "run", "agent", "workspace"] do
      r = Control.command(human, :approve_grant_request, ["gq_legacy", attempt])
      refute r["allow"], "approving a malformed request as #{inspect(attempt)} minted a grant"
      assert r["refusal"]["code"] == "invalid-grant-duration"
    end

    refute Enum.any?(GrantRegistry.list(), &(&1["duration"] == "forever"))
    assert Enum.find(GrantRegistry.requests(), &(&1["id"] == "gq_legacy"))["status"] == "pending"

    # Denying it is the way out, and it works.
    assert Control.command(human, :deny_grant_request, ["gq_legacy", "unenforceable duration"])
    assert Enum.find(GrantRegistry.requests(), &(&1["id"] == "gq_legacy"))["status"] == "denied"
  end

  # ------------------------------------------- consent binds to a contract
  test "a request cannot be approved after the pack it was asked under changed" do
    {human, kestrel} = fresh()

    before = Ampd.CapabilityRegistry.get("github")
    q = Control.command(kestrel, :request_grant, ["github.repo.read", "traaviis/trvm", %{}])["grant_request"]

    # The request records which contract it was asked under, not just a
    # capability name.
    assert q["pack"] == "github"
    assert q["pack_version"] == before["version"]
    assert q["pack_digest"] == Core.pack_digest(before)

    # The pack updates while the request sits pending: 1.5.0 adds a
    # capability and changes the surface the human is about to approve
    # against.
    Authority.update_github()
    assert Ampd.CapabilityRegistry.get("github")["version"] != before["version"]

    r = Control.command(human, :approve_grant_request, [q["id"]])
    refute r["allow"], "a request was approved against a contract that is not the one it asked about"
    assert r["refusal"]["code"] == "grant-request-stale"
    assert r["refusal"]["operator_detail"]["requested_under_version"] == before["version"]
    assert r["refusal"]["operator_detail"]["installed_version"] == "1.5.0"

    # Nothing was minted, and the request is still pending — a refused
    # approval must not consume the thing it refused.
    refute Enum.any?(GrantRegistry.list(),
             &(&1["capability"] == "github.repo.read" and &1["id"] not in demo_ids()))

    assert Enum.find(GrantRegistry.requests(), &(&1["id"] == q["id"]))["status"] == "pending"

    # Asking again, against the contract that is actually installed, works.
    q2 = Control.command(kestrel, :request_grant, ["github.repo.read", "traaviis/trvm", %{}])["grant_request"]
    assert Control.command(human, :approve_grant_request, [q2["id"]])["allow"]
  end

  test "a request made and approved under one unchanged pack is not called stale" do
    {human, kestrel} = fresh()
    q = Control.command(kestrel, :request_grant, ["github.pr.create", "traaviis/trvm", %{}])["grant_request"]

    # Installing a *different* pack is not a change to this one. Absence of
    # a reason to refuse is not a reason to refuse.
    Authority.install_postgres()
    assert Control.command(human, :approve_grant_request, [q["id"]])["allow"]
  end

  defp demo_ids, do: Enum.map(GrantRegistry.list(), & &1["id"]) |> Enum.take(3)

  test "a grant carrying an unenforceable duration is inert even if it exists" do
    fresh()

    # The scope check used to end in `_ -> true`, so this satisfied every
    # scope there is: it outlived its run, survived a workspace change, and
    # never spent a use. Constructed directly, because minting refuses now.
    g = %{"status" => "active", "capability" => "github.pr.draft", "actor" => "kestrel",
          "resource" => "traaviis/trvm", "duration" => "forever"}

    refute Core.duration_ok(g, Gateway.ctx(), fn _ -> false end),
           "an unenforceable duration satisfied the scope check"

    assert Core.duration_ok(%{g | "duration" => "agent"}, Gateway.ctx(), fn _ -> false end),
           "`agent` is the real fourth member and must still work"
  end

  test "approving may narrow a request, never widen it" do
    {human, kestrel} = fresh()

    q = Control.command(kestrel, :request_grant, ["github.pr.draft", "traaviis/trvm", %{"duration" => "once"}])
    id = q["grant_request"]["id"]

    wide = Control.command(human, :approve_grant_request, [id, "workspace"])
    refute wide["allow"]
    assert wide["refusal"]["code"] == "grant-widening-refused"
    assert wide["refusal"]["operator_detail"]["requested"] == "once"

    # Still pending — a refused approval must not consume the request.
    assert Enum.find(GrantRegistry.requests(), &(&1["id"] == id))["status"] == "pending"

    # Narrowing, or matching, is fine.
    ok = Control.command(human, :approve_grant_request, [id, "once"])
    assert ok["allow"]
    assert ok["granted"]["duration"] == "once"
    assert ok["granted"]["uses_remaining"] == 1
  end

  # ------------------------------------- installation confers zero authority
  # The hole has two ends and each is closed separately, so each is asserted
  # separately. A single test covering both would pass with either fix
  # disabled — which is exactly what the sabotage battery caught when this
  # was one test, and the reason it is now two.
  test "a grant for a merely DISCOVERED pack cannot be minted" do
    {_human, kestrel} = fresh()

    # postgres ships at installation:"available" and already declares its
    # whole surface — that is what makes it browsable.
    assert Ampd.CapabilityRegistry.get("postgres")["installation"] == "available"

    # Refused at request creation now, for the same reason the duration is:
    # `mint` was always going to refuse it, so the only thing a pending
    # request bought was a person clicking approve to find that out.
    q = Control.command(kestrel, :request_grant, ["postgres.schema.read", "db-main", %{}])
    refute q["allow"]
    refute q["grant_request"]
    assert q["refusal"]["code"] == "capability-undeclared"


    # And through the raw mint path, which is what stops the dormant grant
    # from existing at all: refusing it only at the gateway would leave it
    # on disk, waiting for the install that would activate it.
    assert {:refused, m} = Authority.mint(%{"capability" => "postgres.schema.read", "resource" => "db-main"})
    assert m["code"] == "capability-undeclared"
    assert GrantRegistry.matching(%{"capability" => "postgres.schema.read"}) == []

    # Installing the pack afterwards grants nothing, because nothing was
    # ever granted. That is the law, stated forwards.
    Authority.install_postgres()
    assert Ampd.CapabilityRegistry.get("postgres")["installation"] == "installed"
    a = Ampd.Conformance.authorize("postgres.schema.read", "db-main", Gateway.ctx(), nil)
    refute a["allow"]
    assert a["refusal"]["code"] == "authority-missing"
  end

  test "a grant that got in another way is still inert while its pack is discovered" do
    fresh()

    # An older store, a restored world, a hand-edited dets: the mint gate
    # cannot reach any of them, so the gateway has to hold on its own.
    # Loaded straight into the registry, bypassing mint entirely.
    st = Ampd.GrantRegistry.initial()

    forged = %{"id" => "gr_forged", "actor" => "kestrel", "capability" => "postgres.schema.read",
               "resource" => "db-main", "duration" => "workspace", "status" => "active",
               "placement" => ["local", "fleet"], "workspace" => "trvm", "run" => "run-b51"}

    Ampd.AuthorityCoordinator.transact(fn ->
      Ampd.GrantRegistry.load_state(%{st | "grants" => [forged]})
    end)

    assert Enum.any?(GrantRegistry.list(), &(&1["id"] == "gr_forged")), "the fixture did not land"

    r = Ampd.Conformance.authorize("postgres.schema.read", "db-main", Gateway.ctx(), nil)
    refute r["allow"], "a grant against a pack nobody installed authorized"
    assert r["refusal"]["code"] == "pack-not-installed"

    Ampd.reset_demo()
  end

  # ------------------------------------------------- the transition, not the command
  test "a sealed registry makes every mutating command answer with a refusal" do
    {human, kestrel} = fresh()
    g = Enum.find(GrantRegistry.list(), &(&1["capability"] == "github.pr.draft"))

    dir = Application.get_env(:ampd, :data_dir)
    GrantRegistry.close_store()
    File.rm_rf!(Path.join(dir, "grant_registry.dets"))
    Process.exit(Process.whereis(GrantRegistry), :kill)
    wait_sealed(GrantRegistry)

    # Each of these used to report success into a store that refused the
    # write. C1.1.0 kept a sealed registry alive precisely so it could
    # return a named refusal; the callers never looked at it.
    rev = Control.command(human, :revoke_grant, [g["id"]])
    refute rev["allow"], "a sealed revoke reported success"
    assert rev["refusal"]["code"] in ~w(recovery-state-missing grant-unknown)

    req = Control.command(kestrel, :request_grant, ["github.pr.draft", "traaviis/trvm", %{}])
    refute req["allow"]
    assert req["refusal"]["code"] == "recovery-state-missing"
    refute Map.has_key?(req, "grant_request"), "a sealed request reported a grant_request"

    # This one crashed rather than refusing.
    apr = Control.command(human, :approve_grant_request, ["gq_0001"])
    refute apr["allow"]
    assert is_binary(apr["refusal"]["code"])

    assert Process.alive?(Process.whereis(Ampd.AuthorityCoordinator))
    Ampd.reset_demo()
  end

  # ------------------------------------------------ redaction lives in one place
  test "every canonical refusal code has a decided agent projection" do
    # The policy is one function, so it can be enumerated. `public_code`
    # put it at each call site, where a caller forgetting it — or setting it
    # wrong — widened disclosure silently, and no test naming the *visible*
    # code could have caught it.
    codes = ~w(
      authority-missing actor-mismatch scope-mismatch one-shot-consumed run-expired
      workspace-mismatch capability-undeclared pack-not-installed denied-by-default
      placement-denied approval-required request-missing invalid-grant-duration
      grant-widening-refused grant-unknown grant-request-unknown bulk-scope-unbounded
      bulk-scope-changed recovery-state-missing recovery-state-untrusted orphaned-world
      world-meta-untrusted world-meta-unsupported world-meta-migration-required
      unordered-authority-mutation human-consent-required wrong-channel unknown-command
      unknown-peer refusal-unknown control-channel-already-claimed
      invalid-command-arguments invalid-peer-handle
    )

    hidden = Enum.filter(codes, &(Refusal.agent_code(&1) != &1))

    assert hidden == ["actor-mismatch"],
           "the set of codes an agent may not read changed: #{inspect(hidden)}"

    assert Refusal.agent_code("actor-mismatch") == "authority-missing"

    # And the field that used to carry it is gone, so it cannot be set wrong.
    r = Refusal.new("actor-mismatch", component: "t")
    refute Map.has_key?(r, "public_code")
    assert Refusal.project(r, :general)["code"] == "authority-missing"
    assert Refusal.project(r, :human_control)["code"] == "actor-mismatch"
  end

  # ------------------------------------------------------------ peer epoch
  # An INVARIANT CHECK, not a falsifier, and the difference is worth stating:
  # stubbing the epoch comparison out leaves this green, because a crashed
  # `Peer` comes back with an empty map and `Map.get/2` returns nil whatever
  # the handle says. The epoch is redundant today. It is there so fail-closed
  # stays true if this table ever gains a handoff or persistence path — and
  # insurance against a thing that does not exist yet cannot be falsified by
  # a test. `tools/sabotage.sh` says the same, and does not count it.
  test "a handle from a previous Peer incarnation can never resolve" do
    {_h, kestrel} = fresh()
    assert Peer.resolve(kestrel) != nil
    old_epoch = Peer.epoch()

    Process.exit(Process.whereis(Peer), :kill)
    wait_up(Peer)

    assert Peer.epoch() != old_epoch, "a new incarnation reused the old epoch"
    assert String.contains?(kestrel, old_epoch), "handles do not carry the epoch that minted them"
    assert Peer.resolve(kestrel) == nil, "a handle survived the incarnation that minted it"

    r = Control.command(kestrel, :agent_projection, [])
    refute r["allow"]
    assert r["refusal"]["code"] == "unknown-peer"

    # The control claim is free again, so the host can reattach.
    assert {:ok, _} = Peer.claim_control_channel()
  end

  # ------------------------------------------------------------ the wire
  test "the decoder is total over arbitrary input" do
    {_h, kestrel} = fresh()

    # Agent-legal command words only, so the arity path is actually
    # reached: the channel gate runs first, and `approve_effect` from an
    # agent is `human-consent-required` before its arity is ever looked at.
    hostile = [
      {"request_effect", []},
      {"request_effect", [1]},
      {"request_grant", []},
      {"inspect_refusal", []},
      {"preflight", 42},
      {"preflight", ["a", "b", "c", "d", "e", "f", "g", "h", "i"]},
      {"agent_projection", %{"not" => "a list"}},
      {"", []},
      {String.duplicate("x", 200), []},
      {"Elixir.System", ["halt"]},
      {"preflight", [String.duplicate("z", 70_000)]},
      {"preflight", [deep(20)]}
    ]

    for {word, args} <- hostile do
      r = Wire.command(kestrel, word, args)

      assert is_map(r), "#{inspect(word)} did not return a map"
      assert r["allow"] == false
      assert r["refusal"]["code"] in ~w(unknown-command invalid-command-arguments invalid-peer-handle),
             "#{inspect(word)} → #{inspect(r["refusal"]["code"])}"
      assert is_binary(r["refusal"]["correlation_id"])
    end

    # A non-binary command word is a refusal, not a crash.
    assert Wire.command(kestrel, :preflight, [])["refusal"]["code"] == "unknown-command"
    assert Wire.command(kestrel, 42, [])["refusal"]["code"] == "unknown-command"
  end

  test "the wire creates no atoms, whatever it is sent" do
    {_h, kestrel} = fresh()

    # One call first, so the modules this path touches are loaded. Loading a
    # module interns its own atoms exactly once; measuring across it would
    # blame the decoder for the VM's own bookkeeping.
    Wire.command(kestrel, "warmup", [])
    before = :erlang.system_info(:atom_count)

    for i <- 1..500 do
      Wire.command(kestrel, "no_such_command_#{i}", [])
    end

    assert :erlang.system_info(:atom_count) == before,
           "the decoder interned atoms from wire input — the atom table has a hard ceiling " <>
             "and is never collected, so this is a denial of service that outlives the connection"
  end

  test "a well-formed wire command reaches the same answer as the internal one" do
    {human, kestrel} = fresh()

    a = Wire.command(kestrel, "agent_projection", [])
    b = Control.command(kestrel, :agent_projection, [])
    assert a["actor"] == b["actor"] and a["schema"] == b["schema"]

    # And the channel table still holds through the wire.
    r = Wire.command(kestrel, "revoke_grant", ["gr_0193"])
    assert r["refusal"]["code"] == "human-consent-required"

    assert Wire.command(human, "operator_projection", [])["schema"] == "operator-projection@2"
    assert Wire.command(nil, "runtime_status", [])["status"] == "healthy"
  end

  test "the wire vocabulary is exactly the command surface" do
    words = Wire.vocabulary() |> Map.values() |> MapSet.new()

    declared =
      (Control.agent_commands() ++ Control.human_commands() ++ Control.open_commands())
      |> MapSet.new()

    assert words == declared,
           "the wire vocabulary and the command tables drifted: #{inspect(MapSet.symmetric_difference(words, declared))}"
  end

  # ----------------------------------------------------------------- helpers
  defp deep(0), do: "x"
  defp deep(n), do: %{"d" => deep(n - 1)}

  defp wait_sealed(mod, n \\ 100)
  defp wait_sealed(_mod, 0), do: flunk("registry never sealed")

  defp wait_sealed(mod, n) do
    if Process.whereis(mod) != nil and (try do mod.sealed() != nil catch :exit, _ -> false end),
      do: :ok,
      else: (Process.sleep(20); wait_sealed(mod, n - 1))
  end

  defp wait_up(mod, n \\ 100)
  defp wait_up(_mod, 0), do: flunk("process did not come back")

  defp wait_up(mod, n) do
    alive =
      Process.whereis(mod) != nil and
        (try do
           Peer.epoch()
           true
         catch
           :exit, _ -> false
         end)

    if alive, do: :ok, else: (Process.sleep(20); wait_up(mod, n - 1))
  end
end
