defmodule Ampd.AttemptWindowTest do
  # T23 · the archived-attempt window. See `Ampd.Projection.with_attempt_window/5`.
  #
  # Most of these run the window over explicit maps, because its budget depends
  # on the size of everything else on the frame, and a real world cannot be made
  # to weigh a chosen amount. The last few run it through `Projection.operator/0`
  # on real records, so the wiring is held too and not only the function.
  use ExUnit.Case, async: false
  alias Ampd.{Authority, Control, Projection}

  @card "archived-record-card@1"

  defp at(n), do: DateTime.to_iso8601(DateTime.add(~U[2026-09-01 00:00:00.000000Z], n, :second))

  defp plan_record(id, finished) do
    %{
      "id" => id,
      "status" => "completed",
      "history" => [
        %{"at" => at(0), "status" => "planned", "note" => "made"},
        %{"at" => finished, "status" => "completed", "note" => "done"}
      ]
    }
  end

  # The card the projection already publishes for an archived plan (T17).
  defp plan_card(id),
    do: %{
      "id" => id,
      "status" => "completed",
      "archived" => %{
        "schema" => @card,
        "omitted" => ["history"],
        "read_with" => "read_development_task"
      }
    }

  defp attempt(id, plan, pad \\ 900, runs \\ 1) do
    %{
      "id" => id,
      "task_ref" => plan,
      "status" => "accepted",
      "history" => [
        %{"at" => at(1), "status" => "recorded", "note" => String.duplicate("h", 300)}
      ],
      "acceptance" => %{
        "schema" => "development-acceptance@1",
        "note" => String.duplicate("a", pad)
      },
      "test_runs" =>
        Map.new(1..runs//1, fn i ->
          {"r#{id}#{i}", %{"run_id" => "r#{id}#{i}", "state" => "completed"}}
        end)
    }
  end

  # A world: `plans` is [{plan_id, finished_at, [attempt]}], all archived.
  defp world(plans, opts \\ []) do
    live_attempts = Keyword.get(opts, :live_attempts, %{})
    live_plans = Keyword.get(opts, :live_plans, %{})
    pad = Keyword.get(opts, :pad, 0)

    archive = for {_p, _f, as} <- plans, a <- as, into: %{}, do: {a["id"], a}
    plan_archive = for {p, f, _} <- plans, into: %{}, do: {p, plan_record(p, f)}

    projection = %{
      "development_attempts" => live_attempts,
      "development_tasks" =>
        Map.merge(for({p, _, _} <- plans, into: %{}, do: {p, plan_card(p)}), live_plans),
      "padding" => String.duplicate("x", pad)
    }

    {projection, archive, plan_archive}
  end

  defp bytes(map) do
    {:ok, body} = Ampd.Frame.encode(map)
    byte_size(body)
  end

  defp t17_cards(archive),
    do:
      archive
      |> Projection.archived_cards(
        Projection.archived_attempt_omits(),
        "read_development_attempt"
      )
      |> Map.new(fn {id, card} -> {id, card} end)

  defp entry(id, card), do: byte_size(JSON.encode!(id)) + byte_size(JSON.encode!(card)) + 2

  defp group_bytes(archive, ids) do
    cards = t17_cards(archive)
    ids |> Enum.map(&entry(&1, cards[&1])) |> Enum.sum()
  end

  describe "the bound" do
    test "T23 · 200 archived attempts across 50 plans ride in at most 32 KiB, and the frame encodes" do
      plans =
        for p <- 1..50 do
          id = "dt_#{1000 + p}"
          {id, at(100 + p), for(a <- 1..4, do: attempt("da_#{p * 10 + a}", id, 3_000, 2))}
        end

      {proj, archive, parch} = world(plans)
      assert map_size(archive) == 200

      out =
        Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), 32 * 1024)

      w = out["development_attempts_window"]

      assert w["carried"]["bytes"] <= 32 * 1024
      assert w["carried"]["attempts"] + w["withheld"]["attempts"] == 200
      assert {:ok, _} = Ampd.Frame.encode(out), "the frame must encode whatever the archive holds"

      # And what it would have been without the window: over the cap on its own.
      all = Map.put(proj, "development_attempts", t17_cards(archive))
      assert {:error, "frame-too-large", _} = Ampd.Frame.encode(all)
    end
  end

  describe "the window rule" do
    test "T23 · newest finished whole plans, as a prefix: a later smaller plan is not skipped in" do
      # Newest first: A (1 attempt), B (3 big attempts), C (1 small attempt).
      # The budget fits A and C but not A and B, so the window stops at B.
      plans = [
        {"dt_0003", at(300), [attempt("da_0031", "dt_0003")]},
        {"dt_0002", at(200), for(i <- 1..3, do: attempt("da_002#{i}", "dt_0002", 4_000))},
        {"dt_0001", at(100), [attempt("da_0011", "dt_0001")]}
      ]

      {proj, archive, parch} = world(plans)
      a = group_bytes(archive, ["da_0031"])
      c = group_bytes(archive, ["da_0011"])
      limit = a + c

      out = Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), limit)
      tasks = out["development_tasks"]

      assert Map.has_key?(out["development_attempts"], "da_0031")

      refute Map.has_key?(out["development_attempts"], "da_0011"),
             "the window skipped a plan to fit an older one"

      assert tasks["dt_0003"]["archived"]["attempts"] == %{"carried" => true, "count" => 1}
      assert tasks["dt_0002"]["archived"]["attempts"]["carried"] == false
      assert tasks["dt_0001"]["archived"]["attempts"]["carried"] == false
    end

    test "T23 · a plan is carried whole or not at all" do
      plans = [{"dt_0002", at(200), for(i <- 1..3, do: attempt("da_002#{i}", "dt_0002"))}]
      {proj, archive, parch} = world(plans)
      two = group_bytes(archive, ["da_0021", "da_0022"])

      out = Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), two)
      assert out["development_attempts"] == %{}
      assert out["development_tasks"]["dt_0002"]["archived"]["attempts"]["count"] == 3
    end

    test "T23 · the order is the terminal transition, and equal times fall to the higher id" do
      # dt_0005 was CREATED first but FINISHED last; dt_0007 and dt_0006 tie.
      plans = [
        {"dt_0005", at(900), [attempt("da_0051", "dt_0005")]},
        {"dt_0006", at(500), [attempt("da_0061", "dt_0006")]},
        {"dt_0007", at(500), [attempt("da_0071", "dt_0007")]}
      ]

      {proj, archive, parch} = world(plans)
      one = group_bytes(archive, ["da_0051"])
      two = one + group_bytes(archive, ["da_0071"])

      out1 = Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), one)
      assert Map.keys(out1["development_attempts"]) == ["da_0051"]

      out2 = Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), two)

      assert Enum.sort(Map.keys(out2["development_attempts"])) == ["da_0051", "da_0071"],
             "on a tie the higher-numbered (newer) plan goes first"
    end

    test "T23 · a plan whose history carries no readable time sorts after every plan that has one" do
      plans = [
        {"dt_0009", at(100), [attempt("da_0091", "dt_0009")]},
        {"dt_0010", "not a time", [attempt("da_0101", "dt_0010")]}
      ]

      {proj, archive, parch} = world(plans)

      out =
        Projection.with_attempt_window(
          proj,
          archive,
          parch,
          Projection.frame_target(),
          group_bytes(archive, ["da_0091"])
        )

      assert Map.keys(out["development_attempts"]) == ["da_0091"]
    end

    test "T23 · a carried card is byte-identical to the card T17 publishes" do
      a = attempt("da_0031", "dt_0003") |> Map.put("text_check", %{"outcome" => "pass"})
      {proj, archive, parch} = world([{"dt_0003", at(300), [a]}])

      out =
        Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), 32 * 1024)

      assert JSON.encode!(out["development_attempts"]["da_0031"]) ==
               JSON.encode!(t17_cards(archive)["da_0031"])

      refute Map.has_key?(out["development_attempts"]["da_0031"], "history")
      assert out["development_attempts"]["da_0031"]["test_runs"] == a["test_runs"]
    end

    test "T23 · a plan with no archived attempt carries no marker" do
      plans = [{"dt_0003", at(300), [attempt("da_0031", "dt_0003")]}, {"dt_0004", at(400), []}]
      {proj, archive, parch} = world(plans)

      out =
        Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), 32 * 1024)

      refute Map.has_key?(out["development_tasks"]["dt_0004"]["archived"], "attempts"),
             "a marker saying zero were withheld sends a reader to a door for nothing"
    end
  end

  describe "current truth" do
    test "T23 · live attempts and live plans pass through unchanged, even when nothing else fits" do
      live = %{
        "da_0200" => attempt("da_0200", "dt_0200", 5_000),
        "da_0201" => attempt("da_0201", "dt_0003")
      }

      live_plan = %{
        "dt_0200" => %{
          "id" => "dt_0200",
          "status" => "planned",
          "criteria" => "c",
          "history" => []
        }
      }

      plans = [{"dt_0003", at(300), [attempt("da_0031", "dt_0003")]}]
      {proj, archive, parch} = world(plans, live_attempts: live, live_plans: live_plan)

      for limit <- [0, 32 * 1024] do
        out =
          Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), limit)

        assert Map.take(out["development_attempts"], Map.keys(live)) == live
        assert out["development_tasks"]["dt_0200"] == live_plan["dt_0200"]
      end
    end
  end

  describe "the markers" do
    test "T23 · carried cards and withheld refs are exactly each plan's archive, and the totals reconcile" do
      plans =
        for p <- 1..12 do
          id = "dt_#{2000 + p}"

          {id, at(p),
           for(a <- 1..rem(p, 4)//1, do: attempt("da_#{p * 10 + a}", id, 2_000, rem(a, 3)))}
        end

      {proj, archive, parch} = world(plans)

      out =
        Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), 20_000)

      w = out["development_attempts_window"]

      for {plan, _, as} <- plans, as != [] do
        mine = as |> Enum.map(& &1["id"]) |> Enum.sort()
        m = out["development_tasks"][plan]["archived"]["attempts"]
        assert m["count"] == length(as)

        if m["carried"] do
          assert Enum.sort(
                   for({id, c} <- out["development_attempts"], c["task_ref"] == plan, do: id)
                 ) == mine
        else
          assert Enum.sort(m["refs"]) == mine
          assert m["runs"] == as |> Enum.map(&map_size(&1["test_runs"])) |> Enum.sum()
          refute Enum.any?(mine, &Map.has_key?(out["development_attempts"], &1))
        end
      end

      assert w["carried"]["attempts"] + w["withheld"]["attempts"] == map_size(archive)

      assert w["carried"]["plans"] + w["withheld"]["plans"] ==
               Enum.count(plans, fn {_, _, as} -> as != [] end)

      assert w["carried"]["runs"] + w["withheld"]["runs"] ==
               archive |> Map.values() |> Enum.map(&map_size(&1["test_runs"])) |> Enum.sum()

      assert w["carried"]["plans"] > 0 and w["withheld"]["plans"] > 0,
             "the case must exercise both sides"

      # The carried figure is the bytes those cards add to the frame, measured
      # independently here: an undercount is what would let a window over-fill.
      on_frame = for {id, c} <- out["development_attempts"], c["archived"], do: id
      assert w["carried"]["bytes"] == group_bytes(archive, on_frame)
      assert w["read_with"] == "read_development_attempt"
    end

    test "T23 · an archived attempt whose plan is not an archived card is carried, and counted as such" do
      stray = attempt("da_0500", "dt_0500")
      {proj, archive, parch} = world([{"dt_0003", at(300), [attempt("da_0031", "dt_0003")]}])
      archive = Map.put(archive, "da_0500", stray)

      out = Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), 0)
      assert Map.has_key?(out["development_attempts"], "da_0500")
      assert out["development_attempts_window"]["carried"]["unwindowed"] == 1
      assert out["development_attempts_window"]["carried"]["attempts"] == 1
    end
  end

  describe "yielding to current truth" do
    setup do
      plans =
        for p <- 1..8 do
          id = "dt_#{3000 + p}"

          {id, at(p),
           [attempt("da_#{p * 10 + 1}", id, 3_000), attempt("da_#{p * 10 + 2}", id, 1_000)]}
        end

      %{plans: plans}
    end

    test "T23 · when the rest of the frame reaches the target, nothing archived rides", %{
      plans: plans
    } do
      {proj, archive, parch} = world(plans, pad: 60_000)
      out = Projection.with_attempt_window(proj, archive, parch, 60_000, 32 * 1024)
      w = out["development_attempts_window"]

      assert w["base_bytes"] >= 60_000
      assert w["budget_bytes"] == 0
      assert w["carried"]["plans"] == 0 and out["development_attempts"] == %{}
    end

    test "T23 · between the two, the window takes only the headroom and the frame stays under the target",
         %{plans: plans} do
      {proj, archive, parch} = world(plans, pad: 50_000)
      # The block reports its own target and limit, so the probe uses numbers
      # of the same width as the real run: the base is then the same bytes.
      base =
        Projection.with_attempt_window(proj, archive, parch, 99_999, 32 * 1024)[
          "development_attempts_window"
        ]["base_bytes"]

      target = base + 64 + 20_000
      assert target in 10_000..99_999

      out = Projection.with_attempt_window(proj, archive, parch, target, 32 * 1024)
      w = out["development_attempts_window"]

      assert w["budget_bytes"] == 20_000
      assert w["carried"]["bytes"] <= 20_000 and w["carried"]["plans"] > 0
      assert w["withheld"]["plans"] > 0, "the headroom, not the 32 KiB, must be what bound it"
      assert bytes(out) <= target
    end

    test "T23 · property: over random worlds the frame never exceeds its target because of history" do
      :rand.seed(:exsss, {23, 9, 27})

      for _ <- 1..150 do
        plans =
          for p <- 1..:rand.uniform(15) do
            id = "dt_#{4000 + p}"

            {id, at(:rand.uniform(50)),
             for(
               a <- 0..(:rand.uniform(4) - 1)//1,
               a > 0 or :rand.uniform(3) > 1,
               do: attempt("da_#{p * 10 + a}", id, :rand.uniform(4_000), :rand.uniform(4) - 1)
             )}
          end

        {proj, archive, parch} = world(plans, pad: :rand.uniform(40_000))

        base =
          Projection.with_attempt_window(proj, archive, parch, 0, 0)[
            "development_attempts_window"
          ]["base_bytes"]

        target = base + :rand.uniform(30_000) - 5_000
        limit = :rand.uniform(32 * 1024)

        out = Projection.with_attempt_window(proj, archive, parch, target, limit)
        w = out["development_attempts_window"]
        final = bytes(out)
        base = w["base_bytes"]

        assert w["carried"]["bytes"] <= w["budget_bytes"]
        assert w["budget_bytes"] <= limit
        assert final <= base + w["budget_bytes"] + 20

        if base + 64 <= target,
          do: assert(final <= target, "history took a frame over its target")

        assert w["carried"]["attempts"] + w["withheld"]["attempts"] == map_size(archive)
      end
    end
  end

  # ── T25 · a LIVE plan's archived attempts ─────────────────────────────────
  #
  # Since T25 a dismissed attempt leaves the live directory while its plan is
  # open. Those records must ride in this window, not loose: loose, they would
  # grow every frame without bound, the failure T23 ended.

  describe "T25 · live plans" do
    defp dismissed(id, plan, pad \\ 900),
      do: Map.put(attempt(id, plan, pad), "status", "dismissed")

    defp live_plan(id), do: %{"id" => id, "status" => "in_progress", "history" => []}

    # `world/2` plus live plans owning archived (dismissed) attempts: [{plan, [attempt]}].
    defp with_live(plans, live, opts \\ []) do
      {proj, archive, parch} =
        world(
          plans,
          Keyword.put(opts, :live_plans, Map.new(live, fn {p, _} -> {p, live_plan(p)} end))
        )

      {proj,
       Enum.reduce(live, archive, fn {_p, as}, acc ->
         Enum.reduce(as, acc, &Map.put(&2, &1["id"], &1))
       end), parch}
    end

    test "T25 · a live plan's archived attempts are carried as the T17 cards, marked on the live plan" do
      as = [dismissed("da_0901", "dt_0900"), dismissed("da_0902", "dt_0900")]
      {proj, archive, parch} = with_live([], [{"dt_0900", as}])

      out =
        Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), 32 * 1024)

      cards = t17_cards(archive)

      for a <- as,
          do:
            assert(out["development_attempts"][a["id"]]["archived"] == cards[a["id"]]["archived"])

      assert out["development_tasks"]["dt_0900"]["archived_attempts"] == %{
               "carried" => true,
               "count" => 2
             }

      refute Map.has_key?(out["development_tasks"]["dt_0900"], "archived")
      assert out["development_attempts_window"]["carried"]["unwindowed"] == 0
    end

    test "T25 · withheld, a live plan says so, and its refs are exactly its archive" do
      as = for n <- [3, 1, 2], do: dismissed("da_091#{n}", "dt_0910")
      {proj, archive, parch} = with_live([], [{"dt_0910", as}])
      out = Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), 0)
      marker = out["development_tasks"]["dt_0910"]["archived_attempts"]

      assert marker["carried"] == false and marker["count"] == 3 and marker["runs"] == 3
      assert marker["refs"] == ["da_0911", "da_0912", "da_0913"]
      for a <- as, do: refute(Map.has_key?(out["development_attempts"], a["id"]))
      assert out["development_attempts_window"]["withheld"]["attempts"] == 3
    end

    test "T25 · a live plan's group comes before every finished plan's" do
      live = [dismissed("da_0921", "dt_0920", 900)]
      finished = [{"dt_0003", at(900), [attempt("da_0031", "dt_0003", 900)]}]
      {proj, archive, parch} = with_live(finished, [{"dt_0920", live}])
      only_one = group_bytes(archive, ["da_0921"])

      out =
        Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), only_one)

      assert out["development_tasks"]["dt_0920"]["archived_attempts"]["carried"] == true
      assert out["development_tasks"]["dt_0003"]["archived"]["attempts"]["carried"] == false
    end

    test "T25 · among live plans, the higher plan id first" do
      {proj, archive, parch} =
        with_live([], [
          {"dt_0930", [dismissed("da_0931", "dt_0930")]},
          {"dt_0940", [dismissed("da_0941", "dt_0940")]}
        ])

      one = group_bytes(archive, ["da_0941"])
      out = Projection.with_attempt_window(proj, archive, parch, Projection.frame_target(), one)
      assert out["development_tasks"]["dt_0940"]["archived_attempts"]["carried"] == true
      assert out["development_tasks"]["dt_0930"]["archived_attempts"]["carried"] == false
    end

    test "T25 · property: with live plans owning archived attempts, history still never takes a frame over its target" do
      :rand.seed(:exsss, {25, 9, 28})

      for _ <- 1..150 do
        plans =
          for p <- 1..:rand.uniform(10) do
            id = "dt_#{6000 + p}"

            {id, at(:rand.uniform(50)),
             for(
               a <- 1..:rand.uniform(3)//1,
               do: attempt("da_#{p * 10 + a}", id, :rand.uniform(4_000))
             )}
          end

        live =
          for p <- 1..:rand.uniform(6) do
            id = "dt_#{7000 + p}"

            {id,
             for(
               a <- 1..:rand.uniform(5)//1,
               do: dismissed("da_#{70_000 + p * 10 + a}", id, :rand.uniform(4_000))
             )}
          end

        {proj, archive, parch} = with_live(plans, live, pad: :rand.uniform(40_000))

        base =
          Projection.with_attempt_window(proj, archive, parch, 0, 0)[
            "development_attempts_window"
          ]["base_bytes"]

        target = base + :rand.uniform(30_000) - 5_000
        limit = :rand.uniform(32 * 1024)

        out = Projection.with_attempt_window(proj, archive, parch, target, limit)
        w = out["development_attempts_window"]
        final = bytes(out)

        assert w["carried"]["bytes"] <= w["budget_bytes"]
        assert final <= w["base_bytes"] + w["budget_bytes"] + 20

        if w["base_bytes"] + 64 <= target,
          do: assert(final <= target, "history took a frame over its target")

        assert w["carried"]["unwindowed"] == 0
        assert w["carried"]["attempts"] + w["withheld"]["attempts"] == map_size(archive)

        # every live plan with archived attempts is marked, and never dressed as a card
        for {id, as} <- live do
          plan = out["development_tasks"][id]
          assert plan["archived_attempts"]["count"] == length(as)
          refute Map.has_key?(plan, "archived")
        end
      end
    end
  end

  # ── through the real projection ────────────────────────────────────────────

  describe "wired" do
    setup do
      Ampd.reset()
      {human, _agent} = Ampd.attach_pair("window-tests")
      %{"workspace" => ws} = Control.command(human, :open_workspace, ["Super"])
      %{"goal" => goal} = Control.command(human, :open_goal, [ws["id"], "Improve Super"])

      bot =
        Authority.register_bot(%{
          "client_ref" => "builder",
          "workspace_ref" => ws["id"],
          "name" => "Builder",
          "role" => "Developer",
          "group" => "Super",
          "instructions" => "Reviewable work",
          "provider" => "ollama"
        })

      repo = Path.join(System.tmp_dir!(), "super-window-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "--quiet", repo])
      on_exit(fn -> File.rm_rf!(repo) end)
      {:ok, registered} = Authority.register_repository(repo)

      %{"lane" => lane} =
        Control.command(human, :open_lane, [goal["id"], bot["actor"], registered["ref"], "HEAD"])

      %{human: human, lane: lane}
    end

    defp hash(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)

    defp archived_plan(c, n) do
      task =
        Authority.create_development_task(%{
          "client_ref" => "plan-#{n}",
          "lane_ref" => c.lane["id"],
          "title" => "Plan #{n}",
          "criteria" => "Criteria #{n}"
        })

      draft = "before\r\n"
      proposed = "after\n"
      head = String.duplicate("a", 40)

      source = %{
        "schema" => "selected-file-basis@1",
        "scope" => "selected-file-only",
        "basis_id" =>
          hash(
            JSON.encode!(["selected-file-basis@1", head, "index.html", hash(draft), hash(draft)])
          ),
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
        "world" =>
          Enum.map(
            ~w(world_incarnation world_generation projection_epoch),
            &Projection.continuity()[&1]
          )
      }

      a =
        Authority.record_development_attempt(%{
          "client_ref" => "attempt-#{n}",
          "task_ref" => task["id"],
          "task_revision" => 1,
          "source" => source,
          "shared_draft" => draft,
          "proposed_text" => proposed
        })

      Authority.update_development_attempt(a["id"], 1, "dismissed", "Superseded")
      Authority.update_development_task(task["id"], 1, "cancelled", "Changed priorities")
      {task, a}
    end

    test "T23 · the operator frame marks a real archived plan and carries the window block", c do
      {task, a} = archived_plan(c, 1)
      p = Projection.operator()

      assert p["development_attempts"][a["id"]]["archived"]["schema"] == @card

      assert p["development_tasks"][task["id"]]["archived"]["attempts"] == %{
               "carried" => true,
               "count" => 1
             }

      w = p["development_attempts_window"]
      assert w["schema"] == "archived-attempt-window@1"
      assert w["max_bytes"] == Projection.attempt_window_bytes()
      assert w["target_bytes"] == Projection.frame_target()
      assert w["carried"]["attempts"] == 1 and w["withheld"]["attempts"] == 0
      assert w["base_bytes"] > 0 and w["budget_bytes"] > 0
    end

    test "T23 · the door still returns a withheld attempt whole", c do
      {_task, a} = archived_plan(c, 2)

      assert %{"allow" => true, "development_attempt" => full} =
               Control.command(c.human, :read_development_attempt, [a["id"]])

      assert full == Ampd.Loci.development_attempts()[a["id"]]
      assert is_list(full["history"])
    end

    test "T23 · the frame's own capacity figure is measured after the window" do
      p = Projection.operator()
      {:ok, body} = Ampd.Frame.encode(Map.delete(p, "capacity"))
      assert p["capacity"]["frame"]["bytes"] == byte_size(body)
    end
  end
end
