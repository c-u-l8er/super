defmodule Ampd.LocusTest do
  @moduledoc """
  **D.1.1's falsifiers.** The success criterion, restated as something a
  machine can refuse:

      A Lane occupies an established position in a persistent governed
      structure. That position admits specific authority over a real
      machine resource. The current execution Carrier may disappear
      without destroying the semantic Locus, and a replacement Carrier
      receives no authority except that which can be legitimately
      re-established from the Locus's current basis.

  Every clause has a test below that fails if the clause is false.

  ## What makes these falsifiers rather than assertions

  Each negative case checks **three** things, not one:

      the call was refused
      it was refused *by the expected name*
      the world is unchanged — no directory, no receipt, no live cap

  Only the third distinguishes a real refusal from a call that failed for
  an unrelated reason and happened to return an error. W.1.4.2 shipped a
  case that asserted an exit code and would have passed whether or not the
  check under it ran; the shape is easy to repeat and expensive to notice.

  The positive path is exercised against a **real git repository** with a
  **real `git worktree add`**. A battery that mocked the effector would
  prove the Elixir agrees with itself.
  """

  use ExUnit.Case, async: false

  alias Ampd.{Authority, Control, Loci, Locus, Peer, Receipts, Worktree, World}

  # ------------------------------------------------------------- fixtures
  setup do
    Ampd.reset()
    Ampd.Bridge.reset()
    Peer.reset()
    Application.delete_env(:ampd, :profile_overrides)
    Application.delete_env(:ampd, :worktree_effector)
    Process.sleep(120)

    # The capability surface is installed, not seeded. See
    # `Ampd.CapabilityRegistry.worktree_pack/0` for why it is not in
    # `initial/0` — the authority snapshot has a frozen parity vector.
    Authority.install_worktree()

    repo = init_repo!()
    {:ok, r} = Authority.register_repository(repo)

    {control, agent} = Ampd.attach_pair("kestrel")
    ws = ok!(Control.command(control, :open_workspace, ["acme"]), "workspace")
    goal = ok!(Control.command(control, :open_goal, [ws["id"], "close the argv boundary"]), "goal")

    lane =
      ok!(
        Control.command(control, :open_lane, [goal["id"], "kestrel", r["ref"], nil]),
        "lane"
      )

    # **D.1.2 added two lines to this fixture, and they are the whole slice.**
    #
    # Under D.1.1 the Carrier occupied this Lane the moment it authenticated
    # as `kestrel`, so the battery below never had to say where anybody was
    # standing. It does now: a person opens an assignment, and the Carrier
    # takes it up. Every D.1.1 falsifier still states exactly what it
    # stated — what changed is that the precondition it silently relied on
    # is now something that has to happen.
    worker = ok!(Control.command(control, :open_worker, [lane["id"], "implement"]), "worker")
    ok!(Control.command(agent, :attach_worker, [worker["id"]]), "worker")

    %{
      repo: repo,
      repo_ref: r["ref"],
      control: control,
      agent: agent,
      ws: ws,
      goal: goal,
      lane: lane,
      worker: worker
    }
  end

  # Open an assignment on `lane_id` and have `carrier` take it up. Returns
  # the `worker@1`. Two acts, deliberately not one: a person assigns and a
  # Carrier attaches, and the falsifiers below need to do the first without
  # the second.
  defp occupy!(control, carrier, lane_id, purpose \\ "work") do
    w = ok!(Control.command(control, :open_worker, [lane_id, purpose]), "worker")
    ok!(Control.command(carrier, :attach_worker, [w["id"]]), "worker")
    w
  end

  # A real repository with one real commit. `git worktree add` needs a
  # commit to detach from, and the whole point of this battery is that the
  # thing on the other side of the capability is a machine resource.
  defp init_repo! do
    dir = Path.join(Ampd.Store.data_dir(), "fixture-repo")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README"), "d11\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "d11@example.invalid"],
          ["config", "user.name", "D11"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "-q", "-m", "init"]
        ] do
      {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert code == 0, "fixture repo setup failed: git #{Enum.join(args, " ")} → #{out}"
    end

    dir
  end

  defp grant_worktree!(lane_id, actor \\ "kestrel") do
    g =
      Authority.mint(%{
        "capability" => Locus.create_capability(),
        "resource" => lane_id,
        "actor" => actor,
        "duration" => "workspace"
      })

    refute match?({:refused, _}, g), "the grant was refused: #{inspect(g)}"
    g
  end

  defp ok!(result, key) do
    assert result["allow"] == true,
           "expected #{key} to be allowed, got: #{inspect(Map.take(result, ["allow", "reason"]))}"

    result[key]
  end

  # `ok!/2` returns one key of the reply. Establishment is the one call
  # whose *whole* reply is under test — the capability, the resource view
  # and the receipt are three surfaces and F19f walks all three.
  defp established!(agent, lane_id, name) do
    r = Control.command(agent, :establish_worktree, [lane_id, name])

    assert r["allow"] == true,
           "expected establishment to be allowed, got: #{inspect(r["refusal"])}"

    r
  end

  defp refusal_code(r), do: r["refusal"]["code"]

  # Put the three durable stores into one exact crash-cut. Writing the
  # state directly is the point: a fault injector that went through the
  # normal path could only reach the cuts the normal path produces, and the
  # cuts worth defining are the ones a crash produces.
  # `original` is captured once, before any cut runs. `:keep_receipt` used
  # to mean "leave the log as it is", which is only the same thing until a
  # `:drop_receipt` cut has run — after that every later `:keep_receipt`
  # silently tested the dropped case, and the matrix was quietly checking
  # six distinct cuts instead of eight.
  defp set_cut!(ref, state, receipt_mode, cap_id, cap_status, original) do
    Ampd.AuthorityCoordinator.transact(fn ->
      Worktree.quarantine_as(ref, state, "cut fixture")
      Loci.put_cap(cap_id, %{"status" => cap_status})

      log =
        case receipt_mode do
          :drop_receipt -> Enum.reject(original, &(&1["kind"] == Locus.receipt_kind()))
          :keep_receipt -> original
        end

      Receipts.load_state(%{"log" => log, "seq" => length(log) + 7})
    end)
  end

  defp worktree_receipts,
    do: Enum.filter(Receipts.all(), &(&1["kind"] == Locus.receipt_kind()))

  # Everything the world could have gained from a call that should have
  # changed nothing. Asserted as a unit so a falsifier cannot pass by
  # checking only the half that happens to be easy.
  defp world_footprint do
    %{
      receipts: length(worktree_receipts()),
      active_caps: Loci.caps() |> Enum.count(fn {_, c} -> c["status"] == "active" end),
      admitted: Worktree.resources() |> Enum.count(fn {_, r} -> r["state"] != "REQUESTED" end),
      dirs: Worktree.root() |> File.ls!() |> Enum.sort()
    }
  end

  # ------------------------------------------------- disclosure walking
  #
  # **A shallow check proved a shallow property, and the difference was a
  # real leak.** What stood here before was, in effect:
  #
  #     refute Map.has_key?(receipt, "path")
  #     refute receipt |> Map.values() |> Enum.any?(fn
  #              s -> is_binary(s) and String.contains?(s, "/home")
  #            end)
  #
  # Both halves fail to see the same thing for the same reason. The first
  # asks about a key literally named `"path"`; the leak was named
  # `worktree_root`. The second is guarded by `is_binary/1`, and
  # `receipt["profile"]` is a **map** — so the guard is false and the value
  # is skipped one level above where the path actually was. `"/home"` was
  # a weak needle besides: under a relocated `AMPD_DATA_DIR` the root does
  # not contain it.
  #
  # So: descend everything, and take the needles from the running system
  # rather than from a literal somebody typed.

  # Absolute strings that are **not** a disclosure of this host's
  # namespace. Each is a constant of the hardening policy — a value chosen
  # by the runtime and identical on every machine — so it says nothing
  # about where anything lives here. Enumerated rather than pattern-matched
  # so that adding one is a decision somebody makes on purpose.
  @disclosure_allowed ["/dev/null"]

  defp host_needles(ctx) do
    [
      Worktree.root(),
      Ampd.Store.data_dir() |> Path.expand(),
      ctx[:repo],
      System.user_home!()
    ]
    |> Enum.reject(&(&1 in [nil, "", "/"]))
    |> Enum.uniq()
  end

  # Every string anywhere in a term, with the route that reached it, so a
  # failure names `profile.facts.worktree_root` rather than "a string".
  defp strings_with_paths(term), do: strings_with_paths(term, [])

  defp strings_with_paths(m, at) when is_map(m) do
    Enum.flat_map(m, fn {k, v} -> strings_with_paths(v, at ++ [to_string(k)]) end)
  end

  defp strings_with_paths(l, at) when is_list(l) do
    l |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> strings_with_paths(v, at ++ ["[#{i}]"]) end)
  end

  defp strings_with_paths(t, at) when is_tuple(t),
    do: strings_with_paths(Tuple.to_list(t), at)

  defp strings_with_paths(s, at) when is_binary(s), do: [{Enum.join(at, "."), s}]
  defp strings_with_paths(_, _), do: []

  # Returns `[{route, string, why}]` — empty means the surface is clean.
  defp disclosures(term, ctx) do
    needles = host_needles(ctx)

    term
    |> strings_with_paths()
    |> Enum.reject(fn {_, s} -> s in @disclosure_allowed end)
    |> Enum.flat_map(fn {route, s} ->
      cond do
        Enum.any?(needles, &String.contains?(s, &1)) ->
          [{route, s, "contains a live host root"}]

        # The generic net, for a root this test did not think to name.
        # Two or more segments, and the first segment is a directory that
        # really exists on this machine — so `"HEAD"` and `"sha256:…"` and
        # `"-c"` are not absolute paths, and `/home/anything` is.
        looks_like_host_path?(s) ->
          [{route, s, "looks like an absolute host path"}]

        true ->
          []
      end
    end)
  end

  defp looks_like_host_path?(s) do
    String.starts_with?(s, "/") and
      case Path.split(s) do
        ["/", first | _] -> File.dir?("/" <> first)
        _ -> false
      end
  end

  defp refute_discloses!(term, ctx, what) do
    case disclosures(term, ctx) do
      [] ->
        :ok

      found ->
        detail =
          Enum.map_join(found, "\n", fn {route, s, why} -> "    #{route} = #{inspect(s)}  (#{why})" end)

        flunk("#{what} discloses a host path:\n#{detail}")
    end
  end

  # ====================================================== the positive path
  describe "the admitted path" do
    test "a granted Lane establishes a real worktree and a receipt", ctx do
      grant_worktree!(ctx.lane["id"])
      before = world_footprint()

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      assert r["allow"] == true, "expected admission, got #{inspect(r["reason"])}"

      cap = r["capability"]
      assert cap["schema"] == "worktree-cap@1"
      assert cap["status"] == "active"
      assert cap["rights"] == ["observe"]
      assert cap["locus_ref"] == ctx.lane["id"]
      assert cap["world_ref"] == World.lineage()
      assert cap["profile_basis"] == Locus.profile_digest()

      # The resource is real, and the runtime observed it rather than
      # assuming the effector told the truth.
      res = Worktree.resource(cap["resource_ref"])
      assert res["state"] == "COMMITTED_READY"
      assert File.dir?(res["path"]), "the worktree directory is not on disk"
      assert File.exists?(Path.join(res["path"], "README"))
      assert Worktree.confined?(res["path"], Worktree.root())

      # And the head is the repository's, not a value the runtime invented.
      {head, 0} = System.cmd("git", ["-C", ctx.repo, "rev-parse", "HEAD"], stderr_to_stdout: true)
      assert res["head"] == String.trim(head)

      after_ = world_footprint()
      assert after_.receipts == before.receipts + 1
      assert after_.active_caps == before.active_caps + 1
    end

    test "worktree_created@1 binds the whole basis and no wall-clock freshness", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      assert r["allow"] == true

      [rcpt] = worktree_receipts()
      assert rcpt["kind"] == "worktree_created@1"

      # Every field program control asked the receipt to bind.
      for k <- ~w(world_ref workspace_ref goal_ref locus_ref repository_ref
                  base_revision resource_ref capability_ref authority_basis
                  rights_digest profile_basis runtime_revision lifecycle_state
                  outcome worktree_head) do
        assert Map.has_key?(rcpt, k), "worktree_created@1 does not bind #{k}"
        refute is_nil(rcpt[k]), "worktree_created@1 binds #{k} as nil"
      end

      assert rcpt["outcome"] == "admitted"
      assert rcpt["lifecycle_state"] == "OBSERVED_CREATED"
      assert rcpt["capability_ref"] == r["capability"]["id"]
      assert rcpt["world_ref"] == World.lineage()

      # **No path.** A receipt is read by more eyes than any projection.
      refute Map.has_key?(rcpt, "path")
      refute rcpt |> Map.values() |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "/home")))

      # `recorded_at` exists for an operator reading history and is never
      # read back as authority. If it were load-bearing, moving it would
      # change a decision — it does not.
      assert Map.has_key?(rcpt, "recorded_at")
      assert Locus.check(Loci.cap(rcpt["capability_ref"]), Peer.resolve(ctx.agent)) == :ok
    end

    test "observe returns the resource and never the path", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]

      o = Control.command(ctx.agent, :observe_worktree, [cap_id])
      assert o["allow"] == true
      assert o["resource"]["exists"] == true
      assert o["resource"]["state"] == "COMMITTED_READY"

      refute Map.has_key?(o["resource"], "path"),
             "the agent channel was handed a filesystem path"
    end
  end

  # ================================================================== F1
  describe "F1 · a Lane lacking worktree authority is refused" do
    test "no grant means no worktree, and nothing is left behind", ctx do
      before = world_footprint()

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      assert r["allow"] == false
      assert refusal_code(r) == "worktree-authority-missing"
      assert world_footprint() == before, "a refused establishment changed the world"
    end

    test "installing the worktree pack confers zero authority", ctx do
      # The runtime's first law, applied to the surface this slice adds.
      # The pack is installed — that is what makes `worktree.create`
      # mintable at all — and no Lane can do anything with it until a
      # person authors a grant.
      assert Ampd.CapabilityRegistry.get("worktree")["installation"] == "installed"
      assert Ampd.GrantRegistry.list() == []

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      assert refusal_code(r) == "worktree-authority-missing"
      assert worktree_receipts() == []
    end

    test "opening a Lane confers nothing by itself", ctx do
      # The product-level form of the runtime's first law. The Lane exists,
      # is occupied, and names a real repository — and reaches nothing.
      assert Loci.lane(ctx.lane["id"])["actor"] == "kestrel"
      assert Loci.caps_of(ctx.lane["id"]) == %{}

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      assert refusal_code(r) == "worktree-authority-missing"
    end
  end

  # ================================================================== F2
  describe "F2 · one Lane may not use another Lane's capability" do
    test "knowing the capability id is not holding it", ctx do
      grant_worktree!(ctx.lane["id"])
      a = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = a["capability"]["id"]

      # A second Lane, occupied by a different actor, with its own grant.
      lane_b =
        ok!(
          Control.command(ctx.control, :open_lane, [ctx.goal["id"], "mallory", ctx.repo_ref, nil]),
          "lane"
        )

      grant_worktree!(lane_b["id"], "mallory")
      {:ok, mallory} = Peer.attach_agent("mallory")
      occupy!(ctx.control, mallory, lane_b["id"])

      before = world_footprint()
      o = Control.command(mallory, :observe_worktree, [cap_id])

      assert o["allow"] == false
      assert refusal_code(o) == "capability-not-held"
      assert world_footprint() == before

      # And the refusal is not "it does not exist" — Mallory is fully
      # authorized on its own Lane, so the only thing that refused here is
      # occupancy of the Locus the capability belongs to.
      b = Control.command(mallory, :establish_worktree, [lane_b["id"], "lane-b"])
      assert b["allow"] == true
    end

    test "a stranger gets one answer whatever the capability's condition is", ctx do
      # Order is disclosure. If `check/2` tested status before occupancy, a
      # caller free to guess ids could read another Locus's capability state
      # one probe at a time — active, establishing, failed — without ever
      # holding anything.
      Application.put_env(:ampd, :worktree_effector, Ampd.LocusTest.FailingEffector)
      grant_worktree!(ctx.lane["id"])
      Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      Application.delete_env(:ampd, :worktree_effector)

      [{failed_id, failed}] = Map.to_list(Loci.caps())
      assert failed["status"] == "failed"

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-b"])
      active_id = r["capability"]["id"]

      {:ok, mallory} = Peer.attach_agent("mallory")

      for id <- [failed_id, active_id, "wc_9999"] do
        o = Control.command(mallory, :observe_worktree, [id])
        assert o["allow"] == false

        assert refusal_code(o) in ["capability-not-held", "capability-unknown"],
               "a stranger learned #{id}'s condition: #{refusal_code(o)}"
      end

      # A stranger cannot tell the failed one from the active one.
      assert refusal_code(Control.command(mallory, :observe_worktree, [failed_id])) ==
               refusal_code(Control.command(mallory, :observe_worktree, [active_id]))

      # The holder does get the specific reason — it is entitled to it.
      assert refusal_code(Control.command(ctx.agent, :observe_worktree, [failed_id])) ==
               "capability-not-active"
    end

    test "attaching to a Locus you do not occupy yields nothing", ctx do
      grant_worktree!(ctx.lane["id"])
      Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      {:ok, mallory} = Peer.attach_agent("mallory")
      r = Control.command(mallory, :attach_locus, [ctx.lane["id"]])

      assert r["allow"] == false
      assert refusal_code(r) == "locus-not-occupied"
      refute Map.has_key?(r, "capabilities")
    end
  end

  # ================================================================== F3
  describe "F3 · a revoked or wrong-generation capability is refused" do
    test "revoking the grant kills the capability that stood on it", ctx do
      g = grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]

      assert Control.command(ctx.agent, :observe_worktree, [cap_id])["allow"] == true

      Authority.revoke_one(g["id"])

      o = Control.command(ctx.agent, :observe_worktree, [cap_id])
      assert o["allow"] == false
      assert refusal_code(o) == "capability-authority-revoked"

      # The record survived. The authority did not. That distinction is
      # the entire point of the slice.
      assert Loci.cap(cap_id)["status"] == "active"
      assert File.dir?(Worktree.resource(r["capability"]["resource_ref"])["path"])
    end

    test "a world lineage advance stales the capability", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]
      established_in = Loci.cap(cap_id)["world_ref"]

      Authority.advance_lineage("D.1.1 falsifier F3")

      # The advance closed every channel — which is itself the rule under
      # test one layer down — so a Carrier has to reattach.
      {:ok, kestrel} = Peer.attach_agent("kestrel")

      # And, since D.1.2, retake its position. The Worker survived the
      # advance exactly as the Lane did — both are durable records and
      # neither is authority — while the attachment did not, because
      # occupancy does not cross a discontinuity.
      assert Loci.worker(ctx.worker["id"])["status"] == "open"
      ok!(Control.command(kestrel, :attach_worker, [ctx.worker["id"]]), "worker")

      o = Control.command(kestrel, :observe_worktree, [cap_id])
      assert o["allow"] == false
      assert refusal_code(o) == "capability-generation-stale"

      assert established_in != World.lineage()
      assert Loci.cap(cap_id)["world_ref"] == established_in,
             "the record was rewritten instead of being refused"
    end
  end

  # ================================================================== F4
  describe "F4 · a namespace escape is refused" do
    test "every escaping name is refused before the filesystem is touched", ctx do
      grant_worktree!(ctx.lane["id"])
      before = world_footprint()

      for name <- [
            "../escape",
            "..",
            ".",
            "/absolute",
            "a/b",
            "a\\b",
            ".hidden",
            "-dash",
            "Upper",
            String.duplicate("x", 64),
            "sub/../../etc"
          ] do
        r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], name])

        assert r["allow"] == false, "#{inspect(name)} was admitted"

        assert refusal_code(r) == "worktree-name-illegal",
               "#{inspect(name)} refused as #{refusal_code(r)}"
      end

      assert world_footprint() == before,
             "an escaping name changed the world before it was refused"
    end

    test "the confinement check is on the realpath, not a string prefix", _ctx do
      root = Worktree.root()

      # The sibling trap. `"<root>-evil"` starts with `"<root>"` and is not
      # inside it; a `String.starts_with?` check admits it.
      sibling = root <> "-evil"
      File.mkdir_p!(sibling)
      on_exit(fn -> File.rm_rf!(sibling) end)

      refute Worktree.confined?(sibling, root),
             "a sibling directory sharing the root's prefix was judged confined"

      inside = Path.join(root, "ok")
      File.mkdir_p!(inside)
      assert Worktree.confined?(inside, root)
    end

    test "a symlink out of the root is not confined", _ctx do
      root = Worktree.root()
      outside = Path.join(Ampd.Store.data_dir(), "outside-target")
      File.mkdir_p!(outside)
      link = Path.join(root, "escape-link")
      File.rm_rf!(link)
      :ok = File.ln_s(outside, link)
      on_exit(fn -> File.rm_rf!(link) end)

      refute Worktree.confined?(link, root),
             "a symlink pointing out of the root was judged confined"
    end
  end

  # =============================================================== F5 · F6
  describe "F5 · F6 · a refusal creates no worktree and emits no receipt" do
    test "no refusal path produces a directory, a live cap, or a receipt", ctx do
      # Every way this slice can refuse, run in one pass, against one
      # baseline. Checking them individually would let a leak that only
      # appears on the third refusal go unseen.
      before = world_footprint()

      {:ok, mallory} = Peer.attach_agent("mallory")

      refusals = [
        {ctx.agent, [ctx.lane["id"], "lane-a"], "worktree-authority-missing"},
        {ctx.agent, ["ln_9999", "lane-a"], "locus-unknown"},
        {mallory, [ctx.lane["id"], "lane-a"], "locus-not-occupied"},
        {ctx.agent, [ctx.lane["id"], "../escape"], "worktree-name-illegal"}
      ]

      for {peer, args, code} <- refusals do
        r = Control.command(peer, :establish_worktree, args)
        assert r["allow"] == false
        assert refusal_code(r) == code
      end

      assert worktree_receipts() == [], "a refusal minted a worktree_created@1"
      assert world_footprint() == before
    end

    test "a failing effector leaves no capability and no receipt", ctx do
      # The crash-shaped case: git ran, the runtime cannot confirm what it
      # did, and the safe direction is state without authority.
      Application.put_env(:ampd, :worktree_effector, Ampd.LocusTest.FailingEffector)
      grant_worktree!(ctx.lane["id"])

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      assert r["allow"] == false
      assert refusal_code(r) == "worktree-create-failed"
      assert worktree_receipts() == []

      # A cap was minted and never became active. That is deliberate: the
      # attempt is evidence, and `check/2` refuses anything not `active`.
      assert Loci.caps() |> Enum.all?(fn {_, c} -> c["status"] != "active" end)

      [{_, res}] = Map.to_list(Worktree.resources())
      assert res["state"] == "INDETERMINATE"
    end

    test "an unobservable success is quarantined, not committed", ctx do
      Application.put_env(:ampd, :worktree_effector, Ampd.LocusTest.LyingEffector)
      grant_worktree!(ctx.lane["id"])

      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      assert r["allow"] == false
      assert refusal_code(r) == "worktree-unobserved"
      assert worktree_receipts() == []

      [{_, res}] = Map.to_list(Worktree.resources())
      assert res["state"] == "QUARANTINED"
      assert res["quarantine_reason"] =~ "absent"
    end
  end

  # ================================================================== F7
  describe "F7 · the Carrier dies and the Locus survives" do
    test "killing every Carrier destroys no Lane, no capability, no resource", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]
      res_ref = r["capability"]["resource_ref"]
      path = Worktree.resource(res_ref)["path"]

      # Carrier death, mechanically: a fresh peer epoch, after which every
      # outstanding handle stops resolving rather than merely being absent.
      Peer.reset()
      Process.sleep(50)

      assert Peer.resolve(ctx.agent) == nil, "the Carrier did not actually die"

      # The Locus and everything admitted from it are untouched.
      assert Loci.lane(ctx.lane["id"])["actor"] == "kestrel"
      assert Loci.cap(cap_id)["status"] == "active"
      assert Worktree.resource(res_ref)["state"] == "COMMITTED_READY"
      assert File.dir?(path), "the worktree died with its Carrier"

      # And the receipt is still the record of what happened.
      assert length(worktree_receipts()) == 1
    end

    test "the Locus survives a full registry restart", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]

      # Not a process restart — a reload from what is actually on disk.
      # If the Lane lived in a GenServer's state rather than in dets, this
      # is where it would evaporate.
      Ampd.Bootstrap.reload_registries!()

      assert Loci.lane(ctx.lane["id"])["actor"] == "kestrel"
      assert Loci.cap(cap_id)["status"] == "active"
      assert Loci.cap(cap_id)["resource_ref"] == r["capability"]["resource_ref"]
    end
  end

  # ================================================================== F8
  describe "F8 · a new Carrier acquires nothing merely because a worktree exists" do
    test "a fresh Carrier without Locus authority reaches nothing", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]
      res_ref = r["capability"]["resource_ref"]

      Peer.reset()
      Process.sleep(50)

      # A replacement Carrier attaches as somebody else. The worktree is
      # right there on disk and it reaches none of it.
      {:ok, mallory} = Peer.attach_agent("mallory")

      assert File.dir?(Worktree.resource(res_ref)["path"])

      o = Control.command(mallory, :observe_worktree, [cap_id])
      assert o["allow"] == false
      assert refusal_code(o) == "capability-not-held"

      a = Control.command(mallory, :attach_locus, [ctx.lane["id"]])
      assert a["allow"] == false
      assert refusal_code(a) == "locus-not-occupied"

      e = Control.command(mallory, :establish_worktree, [ctx.lane["id"], "lane-b"])
      assert e["allow"] == false
      assert refusal_code(e) == "locus-not-occupied"
    end
  end

  # ================================================================== F9
  describe "F9 · a replacement Carrier receives only what can be re-established" do
    test "attaching to an authorized Locus reconstructs exactly the live set", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]

      Peer.reset()
      Process.sleep(50)
      {:ok, kestrel} = Peer.attach_agent("kestrel")

      # **The replacement Carrier has to retake the position, and D.1.2 is
      # what makes that sentence non-trivial.** Under D.1.1 authenticating
      # as `kestrel` put it back at the Lane; now the Worker is still open
      # and unoccupied, and standing there again is an act.
      ok!(Control.command(kestrel, :attach_worker, [ctx.worker["id"]]), "worker")

      a = Control.command(kestrel, :attach_locus, [ctx.lane["id"]])
      assert a["allow"] == true
      assert a["count"] == 1
      assert Map.has_key?(a["capabilities"], cap_id)
      assert a["capabilities"][cap_id]["rights"] == ["observe"]
    end

    test "the set is reconstructed, not inherited", ctx do
      g = grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]

      # The grant goes away while no Carrier is attached — the interval a
      # design that handed the old set to the new Carrier would miss.
      Peer.reset()
      Process.sleep(50)
      Authority.revoke_one(g["id"])

      {:ok, kestrel} = Peer.attach_agent("kestrel")
      ok!(Control.command(kestrel, :attach_worker, [ctx.worker["id"]]), "worker")
      a = Control.command(kestrel, :attach_locus, [ctx.lane["id"]])

      assert a["allow"] == true, "the Locus itself is still occupiable"
      assert a["count"] == 0, "a replacement Carrier inherited a capability it could not re-establish"
      refute Map.has_key?(a["capabilities"], cap_id)

      # The cap record is still on disk. Persistence is not authority.
      assert Loci.cap(cap_id)["status"] == "active"
    end
  end

  # ================================================================= F10
  describe "F10 · an invalidated profile basis does not silently survive" do
    test "a changed embodiment refuses the capability by name", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]
      established_under = Loci.cap(cap_id)["profile_basis"]

      assert Control.command(ctx.agent, :observe_worktree, [cap_id])["allow"] == true

      # The embodiment moves. Nothing else changes: same world, same
      # grant, same Carrier, same record on disk.
      Application.put_env(:ampd, :profile_overrides, %{"machine" => "a different one"})

      o = Control.command(ctx.agent, :observe_worktree, [cap_id])
      assert o["allow"] == false
      assert refusal_code(o) == "capability-profile-basis-changed"

      assert Loci.cap(cap_id)["profile_basis"] == established_under
      assert established_under != Locus.profile_digest()

      # And the capability comes back when the embodiment does — the rule
      # is *re-establish against the current basis*, not *destroy*.
      Application.delete_env(:ampd, :profile_overrides)
      assert Control.command(ctx.agent, :observe_worktree, [cap_id])["allow"] == true
    end

    test "reconstruction under a changed profile yields an empty set", ctx do
      grant_worktree!(ctx.lane["id"])
      Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      Application.put_env(:ampd, :profile_overrides, %{"machine" => "a different one"})

      a = Control.command(ctx.agent, :attach_locus, [ctx.lane["id"]])
      assert a["allow"] == true
      assert a["count"] == 0
    end
  end

  # ================================================================ F3c
  describe "F3c · a replacement grant does not revive a revoked capability" do
    test "authority is the exact grant named by authority_basis, never an equivalent", ctx do
      a = grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap_id = r["capability"]["id"]

      assert Loci.cap(cap_id)["authority_basis"] == a["id"]
      assert Control.command(ctx.agent, :observe_worktree, [cap_id])["allow"] == true

      Authority.revoke_one(a["id"])
      assert refusal_code(Control.command(ctx.agent, :observe_worktree, [cap_id])) ==
               "capability-authority-revoked"

      # An identical grant — same actor, same capability, same resource,
      # same duration. Under the first implementation this revived the
      # capability, because the check searched for *an* applicable grant
      # rather than resolving the one the capability was established from.
      b = grant_worktree!(ctx.lane["id"])
      assert b["id"] != a["id"]

      o = Control.command(ctx.agent, :observe_worktree, [cap_id])

      assert o["allow"] == false,
             "resurrected: #{cap_id} records basis #{a["id"]} and was authorized by #{b["id"]}"

      assert refusal_code(o) == "capability-authority-revoked"

      # The evidence and the runtime must never disagree about the basis.
      [rcpt] = worktree_receipts()
      assert rcpt["authority_basis"] == a["id"]
      assert Loci.cap(cap_id)["authority_basis"] == a["id"]

      # A new grant is grounds for a NEW capability, and that still works.
      fresh = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-b"])
      assert fresh["allow"] == true
      assert fresh["capability"]["authority_basis"] == b["id"]
    end
  end

  # ================================================================ F12
  describe "F12 · the worktree lifecycle is completely mediated" do
    test "a non-coordinator caller cannot reach any lifecycle mutation", ctx do
      before = world_footprint()

      # Each of these is an ordinary exported function. Before D.1.1a they
      # were served to any in-VM caller, and the three together produced a
      # real git worktree with no grant, no occupancy and no capability.
      # The caller never got a `worktree-cap@1` — but the machine effect
      # had already happened, which is the whole of complete mediation.
      calls = [
        {"request",
         fn ->
           Worktree.request(%{
             "repository_ref" => ctx.repo_ref,
             "locus_ref" => ctx.lane["id"],
             "name" => "bypass",
             "base_revision" => "HEAD"
           })
         end},
        {"admitted", fn -> Worktree.admitted("wt_0001") end},
        {"create", fn -> Worktree.create("wt_0001") end},
        {"committed", fn -> Worktree.committed("wt_0001") end},
        {"register_repository", fn -> Worktree.register_repository!(ctx.repo) end}
      ]

      for {name, call} <- calls do
        result = call.()

        assert match?({:refused, _}, result),
               "#{name} served a non-coordinator caller: #{inspect(result)}"

        {:refused, refusal} = result
        assert refusal["code"] == "unordered-authority-mutation"
      end

      assert world_footprint() == before,
             "a bypassed lifecycle call changed the world"

      refute "bypass" in File.ls!(Worktree.root()),
             "a grantless in-VM caller created a real git worktree"
    end

    test "the legitimate caller is not refused by the same guard", ctx do
      # The guard's justification for not existing was that it would refuse
      # `Ampd.Locus.establish/3`. It does not: that function runs *inside*
      # the coordinator, so it IS the ordered caller. `Ampd.Loci.create_cap/1`
      # was always guarded and always worked from the same transaction,
      # which was standing proof in the same function.
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      assert r["allow"] == true
    end
  end

  # ================================================================ F13
  describe "F13 · the Workspace → Goal → Lane graph is referentially closed" do
    test "no object may be opened under an ancestor that does not exist", ctx do
      before = world_footprint()

      g = Control.command(ctx.control, :open_goal, ["ws_9999", "phantom parent"])
      assert g["allow"] == false
      assert refusal_code(g) == "workspace-unknown"

      l = Control.command(ctx.control, :open_lane, ["gl_9999", "kestrel", ctx.repo_ref, nil])
      assert l["allow"] == false
      assert refusal_code(l) == "goal-unknown"

      # The repository was checked only at establishment, so a Lane could
      # be opened against one that does not resolve and be presented as an
      # occupied position until someone tried to use it.
      r = Control.command(ctx.control, :open_lane, [ctx.goal["id"], "kestrel", "rp_9999", nil])
      assert r["allow"] == false
      assert refusal_code(r) == "repository-unknown"

      assert world_footprint() == before
      assert Loci.goals() |> Enum.all?(fn {_, gl} -> Loci.workspace(gl["workspace_ref"]) != nil end)
      assert Loci.lanes() |> Enum.all?(fn {_, ln} -> Loci.goal(ln["goal_ref"]) != nil end)
    end
  end

  # ================================================================ F14
  describe "F14 · visibility is ancestry-closed, not table-wide" do
    test "an agent cannot infer another actor's Workspace, Goal or Lane", ctx do
      ws_b = ok!(Control.command(ctx.control, :open_workspace, ["secret-b"]), "workspace")
      goal_b = ok!(Control.command(ctx.control, :open_goal, [ws_b["id"], "b's private goal"]), "goal")

      lane_b =
        ok!(
          Control.command(ctx.control, :open_lane, [goal_b["id"], "mallory", ctx.repo_ref, nil]),
          "lane"
        )

      # `list_loci` filtered lanes by actor and then returned the whole
      # workspace and goal tables — so the leaf was scoped and the tree was
      # not, which scopes nothing. Titles included.
      r = Control.command(ctx.agent, :list_loci, [])
      assert r["allow"] == true

      refute Map.has_key?(r["lanes"], lane_b["id"])
      refute Map.has_key?(r["goals"], goal_b["id"]), "kestrel can see mallory's Goal"
      refute Map.has_key?(r["workspaces"], ws_b["id"]), "kestrel can see mallory's Workspace"

      # Its own ancestry is present and complete — closure, not blindness.
      assert Map.has_key?(r["lanes"], ctx.lane["id"])
      assert Map.has_key?(r["goals"], ctx.goal["id"])
      assert Map.has_key?(r["workspaces"], ctx.ws["id"])

      # The operator sees the world, because the operator is who it is for.
      op = Control.command(ctx.control, :list_loci, [])
      assert Map.has_key?(op["workspaces"], ws_b["id"])
      assert Map.has_key?(op["lanes"], lane_b["id"])
    end
  end

  # ================================================================ F15
  describe "F15 · git is a program that runs other programs" do
    test "a repository's post-checkout hook does not execute", ctx do
      # Measured before D.1.1a: this hook RAN, with the runtime's uid and
      # the runtime's whole filesystem view. The census row reading "one
      # module executes a program" was true of the source and false about
      # the machine.
      marker = Path.join(Ampd.Store.data_dir(), "HOOK_RAN")
      File.rm_rf!(marker)
      hooks = Path.join(ctx.repo, ".git/hooks")
      File.mkdir_p!(hooks)
      File.write!(Path.join(hooks, "post-checkout"), "#!/bin/sh\necho pwned > #{marker}\n")
      File.chmod!(Path.join(hooks, "post-checkout"), 0o755)

      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "hooked"])

      assert r["allow"] == true, "the hardening broke the legitimate path"

      refute File.exists?(marker),
             "transitive execution: git worktree add ran the repository's post-checkout hook"
    end

    test "hook suppression is asserted at a precedence the repository cannot override", ctx do
      # `core.hooksPath` passed as `-c` on the command line, so a hostile
      # `.git/config` setting its own value cannot win.
      #
      # The assertion below is **behavioural**, and that matters now that
      # execution lives in the host: a check against
      # `Ampd.Worktree.Git.hardening_flags()` would be inspecting the
      # effector that is not running. The repository sets its own
      # `core.hooksPath` and the hook still must not fire, whichever
      # effector is current.
      {_, 0} =
        System.cmd("git", ["-C", ctx.repo, "config", "core.hooksPath", ".git/hooks"],
          stderr_to_stdout: true
        )

      marker = Path.join(Ampd.Store.data_dir(), "HOOK_RAN2")
      File.rm_rf!(marker)
      hooks = Path.join(ctx.repo, ".git/hooks")
      File.mkdir_p!(hooks)
      File.write!(Path.join(hooks, "post-checkout"), "#!/bin/sh\necho pwned > #{marker}\n")
      File.chmod!(Path.join(hooks, "post-checkout"), 0o755)

      grant_worktree!(ctx.lane["id"])
      Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "hooked"])

      refute File.exists?(marker),
             "the repository's own core.hooksPath overrode the runtime's"
    end

    test "config files are disabled by /dev/null, not by being unset", _ctx do
      g = Ampd.Worktree.Git

      # The distinction the first version got backwards. Unsetting these
      # restores git's default lookup; setting them to /dev/null is what
      # disables it. Both directions are asserted so the claim cannot rot.
      assert g.nulled_variables()["GIT_CONFIG_GLOBAL"] == "/dev/null"
      assert g.nulled_variables()["GIT_CONFIG_SYSTEM"] == "/dev/null"
      refute "GIT_CONFIG_GLOBAL" in g.scrubbed_variables()

      env = Enum.map(g.scrubbed_variables(), &{&1, nil}) ++ Enum.to_list(g.nulled_variables())

      {out, _} =
        System.cmd("git", ["config", "--show-origin", "--get-all", "user.email"],
          env: env,
          stderr_to_stdout: true
        )

      refute out =~ "gitconfig", "the effector env still reads a global gitconfig: #{out}"
    end
  end

  # ================================================================ F16
  describe "F16 · every durable cross-state has a defined interpretation" do
    test "the crash-cut matrix is total, and no cut promotes a capability", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      ref = r["capability"]["resource_ref"]
      cap_id = r["capability"]["id"]

      # Establishment crosses three durable stores. A crash between any two
      # writes leaves a combination no single store can see, so each is set
      # up here and handed to the reconciler that runs at boot.
      cuts = [
        {"REQUESTED", :keep_receipt, "establishing", :inert},
        {"ADMITTED", :keep_receipt, "establishing", :inert},
        {"CREATING", :keep_receipt, "establishing", "INDETERMINATE"},
        {"OBSERVED_CREATED", :drop_receipt, "establishing", "RECOVERY_REQUIRED"},
        {"OBSERVED_CREATED", :keep_receipt, "establishing", "RECOVERY_REQUIRED"},
        {"COMMITTED_READY", :keep_receipt, "establishing", "RECOVERY_REQUIRED"},
        {"COMMITTED_READY", :drop_receipt, "active", "QUARANTINED"},
        {"COMMITTED_READY", :keep_receipt, "active", :complete}
      ]

      original_log = Receipts.all()

      for {state, receipt_mode, cap_status, expected} <- cuts do
        set_cut!(ref, state, receipt_mode, cap_id, cap_status, original_log)

        out = Ampd.Authority.reconcile_worktrees()
        got = Enum.find(out, fn {rf, _, _} -> rf == ref end)

        case expected do
          s when is_binary(s) ->
            assert got != nil,
                   "cut #{state}/#{receipt_mode}/#{cap_status} produced no interpretation"

            {_, actual, why} = got

            assert actual == s,
                   "cut #{state}/#{receipt_mode}/#{cap_status} → #{actual}, expected #{s}"

            assert is_binary(why) and why != "", "the interpretation carries no reason"

          _ ->
            assert got == nil,
                   "cut #{state}/#{receipt_mode}/#{cap_status} was reclassified when it should " <>
                     "have been left alone: #{inspect(got)}"
        end

        # **No cut ever promotes.** This is the property that matters more
        # than any individual row: recovery may refuse, quarantine, or ask
        # for a person. It may never decide that a capability nobody
        # finished establishing is now live.
        refute Loci.cap(cap_id)["status"] == "active" and cap_status != "active",
               "reconcile promoted a capability from #{cap_status} to active"
      end
    end

    test "reconcile is idempotent and terminal states are left alone", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      ref = r["capability"]["resource_ref"]

      # Through the coordinator, because `quarantine_as/3` is ordered like
      # every other lifecycle mutation. A direct call from this process is
      # refused — which is F12 holding, in a test that was not trying to
      # check it.
      Ampd.AuthorityCoordinator.transact(fn ->
        Worktree.quarantine_as(ref, "CREATING", "simulated")
      end)

      first = Ampd.Authority.reconcile_worktrees()
      assert Enum.any?(first, fn {rf, s, _} -> rf == ref and s == "INDETERMINATE" end)

      # A second boot must not reinterpret what the first one settled — a
      # terminal state that keeps being re-derived is a state that never
      # converges.
      second = Ampd.Authority.reconcile_worktrees()
      refute Enum.any?(second, fn {rf, _, _} -> rf == ref end)
      assert Worktree.resource(ref)["state"] == "INDETERMINATE"
    end
  end

  # ================================================================ F17
  describe "F17 · the profile basis is recoverable, not just a hash" do
    test "worktree_created@1 binds the canonical basis object", ctx do
      grant_worktree!(ctx.lane["id"])
      Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      [rcpt] = worktree_receipts()
      p = rcpt["profile"]

      assert p["schema"] == "worktree-profile@1"
      # **The exact version, not "an integer".** `is_integer/1` was true of
      # the stale 1 and would be true of any future stale value — it asserts
      # that the field exists, which was never in doubt. This pins the
      # vocabulary revision, so adding or removing a fact without advancing
      # it fails here.
      assert p["fact_set_version"] == 2
      assert p["fact_set_version"] == Locus.fact_set_version()

      # And the vocabulary itself, so a silent change of the fact set is a
      # test failure rather than a digest that moved for reasons nobody
      # wrote down. `worktree_root` is named explicitly because its removal
      # is the D.1.1b closure and its return would be the regression.
      assert Enum.sort(Map.keys(p["facts"])) == Locus.fact_keys(),
             "the declared fact vocabulary and the produced one disagree"

      assert Locus.fact_keys() == [
               "ampd_vsn",
               "effector",
               "effector_protocol_version",
               "embodiment",
               "otp_release",
               "worktree_root_identity"
             ]

      refute Map.has_key?(p["facts"], "worktree_root")
      assert p["evidence_class"] == "declared-provisional"
      assert is_map(p["facts"]) and map_size(p["facts"]) > 0

      # The digest must be *of* the object it is stored beside, or the
      # object is decoration rather than the basis.
      assert rcpt["profile_basis"] == Ampd.Core.intent_digest(p)
      assert rcpt["profile_basis"] == Locus.profile_digest()
    end

    test "a changed fact set is visible in the object, not only in the digest", ctx do
      grant_worktree!(ctx.lane["id"])
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])
      cap = Loci.cap(r["capability"]["id"])

      Application.put_env(:ampd, :profile_overrides, %{"machine" => "a different one"})

      # Refused, as F10 already proved. What F17 adds: the stored basis can
      # still be read and compared, so "what did this commit us to?" has an
      # answer six months later instead of an uninterpretable hash.
      assert refusal_code(Control.command(ctx.agent, :observe_worktree, [cap["id"]])) ==
               "capability-profile-basis-changed"

      was = cap["profile"]["facts"]
      now = Locus.profile_facts()
      assert Map.keys(now) -- Map.keys(was) == ["machine"]
      assert was["effector"] == now["effector"]
    end
  end

  # ================================================================ F18
  describe "F18 · the effector boundary" do
    test "the host is the default and ampd does not exec git", _ctx do
      assert Ampd.Worktree.Effector.current() == Ampd.Worktree.Effector.Host
      assert Ampd.Worktree.Effector.Host.available?(),
             "the host binary is absent — build it: cd super/host && cargo build --release"

      # The one exec `ampd` performs is its own binary, not `git`. This is
      # a source probe and it is deliberately narrow: it proves which
      # program the runtime names, which is the property that changed.
      src = File.read!("lib/ampd/worktree/effector.ex")
      assert src =~ "Port.open({:spawn_executable, bin}"
      refute Ampd.Worktree.Effector.Host |> Module.split() |> Enum.empty?()
    end

    test "host and in-process effectors observe the same effect", ctx do
      # The move is only safe if it did not change the effect. Same
      # repository, same revision, two effectors, one comparison.
      grant_worktree!(ctx.lane["id"])

      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
      via_host = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "by-host"])
      assert via_host["allow"] == true

      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Git)
      via_git = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "by-git"])
      assert via_git["allow"] == true, "the in-process effector stopped working: #{inspect(via_git["reason"])}"

      h = Worktree.resource(via_host["capability"]["resource_ref"])
      g = Worktree.resource(via_git["capability"]["resource_ref"])

      assert h["head"] == g["head"], "the two effectors checked out different commits"
      assert h["state"] == g["state"]
      assert File.dir?(h["path"]) and File.dir?(g["path"])
      assert File.read!(Path.join(h["path"], "README")) == File.read!(Path.join(g["path"], "README"))
    end

    test "the host reports what OS authority it retained, and it is bound into evidence", ctx do
      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
      grant_worktree!(ctx.lane["id"])
      Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      [rcpt] = worktree_receipts()
      c = rcpt["confinement"]

      assert c["schema"] == "host-confinement@1"

      # **Every one of these is false today**, and the falsifier asserts
      # that rather than hoping. Moving the exec is not confinement; it is
      # the place confinement can be applied. If one of these becomes true
      # this test fails and somebody has to say so in the evidence.
      for k <- ~w(landlock seccomp mount_namespace network_namespace pid_namespace chroot drops_privileges) do
        assert c[k] == false, "#{k} is now #{inspect(c[k])} — the confinement claim changed"
      end

      assert c["inherits_uid"] == true
      assert "core.hooksPath=/dev/null" in c["hardening_flags"]
      assert Enum.any?(c["nulled"], fn [k, v] -> k == "GIT_CONFIG_GLOBAL" and v == "/dev/null" end)
    end

    test "a missing host binary refuses by name rather than falling back to git", ctx do
      Application.put_env(:ampd, :host_bin, "/nonexistent/super-host")
      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
      on_exit(fn -> Application.delete_env(:ampd, :host_bin) end)

      grant_worktree!(ctx.lane["id"])
      before = world_footprint()
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      assert r["allow"] == false
      assert refusal_code(r) == "worktree-create-failed"

      # **The agent is told nothing about the host's filesystem layout**,
      # which is `Ampd.Refusal.project/2` doing its job — a missing binary
      # path is topology. So the detail is asserted where an operator
      # would read it, in the unprojected record, and its absence from the
      # agent's copy is asserted too.
      refute Map.has_key?(r["refusal"], "operator_detail")

      logged = Enum.find(Ampd.RefusalLog.recent(20), &(&1["code"] == "worktree-create-failed"))

      assert logged["operator_detail"]["reason"] =~ "refusing to execute git in the runtime",
             "a silent fallback to executing git in the runtime would change the trusted " <>
               "computing base with nothing saying so"
      assert worktree_receipts() == []
      assert before.dirs == world_footprint().dirs
    end
  end

  # ================================================================== F19
  describe "F19 · the basis identifies the machine, not just the module" do
    # A working binary with different bytes. An ELF loader uses the program
    # headers, so trailing bytes past the end of the image are ignored and
    # the copy still runs — which is exactly the case worth testing: the
    # same program, byte-different, must invalidate. Padding rather than
    # corrupting, because a binary that cannot run would prove only that a
    # broken host is refused.
    defp padded_copy!(src, dest) do
      File.cp!(src, dest)
      File.write!(dest, :crypto.strong_rand_bytes(16), [:append])
      File.chmod!(dest, 0o755)
      dest
    end

    defp tmpdir!(name) do
      d = Path.join(System.tmp_dir!(), "ampd-f19-#{name}-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(d)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf(d) end)
      d
    end

    test "F19a · replacing the host executable invalidates an existing capability", ctx do
      host = Ampd.Worktree.Effector.Host.binary()

      if not File.exists?(host) do
        flunk("F19a needs the real host binary at the configured location — build it with " <>
                "`cargo build --release` in super/host")
      end

      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Effector.Host)
      Ampd.Embodiment.refresh()

      grant_worktree!(ctx.lane["id"])
      r = established!(ctx.agent, ctx.lane["id"], "lane-a")
      cap_id = r["capability"]["id"]

      # It is exercisable under the machine it was established on.
      assert Control.command(ctx.agent, :observe_worktree, [cap_id])["allow"] == true

      # The same program, sixteen bytes longer.
      other = padded_copy!(host, Path.join(tmpdir!("host"), "super-host"))
      assert File.read!(other) != File.read!(host)

      Application.put_env(:ampd, :host_bin, other)
      System.put_env("SUPER_HOST_BIN", other)
      on_exit(fn ->
        System.delete_env("SUPER_HOST_BIN")
        Application.delete_env(:ampd, :host_bin)
      end)

      # **No `refresh/0` here, deliberately.** The claim is that the probe
      # notices, not that a test cleared a cache — those are two different
      # properties and only the first is the one this module offers.
      o = Control.command(ctx.agent, :observe_worktree, [cap_id])

      assert refusal_code(o) == "capability-profile-basis-changed",
             "the executable that performs the effect was replaced and the capability " <>
               "established under the old one stayed exercisable"
    end

    test "F19b · replacing the effective git invalidates an existing capability", ctx do
      real_git = System.find_executable("git")
      assert real_git != nil

      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Git)
      Ampd.Embodiment.refresh()

      grant_worktree!(ctx.lane["id"])
      r = established!(ctx.agent, ctx.lane["id"], "lane-a")
      cap_id = r["capability"]["id"]
      o0 = Control.command(ctx.agent, :observe_worktree, [cap_id])
      assert o0["allow"] == true,
             "the capability was refused before anything was swapped — the basis is not " <>
               "stable across two measurements of one unchanged machine: " <>
               inspect(o0["refusal"]["code"])

      # A different git, first on PATH. Both `ampd`'s probe and the host's
      # own resolution walk the same PATH, so both move together.
      dir = tmpdir!("git")
      padded_copy!(real_git, Path.join(dir, "git"))
      was = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> was)
      on_exit(fn -> System.put_env("PATH", was) end)

      assert System.find_executable("git") == Path.join(dir, "git")

      o = Control.command(ctx.agent, :observe_worktree, [cap_id])

      assert refusal_code(o) == "capability-profile-basis-changed",
             "the git that performs the effect was replaced and the capability established " <>
               "under the old one stayed exercisable"
    end

    test "F19c · a capability may be re-established under the new basis", ctx do
      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Git)
      Ampd.Embodiment.refresh()
      grant_worktree!(ctx.lane["id"])
      first = established!(ctx.agent, ctx.lane["id"], "lane-a")

      Application.put_env(:ampd, :profile_overrides, %{"embodiment_note" => "a second machine"})

      assert refusal_code(Control.command(ctx.agent, :observe_worktree, [first["capability"]["id"]])) ==
               "capability-profile-basis-changed"

      # **Refusal is not revocation.** The Lane still occupies its Locus and
      # the grant still stands, so the authority is reacquirable on the far
      # side of the discontinuity — which is the whole difference between a
      # basis change and a revocation.
      second = established!(ctx.agent, ctx.lane["id"], "lane-b")
      assert Control.command(ctx.agent, :observe_worktree, [second["capability"]["id"]])["allow"] == true
      refute second["capability"]["profile_basis"] == first["capability"]["profile_basis"]
    end

    test "F19d · the host's hand-written SHA-256 agrees with OpenSSL's", _ctx do
      host = Ampd.Worktree.Effector.Host.binary()

      if not File.exists?(host) do
        flunk("F19d needs the real host binary — build it with `cargo build --release`")
      end

      id = Ampd.Worktree.Effector.Host.identity()

      assert id["host_binary"]["resolved"] == true,
             "the host could not identify its own running image: #{inspect(id["reason"])}"

      # The host hashes `/proc/self/exe` with SHA-256 written out by hand in
      # `host/src/sha256.rs`. This is the cross-check that makes that
      # defensible: Erlang's `:crypto` is OpenSSL, a different
      # implementation in a different language, over the same real
      # multi-megabyte binary.
      expected = "sha256:" <> Base.encode16(:crypto.hash(:sha256, File.read!(host)), case: :lower)

      assert id["host_binary"]["sha256"] == expected,
             "the host's SHA-256 disagrees with OpenSSL's on its own image"

      assert id["git"]["sha256"] ==
               "sha256:" <>
                 Base.encode16(:crypto.hash(:sha256, File.read!(System.find_executable("git"))),
                   case: :lower
                 )

      # `--version` is one line a distro holds constant across backported
      # changes. The build options carry the SHA-1 implementation and the
      # compiled-in shell, which decide what an effect can reach.
      assert id["git"]["version"] =~ "SHA-1:"
    end

    test "F19e · an effector that misreports which machine ran is quarantined", ctx do
      Application.put_env(:ampd, :worktree_effector, Ampd.LocusTest.ImpostorEffector)
      Ampd.Embodiment.refresh()
      grant_worktree!(ctx.lane["id"])

      before = world_footprint()
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      assert refusal_code(r) == "worktree-embodiment-mismatch",
             "an effector reported an identity that was not the one measured, and the " <>
               "runtime committed anyway"

      # The directory it really made is litter, and litter is the safe
      # direction — but no capability and no receipt may exist.
      assert worktree_receipts() == []
      assert before.active_caps == world_footprint().active_caps

      quarantined =
        Worktree.resources() |> Enum.filter(fn {_, w} -> w["state"] == "QUARANTINED" end)

      assert length(quarantined) == 1
    end

    test "F19h · a real, correct effect that will not name its machine is refused", ctx do
      # **The observation gets everything right except the one thing that
      # makes it committable.** A real `git worktree add`, the true HEAD, the
      # directory present and confined — and no identity.
      #
      # D.1.1b accepted this. `identity_moved?/1` read `nil -> false`, i.e.
      # "no identity is not a mismatch", underneath a comment claiming such an
      # observation is not silently trusted. Both shipped effectors reported
      # one, so the happy path was right and the property was not.
      Application.put_env(:ampd, :worktree_effector, Ampd.LocusTest.AnonymousEffector)
      Ampd.Embodiment.refresh()
      grant_worktree!(ctx.lane["id"])

      before = world_footprint()
      r = Control.command(ctx.agent, :establish_worktree, [ctx.lane["id"], "lane-a"])

      assert refusal_code(r) == "worktree-embodiment-unidentified",
             "a successful effect that named no machine was committed anyway"

      # The work really was done, which is what makes this the interesting
      # case rather than an error path: the directory is on disk.
      assert [_] = Worktree.root() |> File.ls!() |> Enum.filter(&(&1 == "lane-a"))

      # And none of it became authority or evidence.
      assert worktree_receipts() == []
      assert before.active_caps == world_footprint().active_caps

      [{_, res}] = Map.to_list(Worktree.resources())
      assert res["state"] == "QUARANTINED"
      assert res["quarantine_reason"] =~ "without saying which machine"
    end

    test "F19h · the contract is on the observation, not on the shipped effectors", _ctx do
      # The rule stated as a property of `Ampd.Worktree` rather than as a
      # survey of what happens to be in the tree. Both directions, so the
      # check cannot pass by refusing everything.
      assert Worktree.embodiment_fault(%{head: "abc"}) ==
               {"worktree-embodiment-unidentified",
                "the effector reported success without saying which machine performed it"}

      assert Worktree.embodiment_fault(%{head: "abc", identity: nil}) |> elem(0) ==
               "worktree-embodiment-unidentified"

      assert Worktree.embodiment_fault(%{head: "abc", identity: %{}}) |> elem(0) ==
               "worktree-embodiment-unidentified"

      assert Worktree.embodiment_fault(%{head: "abc", identity: %{"a" => 1}}) |> elem(0) ==
               "worktree-embodiment-mismatch"

      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Git)
      Ampd.Embodiment.refresh()

      assert Worktree.embodiment_fault(%{head: "abc", identity: Ampd.Embodiment.identity()}) == nil
    end

    test "F19i · an unavailable embodiment cache refuses by name, it does not crash", ctx do
      # `Ampd.Locus.check/2` runs on every capability use and reaches
      # `Ampd.Embodiment` through a `GenServer.call`. If that process is
      # momentarily restarting, the call would take down the caller *inside a
      # coordinator transaction* rather than refuse — and this codebase's own
      # rule is that a crash is not a named refusal.
      grant_worktree!(ctx.lane["id"])
      r = established!(ctx.agent, ctx.lane["id"], "lane-a")
      cap_id = r["capability"]["id"]

      pid = Process.whereis(Ampd.Embodiment)
      assert is_pid(pid)
      ref = Process.monitor(pid)
      Process.unregister(Ampd.Embodiment)

      try do
        o = Control.command(ctx.agent, :observe_worktree, [cap_id])

        assert o["allow"] == false
        assert refusal_code(o) == "capability-profile-basis-changed",
               "an absent measurement must be fail-closed and named, not a crash"
      after
        Process.register(pid, Ampd.Embodiment)
        Process.demonitor(ref, [:flush])
      end

      # And it recovers: the measurement returning restores the basis rather
      # than leaving the capability permanently refused.
      assert Control.command(ctx.agent, :observe_worktree, [cap_id])["allow"] == true
    end

    test "F19g · an effector that is merely not loaded yet is still identified", _ctx do
      # **The basis must not depend on code-loading order.** `function_exported?/3`
      # answers about a *loaded* module and says false for one that has simply
      # not been loaded, so the first measurement recorded "declares no
      # identity/0" and a later one — after something else had loaded the
      # module by calling it — recorded the truth. Two digests, one unchanged
      # machine, and a `capability-profile-basis-changed` nobody could explain.
      #
      # Found as an intermittent failure of F19b that depended on the ExUnit
      # seed. This is that condition, made deterministic.
      Application.put_env(:ampd, :worktree_effector, Ampd.Worktree.Git)

      :code.purge(Ampd.Worktree.Git)
      :code.delete(Ampd.Worktree.Git)
      :code.purge(Ampd.Worktree.Git)

      refute :erlang.function_exported(Ampd.Worktree.Git, :identity, 0),
             "the module was expected to be unloaded — this test cannot prove anything otherwise"

      Ampd.Embodiment.refresh()
      id = Ampd.Embodiment.identity()

      refute id["resolved"] == false,
             "an unloaded effector was recorded as unidentifiable: #{inspect(id["reason"])}"

      assert id["effector_kind"] == "in-runtime"

      # And the digest is the same one a loaded module produces, which is the
      # property that actually matters — not merely that it did not say false.
      Ampd.Embodiment.refresh()
      assert Ampd.Core.intent_digest(id) == Ampd.Core.intent_digest(Ampd.Embodiment.identity())
    end
  end

  # ============================================== recursive disclosure walk
  describe "F19f · no serialized surface carries a host path, at any depth" do
    test "the establishment reply, the receipt, the caps and the projections", ctx do
      grant_worktree!(ctx.lane["id"])
      r = established!(ctx.agent, ctx.lane["id"], "lane-a")
      cap_id = r["capability"]["id"]

      # First: prove the walker can actually see the thing the old shallow
      # check could not. If this fails, every assertion below is vacuous.
      planted = put_in(r, ["capability", "profile", "facts", "worktree_root"], Worktree.root())

      assert disclosures(planted, ctx) != [],
             "the disclosure walker cannot see a host path nested two levels below a map — " <>
               "it is the shallow check it replaced"

      # And that it does not fire on the hardening policy's `/dev/null`.
      assert disclosures(%{"nulled" => [["GIT_CONFIG_GLOBAL", "/dev/null"]]}, ctx) == []

      # Now the surfaces. Every one of these is agent-reachable or is
      # serialized, framed and rendered.
      refute_discloses!(r, ctx, "the establish_worktree reply")
      refute_discloses!(r["capability"], ctx, "worktree-cap@1")
      refute_discloses!(r["receipt"], ctx, "worktree_created@1")

      refute_discloses!(
        Control.command(ctx.agent, :attach_locus, [ctx.lane["id"]]),
        ctx,
        "the attach_locus reply"
      )

      refute_discloses!(
        Control.command(ctx.agent, :observe_worktree, [cap_id]),
        ctx,
        "the observe_worktree reply"
      )

      refute_discloses!(
        Control.command(ctx.agent, :list_receipts, [nil, 50]),
        ctx,
        "list_receipts on the agent channel"
      )

      refute_discloses!(Ampd.Projection.agent(ctx.lane["actor"]), ctx, "the agent projection")

      # **The operator projection too.** It is not an agent channel, but
      # `projection.ex` already argues — three lines above the offending
      # key — that a projection which is "serialized, framed, coalesced and
      # rendered" must not carry a path, and then carried one. A rule the
      # file states about itself is a rule worth testing.
      refute_discloses!(Ampd.Projection.operator(), ctx, "the operator projection")
    end

    test "the D.1.1a fact set is reproduced as a real leak, through the real pipeline", ctx do
      # **The defect, re-created rather than described.** D.1.1a's
      # `profile_facts/0` carried `worktree_root` as the literal path.
      # `:profile_overrides` merges over the derived facts, so this is that
      # exact fact set, digested by the real digest, bound onto a real
      # capability by `Ampd.Locus.admit/3` and into a real
      # `worktree_created@1` by `emit_receipt/5` — no hand-built map
      # anywhere in the path.
      Application.put_env(:ampd, :profile_overrides, %{"worktree_root" => Worktree.root()})
      grant_worktree!(ctx.lane["id"])
      r = established!(ctx.agent, ctx.lane["id"], "lane-a")

      found = disclosures(r["receipt"], ctx)

      assert found != [],
             "the D.1.1a fact set was re-created and the walker did not fire — the falsifier " <>
               "cannot detect the defect it was written for"

      assert Enum.any?(found, fn {route, _, _} -> route == "profile.facts.worktree_root" end),
             "expected the leak at profile.facts.worktree_root, got: #{inspect(found)}"

      # And the shallow check it replaced passes on the very same receipt,
      # which is why the leak survived a round of review.
      rcpt = r["receipt"]
      refute Map.has_key?(rcpt, "path")

      refute rcpt
             |> Map.values()
             |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "/home"))),
             "the old shallow assertion was expected to pass here — that is the point"
    end

    test "the durable cap record itself carries no path", ctx do
      grant_worktree!(ctx.lane["id"])
      established!(ctx.agent, ctx.lane["id"], "lane-a")

      # Not a projection — the stored record. If the path is not in the
      # store it cannot be leaked by a surface nobody has written yet,
      # which is the only version of this property that survives D.1.2.
      refute_discloses!(Loci.caps(), ctx, "the stored worktree-cap@1 records")
      refute_discloses!(Receipts.all(), ctx, "the stored receipt log")
    end
  end

  # ====================================================== the grammar itself
  describe "the command grammar cannot express a path" do
    test "no declared field is path-typed, and no id prefix is a separator", _ctx do
      offenders =
        for word <- Ampd.CommandSpec.commands(),
            f <- Ampd.CommandSpec.get(word).fields,
            f.name in ~w(path dir directory file cwd root worktree_path repo_path),
            do: {word, f.name}

      assert offenders == [],
             "a command declares a path-shaped field: #{inspect(offenders)}"
    end

    test "establish_worktree refuses a path in its name field through bind/2", _ctx do
      # The wire path, not the in-BEAM one. `bind/2` is what a Rust client
      # reaches, and the size bound has to hold there too.
      assert {:error, "invalid-command-arguments", _} =
               Ampd.CommandSpec.bind("establish_worktree", %{
                 "locus_ref" => "ln_0001",
                 "name" => String.duplicate("x", 65)
               })

      # A well-formed but escaping name binds — the protocol cannot know
      # about traversal — and is refused by `Ampd.Worktree.legal_name?/1`.
      # Recorded because it says exactly where each check lives.
      assert {:ok, :establish_worktree, ["ln_0001", "../escape"]} =
               Ampd.CommandSpec.bind("establish_worktree", %{
                 "locus_ref" => "ln_0001",
                 "name" => "../escape"
               })

      assert {:error, _} = Worktree.legal_name?("../escape")
    end
  end
end

defmodule Ampd.LocusTest.FailingEffector do
  @moduledoc false
  @behaviour Ampd.Worktree.Effector
  @impl true
  def create(_), do: {:error, "simulated: git worktree add exited 128"}
  @impl true
  def identity, do: %{"schema" => "host-identity@1", "effector_kind" => "test-failing"}
  @impl true
  def identity_probe, do: :test_failing
end

defmodule Ampd.LocusTest.LyingEffector do
  @moduledoc false
  # Reports success and creates nothing. The runtime must not take an
  # effector's word for what is on disk.
  #
  # **It reports its identity truthfully**, and must: once a success without
  # an identity is quarantined as a contract violation, an effector that
  # omitted one would be caught before the disk was ever consulted — and this
  # falsifier would silently stop testing the property it is named for. It
  # lies about exactly one thing.
  @behaviour Ampd.Worktree.Effector
  @impl true
  def create(_), do: {:ok, %{head: "0000000000000000000000000000000000000000", identity: identity()}}
  @impl true
  def identity, do: %{"schema" => "host-identity@1", "effector_kind" => "test-lying"}
  @impl true
  def identity_probe, do: :test_lying
end

defmodule Ampd.LocusTest.AnonymousEffector do
  @moduledoc false
  # Does the work correctly and will not say who did it.
  #
  # Delegates to the real in-runtime effector, so the worktree is real and
  # the HEAD is the true commit — then strips the identity. Everything an
  # observation can get right, except the one thing that makes it
  # committable.
  @behaviour Ampd.Worktree.Effector
  @impl true
  def create(req) do
    case Ampd.Worktree.Git.create(req) do
      {:ok, obs} -> {:ok, Map.delete(obs, :identity)}
      other -> other
    end
  end

  @impl true
  def identity, do: Ampd.Worktree.Git.identity()
  @impl true
  def identity_probe, do: Ampd.Worktree.Git.identity_probe()
end

defmodule Ampd.LocusTest.ImpostorEffector do
  @moduledoc false
  # Creates a **real** worktree — by delegating to the real in-runtime
  # effector — and then reports an identity that is not its own.
  #
  # This is the one an identity check exists for, and it is deliberately
  # not the lying effector: that one lies about the *disk*, and the
  # directory check catches it. This one tells the truth about the disk
  # and lies about *which machine did the work*. Nothing in D.1.1a could
  # see the difference, because nothing asked.
  @behaviour Ampd.Worktree.Effector
  @impl true
  def create(req) do
    case Ampd.Worktree.Git.create(req) do
      {:ok, obs} ->
        {:ok, Map.put(obs, :identity, %{"schema" => "host-identity@1", "effector_kind" => "not-me"})}

      other ->
        other
    end
  end

  @impl true
  def identity, do: Ampd.Worktree.Git.identity()
  @impl true
  def identity_probe, do: Ampd.Worktree.Git.identity_probe()
end
