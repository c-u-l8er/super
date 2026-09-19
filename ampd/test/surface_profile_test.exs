defmodule Ampd.SurfaceProfileTest do
  use ExUnit.Case, async: false
  alias Ampd.SurfaceProfile

  test "unsupported requirements never silently select the local profile" do
    for requirement <- [
          %{"profile" => "vm"},
          %{"profile" => "super.local-carrier-terminal.v0", "hardware" => true},
          %{"cpu_max" => 1},
          %{},
          nil
        ] do
      assert {:error, "surface-profile-unsupported"} = SurfaceProfile.preflight(requirement, %{})
    end
  end

  test "legacy evidence is readable without inventing admission" do
    assert SurfaceProfile.project(nil, "RUNNING") == %{
             "status" => "RUNNING",
             "admission_profile" => nil,
             "evidence" => "legacy-or-unrecorded"
           }

    refute SurfaceProfile.binding_current?(nil, %{})
  end
end
