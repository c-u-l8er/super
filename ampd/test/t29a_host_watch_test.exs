defmodule Ampd.T29aHostWatchTest do
  @moduledoc """
  T29a item 6 is macOS-only (the coordinator's ruling, agenda A-57; superlane/t29a/AMENDMENT-3.md): off macOS
  `Ampd.Bridge.watch_host/1` arms nothing, so the runtime's Linux behaviour is unchanged (T29a A8). macOS's half is A6,
  measured on the Mac by superlane/t29a/laws-mac.
  """
  use ExUnit.Case, async: true

  unless :os.type() == {:unix, :darwin} do
    test "T29a A8: off macOS the host watch arms nothing" do
      reader = spawn(fn -> receive do: (:stop -> :ok) end)
      assert Ampd.Bridge.watch_host(reader) == :ok
      assert {:monitored_by, []} = Process.info(reader, :monitored_by)
      send(reader, :stop)
    end
  end
end
