defmodule Ampd.RegisteredRepositoryBridgeTest do
  @moduledoc """
  `registered_repository` on the host bridge — a registered repository's
  folder, by reference, for the host process only.

  This is what lets the Editor reopen a registered repository without the
  native folder chooser. Spoken over a socketpair exactly as the Rust host
  speaks it: `bridge-command@1` in, `bridge-reply@1` out, on the descriptor
  `Ampd.Transport.HostBridge` serves.
  """
  use ExUnit.Case, async: false
  alias Ampd.Authority

  setup do
    Ampd.reset_demo()
    Ampd.Bridge.reset()
    Ampd.Peer.reset()
    # SEQPACKET, as Linux's real bridge is: HostBridge reads a stream bridge as framed since T28 (C7).
    {runtime, host} = Ampd.Transport.socketpair(:seqpacket)
    {:ok, bridge} = Ampd.Transport.HostBridge.start(runtime)

    on_exit(fn ->
      Ampd.Transport.HostBridge.stop(bridge)
      :socket.close(host)
      :socket.close(runtime)
    end)

    repo = Path.join(System.tmp_dir!(), "super-registered-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "--quiet", repo])
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, registered} = Authority.register_repository(repo)
    %{host: host, repo: repo, ref: registered["ref"]}
  end

  defp ask(host, frame) do
    :ok = :socket.send(host, JSON.encode!(frame))
    {:ok, bytes} = :socket.recv(host, 0, 3_000)
    JSON.decode!(bytes)
  end

  defp lookup(host, ref),
    do:
      ask(host, %{
        "schema" => "bridge-command@1",
        "command" => "registered_repository",
        "repository_ref" => ref
      })

  test "a registered reference answers the folder registration recorded", ctx do
    reply = lookup(ctx.host, ctx.ref)
    assert reply["ok"] == true
    assert reply["schema"] == "bridge-reply@1"
    assert reply["repository"]["ref"] == ctx.ref
    # The registered path is the resolved one, as `register_repository` stored it.
    {:ok, expected} = Ampd.Worktree.repo(ctx.ref) |> Map.fetch("path")
    assert reply["repository"]["path"] == expected
    assert File.dir?(reply["repository"]["path"])
  end

  test "a reference nothing registered is refused, and names the reference", ctx do
    reply = lookup(ctx.host, "rp_9999")
    assert reply["ok"] == false
    assert reply["refusal"]["code"] == "repository-unknown"
    assert reply["refusal"]["requires_human"] == true
    assert reply["refusal"]["operator_detail"]["repository_ref"] == "rp_9999"
    assert reply["refusal"]["public_message"] =~ "not registered"
  end

  test "only a reference is accepted — a path, an empty string or a decorated ref is refused",
       ctx do
    for bad <- ["", "rp_", ctx.repo, ctx.ref <> "/..", "wt_0001", String.duplicate("rp_1", 40)] do
      reply = lookup(ctx.host, bad)
      assert reply["ok"] == false, inspect(bad)
      assert reply["refusal"]["code"] == "repository-unknown", inspect(bad)
      refute Map.has_key?(reply, "repository"), inspect(bad)
    end

    # A non-string reference does not match the arm at all and is refused as
    # an unknown bridge command rather than crashing the bridge.
    reply =
      ask(ctx.host, %{
        "schema" => "bridge-command@1",
        "command" => "registered_repository",
        "repository_ref" => 3
      })

    assert reply["ok"] == false
    # And the bridge is still serving after every refusal above.
    assert lookup(ctx.host, ctx.ref)["ok"] == true
  end

  test "the projection still carries no path for the repository", ctx do
    record = Ampd.Projection.operator()["repositories"][ctx.ref]
    assert record["ref"] == ctx.ref
    refute Map.has_key?(record, "path")
  end
end
