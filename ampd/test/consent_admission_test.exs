defmodule Ampd.ConsentAdmissionTest do
  @moduledoc """
  Replay and staleness, refused by name.

  `Ampd.Approvals.admit_consent/2` is pure and nothing calls it yet. It is the
  gate in `docs/app/MOBILE_CONSENT_DESIGN_2026_09_11.md` §4: no device other
  than the desktop may decide an approval until every one of these refusals is
  shown to happen, and to happen for the stated reason rather than by accident.

  Two disciplines are followed here deliberately.

  **Every refusal is asserted by name.** `assert {:refused, _}` would pass for
  a predicate that refuses everything, which is the failure mode a fail-closed
  design is most likely to hide behind.

  **One field moves per case.** A case that changes two things cannot say which
  one the refusal came from, and would still pass if one of the two checks were
  deleted.
  """
  use ExUnit.Case, async: true
  alias Ampd.Approvals

  @now "2026-09-11T23:40:00Z"
  @presented "2026-09-11T23:39:00Z"

  defp record(over \\ %{}) do
    Map.merge(
      %{
        "id" => "ap_0001",
        "status" => "pending",
        "request_hash" => "sha256:aaaa",
        "capability" => "github.repo.write",
        "actor" => "bot_0a",
        "resource" => "traaviis/trvm",
        "placement" => "local",
        "pack_version" => "1.2.0",
        "world_installation_id" => "wi_1",
        "world_generation" => 3,
        "envelope" => %{
          "request_id" => "er_0041",
          "request_revision" => 2,
          "request" => %{"branch" => "main", "force" => false}
        },
        # Present in the record, absent from the presentation on purpose.
        "held_ctx" => %{"token" => "a-credential"}
      },
      over
    )
  end

  defp claim(a, over \\ %{}) do
    Map.merge(
      %{
        "approval_id" => a["id"],
        "request_hash" => a["request_hash"],
        "presentation_digest" => Approvals.presentation_digest(a),
        "nonce" => "n1",
        "presented_at" => @presented,
        "now" => @now,
        "world" => %{"installation_id" => "wi_1", "generation" => 3},
        "nonce_seen" => false,
        "decision" => "approve"
      },
      over
    )
  end

  defp refusal(a, over), do: Approvals.admit_consent(a, claim(a, over))

  test "a well-formed claim against an unchanged pending record is admitted" do
    a = record()
    assert Approvals.admit_consent(a, claim(a)) == :ok
    assert Approvals.admit_consent(a, claim(a, %{"decision" => "deny"})) == :ok
  end

  test "a missing record is not an admission" do
    assert Approvals.admit_consent(nil, %{}) == {:refused, "approval-not-found"}
  end

  test "a claim naming another approval is refused even against a valid record" do
    a = record()
    assert refusal(a, %{"approval_id" => "ap_0002"}) == {:refused, "approval-not-found"}
  end

  # ---------------------------------------------------------------- resolved
  #
  # The whole family, because "already resolved" is three different words in
  # this runtime and only one of them is an approval that went through.

  test "a resolved request cannot be decided again, whichever way it resolved" do
    for status <- ~w(granted denied stale) do
      a = record(%{"status" => status})
      assert refusal(a, %{}) == {:refused, "approval-not-pending"},
             "status #{status} was admitted"
    end
  end

  # ----------------------------------------------------------------- changed

  test "a revised proposal refuses the consent given to the previous one" do
    # What the runtime does on revision: the record keeps a NEW request_hash
    # while the device still holds the old one it was shown.
    a = record(%{"request_hash" => "sha256:bbbb"})
    assert refusal(a, %{"request_hash" => "sha256:aaaa"}) == {:refused, "intent-changed"}
  end

  test "a lineage advance refuses consent given in the previous world" do
    a = record()
    assert refusal(a, %{"world" => %{"installation_id" => "wi_1", "generation" => 4}}) ==
             {:refused, "world-moved"}

    assert refusal(a, %{"world" => %{"installation_id" => "wi_2", "generation" => 3}}) ==
             {:refused, "world-moved"}
  end

  test "an argument that changed under the device refuses by presentation, not by luck" do
    # The digest the device holds was computed over the arguments it displayed.
    # Recomputing from the record as it stands now is what catches this, and it
    # is the half of the pair a device cannot choose.
    shown = record()
    held = Approvals.presentation_digest(shown)

    moved =
      record(%{
        "request_hash" => "sha256:aaaa",
        "envelope" => %{
          "request_id" => "er_0041",
          "request_revision" => 2,
          "request" => %{"branch" => "main", "force" => true}
        }
      })

    assert Approvals.presentation_digest(moved) != held

    assert Approvals.admit_consent(moved, claim(shown, %{})) ==
             {:refused, "presentation-mismatch"}
  end

  test "a digest the device simply asserts is refused" do
    a = record()
    assert refusal(a, %{"presentation_digest" => "sha256:whatever"}) ==
             {:refused, "presentation-mismatch"}
  end

  # ------------------------------------------------------------------ replay

  test "a nonce already seen is refused" do
    a = record()
    assert refusal(a, %{"nonce_seen" => true}) == {:refused, "consent-replayed"}
  end

  test "a caller that forgets to say whether the nonce was seen gets no admission" do
    # The memory belongs to the caller; the rule does not. Omission must not
    # read as "not seen".
    a = record()
    incomplete = claim(a) |> Map.delete("nonce_seen")
    assert Approvals.admit_consent(a, incomplete) == {:refused, "claim-incomplete"}
  end

  test "every required field is required, one at a time" do
    a = record()
    full = claim(a)

    for key <- Map.keys(full) do
      assert Approvals.admit_consent(a, Map.delete(full, key)) ==
               {:refused, "claim-incomplete"},
             "#{key} was optional"
    end
  end

  # --------------------------------------------------------------- staleness

  test "a presentation older than the window is refused" do
    a = record()
    window = Approvals.consent_window_seconds()
    {:ok, now, _} = DateTime.from_iso8601(@now)
    stale = DateTime.add(now, -(window + 1), :second) |> DateTime.to_iso8601()
    edge = DateTime.add(now, -window, :second) |> DateTime.to_iso8601()

    assert refusal(a, %{"presented_at" => stale}) == {:refused, "presentation-expired"}
    assert refusal(a, %{"presented_at" => edge}) == :ok
  end

  test "a presentation stamped in the future is refused, not trusted for longer" do
    a = record()
    assert refusal(a, %{"presented_at" => "2026-09-11T23:41:00Z"}) ==
             {:refused, "presentation-expired"}
  end

  test "an unreadable or absent stamp is not fresh" do
    a = record()

    for bad <- ["", "yesterday", "2026-13-45T99:99:99Z", nil, 1_789_000_000] do
      assert refusal(a, %{"presented_at" => bad}) == {:refused, "presentation-expired"},
             "#{inspect(bad)} was read as fresh"
    end

    for bad <- ["", "soon", nil] do
      assert refusal(a, %{"now" => bad}) == {:refused, "presentation-expired"}
    end
  end

  # --------------------------------------------------------------- decisions

  test "only approve and deny are decisions" do
    a = record()

    for bad <- ["APPROVE", "yes", "", "maybe", nil, true, "approve "] do
      assert refusal(a, %{"decision" => bad}) == {:refused, "decision-unrecognised"},
             "#{inspect(bad)} was read as a decision"
    end
  end

  # ------------------------------------------------------------ presentation

  test "the presentation carries the arguments and never the held context" do
    a = record()
    shown = Approvals.presentation_of(a)

    assert shown["request"] == %{"branch" => "main", "force" => false}
    assert shown["capability"] == "github.repo.write"
    assert shown["request_revision"] == 2

    rendered = inspect(shown)
    refute rendered =~ "a-credential"
    refute rendered =~ "held_ctx"
  end

  test "a claim that is not a map cannot be admitted" do
    a = record()

    for bad <- [nil, "approve", [], 1] do
      assert Approvals.admit_consent(a, bad) == {:refused, "claim-incomplete"}
    end
  end

  # ------------------------------------------------------------------- order
  #
  # The one property that is not about a single field: no input admits unless
  # everything holds. A predicate with an early `true ->` would pass every
  # case above and still fail this.

  test "any single defect refuses, so nothing rides in on the others being right" do
    a = record()

    defects = [
      %{"approval_id" => "ap_9999"},
      %{"request_hash" => "sha256:other"},
      %{"world" => %{"installation_id" => "wi_9", "generation" => 3}},
      %{"presentation_digest" => "sha256:other"},
      %{"nonce_seen" => true},
      %{"presented_at" => "2026-09-11T00:00:00Z"},
      %{"decision" => "sure"}
    ]

    for d <- defects do
      assert {:refused, _} = refusal(a, d)
    end

    assert Approvals.admit_consent(a, claim(a)) == :ok
  end
end
