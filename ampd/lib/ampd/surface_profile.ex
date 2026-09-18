defmodule Ampd.SurfaceProfile do
  @moduledoc """
  The fixed local Carrier contract. This module performs no machine I/O and
  owns no authority. Preflight binds an eligible attempt; Carrier's existing
  currentness, correspondence and Floor checks accept the actual instance.

  The public command remains start_carrier(locus_ref). Requirements and
  execution bases are resolved by the runtime, never supplied by the caller.
  Change the profile ID when these contract semantics change.
  """
  alias Ampd.{Core, Locus}
  alias Ampd.Carrier.Floor

  @profile "super.local-carrier-terminal.v0"

  def requirement, do: %{"profile" => @profile}

  def contract do
    %{
      "profile" => @profile,
      "isolation" => "trusted-host-linux-confinement",
      "terminal" => "required-separately-authorized",
      "network" => "none",
      "resources" => "no-hard-quota-claim",
      "continuity" => "fresh-after-confirmed-absence",
      "payload" => "host-selected-execution-basis"
    }
  end

  def preflight(requirement, basis) when is_map(basis) do
    if requirement == requirement() do
      {:ok,
       %{
         "schema" => "surface-binding@1",
         "requirement" => requirement,
         "contract" => contract(),
         "floor_version" => Floor.version(),
         "floor_basis" => Floor.digest(),
         "profile_basis" => Locus.profile_digest(),
         "execution_basis_digest" => Core.intent_digest(basis)
       }}
    else
      {:error, "surface-profile-unsupported"}
    end
  end

  def preflight(_, _), do: {:error, "surface-profile-unsupported"}

  # Equality covers unknown fields too. A missing legacy binding remains
  # readable, but cannot authorize a new membership under this profile.
  def binding_current?(binding, basis) do
    case preflight(requirement(), basis) do
      {:ok, expected} -> binding == expected
      _ -> false
    end
  end

  # Only contract vocabulary is disclosed, never payload identities, paths,
  # tickets, epochs or host observations. This describes recorded admission;
  # current execution status comes independently from Carrier membership.
  def project(binding, status) do
    recorded = is_map(binding) and binding["contract"] == contract()

    %{
      "status" => status,
      "admission_profile" => if(recorded, do: @profile, else: nil),
      "evidence" => if(recorded, do: "recorded", else: "legacy-or-unrecorded")
    }
  end
end
