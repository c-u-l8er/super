defmodule Ampd.CommandSpecTest do
  @moduledoc """
  The declared protocol, and the size invariant that was not holding.

  Every test here was a defect first. The nested-argument one was found by
  reading the implementation against the claim the brief made about it —
  the brief said "argument ≤ 64 KB", and the code checked top-level
  binaries.
  """
  use ExUnit.Case, async: false
  alias Ampd.{CommandSpec, Control, Frame, GrantRegistry, Wire}

  defp fresh(actor \\ "kestrel") do
    Ampd.reset_demo()
    Ampd.attach_pair(actor)
  end

  # ------------------------------------------------ the size hole, closed
  test "a large value nested inside an argument is refused, not just a top-level one" do
    {_h, kestrel} = fresh()
    big = String.duplicate("A", 5 * 1024 * 1024)

    # This was always refused: it is a top-level binary.
    top = Wire.command(kestrel, "request_grant", ["github.pr.draft", "traaviis/trvm", big])
    assert top["refusal"]["code"] == "invalid-command-arguments"

    # **This was accepted, and stored.** The third argument is a map, so
    # `is_binary(a) and byte_size(a) > 64K` never looked at it; the depth
    # walk visited the same value and only counted levels. Reproduced
    # before it was fixed: it minted a grant-request carrying 5 242 880
    # bytes of reason.
    nested = Wire.command(kestrel, "request_grant", ["github.pr.draft", "traaviis/trvm", %{"reason" => big}])
    refute nested["allow"], "a 5 MB value one level down was accepted"
    assert nested["refusal"]["code"] == "invalid-command-arguments"
    assert GrantRegistry.requests() == [], "the oversized request reached the store"

    # And two levels down, which is where "we check one level" would show.
    deeper =
      Wire.command(kestrel, "request_grant", [
        "github.pr.draft",
        "traaviis/trvm",
        %{"reason" => %{"why" => %{"because" => big}}}
      ])

    refute deeper["allow"]
  end

  test "logical_size counts keys as well as values, and short-circuits" do
    # A map whose values are all empty still weighs what its keys weigh; a
    # limit that ignores keys has a hole in it the shape of the keys.
    keys_only = Map.new(1..500, fn i -> {String.duplicate("k#{i}", 40), ""} end)
    assert {:over, _} = Frame.logical_size(keys_only, 1_000)

    assert {:ok, n} = Frame.logical_size(%{"a" => "bcd"}, 1_000)
    assert n == byte_size("a") + byte_size("bcd")

    # Short-circuiting: the reported weight of a hostile term stops near
    # the cap rather than being its true total.
    {:over, partial} = Frame.logical_size(%{"x" => String.duplicate("A", 1_000_000)}, 64)
    assert partial < 1_100_000
  end

  # ------------------------------------------------------ per-field limits
  test "each field carries its own declared limit" do
    {human, kestrel} = fresh()

    over_cap = Wire.command(kestrel, "preflight", [String.duplicate("c", 200), "traaviis/trvm"])
    assert over_cap["refusal"]["code"] == "invalid-command-arguments"

    over_res = Wire.command(kestrel, "preflight", ["github.repo.read", String.duplicate("r", 600)])
    assert over_res["refusal"]["code"] == "invalid-command-arguments"

    # A capability at exactly the limit is fine — the limit is a limit, not
    # an off-by-one.
    ok = Wire.command(kestrel, "preflight", [String.pad_trailing("github.repo.read", 128, "x"), "traaviis/trvm"])
    assert is_map(ok)
    refute ok["refusal"]["code"] == "invalid-command-arguments"

    _ = human
  end

  test "identifiers must carry the prefix of the thing they name" do
    {human, _k} = fresh()

    # `approve_effect` takes an effect-request id and an approval id, in
    # that order. Swapping them is the mistake a positional protocol makes
    # easy and a typed one catches.
    r = Wire.command(human, "approve_effect", %{"request_id" => "ap_0001", "approval_id" => "er_0001"})
    assert r["refusal"]["code"] == "invalid-command-arguments"

    r2 = Wire.command(human, "revoke_grant", ["gq_0001"])
    assert r2["refusal"]["code"] == "invalid-command-arguments"
  end

  # ----------------------------------------------------------- named args
  test "named arguments and positional arguments reach the same answer" do
    {human, kestrel} = fresh()

    named = Wire.command(kestrel, "preflight", %{"capability" => "github.repo.read", "resource" => "traaviis/trvm"})
    positional = Wire.command(kestrel, "preflight", ["github.repo.read", "traaviis/trvm"])
    assert named["allow"] == positional["allow"]
    assert named["effect_key"] == positional["effect_key"]

    # An absent optional field becomes its declared default rather than a
    # shorter argument list, so the arity is always the declared arity.
    assert {:ok, :preflight, [_, _, nil]} = CommandSpec.bind("preflight", %{"capability" => "a", "resource" => "b"})
    assert {:ok, :request_grant, [_, _, %{}]} = CommandSpec.bind("request_grant", ["a", "b"])

    _ = human
  end

  test "an unknown field is refused, not silently dropped" do
    {human, _k} = fresh()

    # A client that misspells `expected_ids` must not receive a bulk
    # revocation it did not confirm.
    r = Wire.command(human, "revoke_capability_domain", %{"scope" => %{"actor" => "kestrel"}, "expected" => []})
    assert r["refusal"]["code"] == "invalid-command-arguments"

    r2 = Wire.command(human, "revoke_grant", %{"grant_id" => "gr_0193", "force" => true})
    assert r2["refusal"]["code"] == "invalid-command-arguments"
  end

  test "a missing required field is refused by name" do
    {human, _k} = fresh()
    r = Wire.command(human, "approve_effect", %{"request_id" => "er_1"})
    assert r["refusal"]["code"] == "invalid-command-arguments"

    # `expected_ids` is required: a bulk revocation with no confirmed set
    # is the operation this command exists to make impossible to say by
    # accident.
    b = Wire.command(human, "revoke_capability_domain", %{"scope" => %{"actor" => "kestrel"}})
    assert b["refusal"]["code"] == "invalid-command-arguments"
  end

  test "the duration enum is closed on the wire, not only at the registry" do
    {human, _k} = fresh()
    r = Wire.command(human, "approve_grant_request", %{"request_id" => "gq_0001", "duration" => "forever"})
    assert r["refusal"]["code"] == "invalid-command-arguments"
  end

  # ------------------------------------------------- one source, derived
  test "the command surface is the spec, and cannot drift from it" do
    words = CommandSpec.vocabulary() |> Map.values() |> MapSet.new()

    declared =
      (Control.agent_commands() ++ Control.human_commands() ++ Control.open_commands())
      |> MapSet.new()

    assert words == declared

    # Every declared command has a dispatch clause that answers rather than
    # raising. This is the check that used to be impossible: with the
    # vocabulary derived from the command tables, "everything in the
    # vocabulary is dispatchable" was true by construction and proved
    # nothing.
    {human, kestrel} = fresh()

    for word <- CommandSpec.commands() do
      spec = CommandSpec.get(word)
      peer = if spec.channel == :human_control, do: human, else: kestrel
      r = Wire.command(peer, word, %{})

      assert is_map(r), "#{word} did not return a map"

      refute match?(%{"refusal" => %{"code" => "unknown-command"}}, r),
             "#{word} is declared but unreachable"
    end
  end

  test "frames cannot carry an identity" do
    for field <- ~w(peer_id actor channel) do
      body = JSON.encode!(%{"schema" => "command@1", "command" => "runtime_status", field => "kestrel"})
      assert {:error, "identity-not-claimable", d} = Frame.decode(body)
      assert field in d["offending_fields"]
    end

    # Refused, not ignored: a client that believes it is choosing its
    # identity has to be told that it is not.
    ok = JSON.encode!(%{"schema" => "command@1", "command" => "runtime_status"})
    assert {:ok, %{"command" => "runtime_status"}} = Frame.decode(ok)
  end

  test "frame decoding is total over hostile bytes" do
    hostile = [
      "",
      "not json at all",
      "[1,2,3]",
      "\"a string\"",
      "null",
      JSON.encode!(%{"schema" => "command@2", "command" => "runtime_status"}),
      JSON.encode!(%{"schema" => "command@1", "command" => 42}),
      JSON.encode!(%{"schema" => "command@1", "command" => "runtime_status", "args" => "not an object"}),
      JSON.encode!(%{"schema" => "command@1", "command" => String.duplicate("x", 100)}),
      JSON.encode!(%{"schema" => "command@1", "command" => "runtime_status",
                     "client_request_id" => String.duplicate("c", 200)}),
      String.duplicate("A", Frame.max_bytes() + 1),
      # A 60 000-deep array is 120 KB — well under the frame limit — and a
      # recursive-descent parser on it is a stack the runtime did not
      # choose to spend.
      String.duplicate("[", 60_000) <> String.duplicate("]", 60_000),
      <<0xFF, 0xFE, 0xFD>>
    ]

    for bytes <- hostile do
      assert {:error, code, _} = Frame.decode(bytes)
      assert is_binary(code), "#{String.slice(inspect(bytes), 0, 40)} did not produce a named error"
    end
  end

  test "encoding refuses to emit a frame larger than it accepts" do
    assert {:error, "frame-too-large", _} = Frame.encode(%{"x" => String.duplicate("A", Frame.max_bytes())})

    # And `encode!/1` turns that into a refusal frame rather than silence:
    # a projection that outgrew the limit must not become a client waiting
    # forever for a push.
    body = Frame.encode!(%{"schema" => "reply@1", "x" => String.duplicate("A", Frame.max_bytes())})
    assert {:ok, decoded} = JSON.decode(body)
    assert decoded["result"]["refusal"]["code"] == "frame-too-large"
  end
end
