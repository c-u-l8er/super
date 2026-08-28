defmodule Ampd.Conformance do
  @moduledoc """
  The C0 conformance interface — **not a product execution path.**

  These four functions drive the frozen vector corpus. Three of them can
  reach an outcome the product path cannot express, and that is precisely
  why they are quarantined here rather than left on `Ampd.Gateway`:

  * `authorize/4` decides, then consumes an approval and a one-shot use,
    **without ever touching the effect journal**. Nothing it does is
    recoverable: a crash between the consume and the caller's next line
    leaves consent spent and no record of what it was spent on. C1.0b
    exists because that was the wrong shape; it survives only because the
    C1.0a vectors are written against it.
  * `exercise/1` invents a request and a context out of nowhere.
  * `approve_last/0` consents to whatever happens to be last, which is the
    wrong identity semantics the moment two effects are in flight.
  * `forge_pr_create/1` writes a granted approval straight into the store,
    which is what makes the "consent does not survive authority change"
    vectors possible and is otherwise the single most dangerous thing in
    this codebase.

  Left on the gateway they were four public functions that looked like
  API, next to the three that are. A test interface adjacent to a product
  interface becomes a second product interface — someone reaches for the
  short one. So they moved, the module says what they are, and
  `Ampd.Control` cannot dispatch to any of them.

  The product path is `preflight` → `request_effect` → `perform`. Nothing
  else.
  """
  alias Ampd.{Core, CapabilityRegistry, GrantRegistry, Approvals, Gateway}

  @doc """
  Decide, then consume — as one ordered step. The C1.0a contract the
  vectors are written against, linearized so deciding and consuming
  cannot be split by a concurrent revocation.

  **No journal.** Use `Ampd.Gateway.perform/5`.
  """
  def authorize(cap, resource, ctx, params_or_nil) do
    Ampd.AuthorityCoordinator.transact(fn ->
      auth = Gateway.decide(cap, resource, ctx, params_or_nil)
      if auth["allow"], do: Gateway.consume!(auth)
      auth
    end)
  end

  @doc "Run a github capability with the fixture's request, on the fixture's context."
  def exercise(cap_short) do
    cap = "github." <> cap_short
    params = Core.params()[cap_short]

    Gateway.perform(cap, "traaviis/trvm", Gateway.ctx(),
      %{"er" => "er-" <> cap, "rev" => 1, "params" => params})
  end

  @doc """
  Approve whatever is pending last.

  The product API is `Ampd.Control.approve_effect/2`, which requires the
  proposal id *and* the approval id and refuses when they disagree — a
  failure this function cannot even express.
  """
  def approve_last do
    case Approvals.last_pending() do
      nil ->
        {:error, :no_pending}

      p ->
        Ampd.Authority.grant_approval(p["id"])

        auth =
          Gateway.perform(p["capability"], p["resource"], p["held_ctx"],
            %{"er" => p["envelope"]["request_id"],
              "rev" => p["envelope"]["request_revision"],
              "params" => p["envelope"]["request"]})

        if auth["allow"] do
          auth
        else
          reason = auth["stale_note"] || auth["reason"] || "state changed under the approval"
          Ampd.Authority.stale_approval(p["id"], reason)
          Map.put(auth, "surfaced_stale", reason)
        end
    end
  end

  @doc """
  Write a granted approval directly into the store, bypassing consent.

  This exists so a vector can ask "what happens when a granted approval no
  longer matches the world?" without a human in the loop. It manufactures
  authority. It must never be reachable from a channel.
  """
  def forge_pr_create(over) do
    g =
      Enum.find(GrantRegistry.list(),
        &(&1["status"] == "active" and &1["capability"] == "github.pr.create"))

    pk = CapabilityRegistry.get("github")
    lin = Ampd.World.lineage() || %{}

    env = %{"schema" => "approval-intent@1", "pack" => "github@" <> pk["version"],
            "capability" => "github.pr.create", "actor" => "kestrel",
            "resource" => "traaviis/trvm", "grant" => g["id"],
            "authority_snapshot" => GrantRegistry.snapshot(), "placement" => "local",
            "world_installation_id" => lin["installation_id"],
            "world_generation" => lin["generation"],
            "request_id" => "er-github.pr.create", "request_revision" => 1,
            "request" => Core.params()["pr.create"]}

    base = %{"id" => "ap_forged", "request_hash" => Core.intent_digest(env),
             "capability" => "github.pr.create", "actor" => "kestrel", "grant_ref" => g["id"],
             "pack_version" => pk["version"], "snapshot" => GrantRegistry.snapshot(),
             "placement" => "local", "envelope" => env,
             "world_installation_id" => lin["installation_id"],
             "world_generation" => lin["generation"],
             "status" => "granted"}

    Ampd.AuthorityCoordinator.transact(fn -> Approvals.push(Map.merge(base, over)) end)
  end
end
