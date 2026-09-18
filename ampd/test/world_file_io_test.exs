defmodule Ampd.WorldFileIOTest do
  use ExUnit.Case, async: false

  # Run without Ampd.Application: its registries and recovery tasks share the
  # configured directory. A separate VM lets us exercise a genuinely absent
  # directory without redirecting or deleting a running world's stores.
  defp isolated(script) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "world-file-io-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    beam_dir = :code.which(Ampd.World) |> List.to_string() |> Path.dirname()

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["-pa", beam_dir, "-e", "import ExUnit.Assertions\nalias Ampd.World\n" <> script],
        env: [{"AMPD_DATA_DIR", Path.join(dir, "nested/world")}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "malformed JSON cannot supply world authority or authorize reinitialization" do
    isolated("""
    World.initialize!("2026-09-15T00:00:00Z")
    path = Path.join(Ampd.Store.data_dir(), "world.json")
    valid = File.read!(path)
    for invalid <- [String.trim_leading(valid, "{"), String.trim_trailing(valid, "}"), valid <> "junk", "[]", "{}", "null"] do
      File.write!(path, invalid)
      assert World.read() == nil
      assert World.lineage() == nil
      assert World.manifest_state() == :malformed
      assert {:error, {:malformed, _}} = World.may_initialize?()
    end
    """)
  end

  test "generation reasons round trip JSON punctuation and escapes" do
    isolated(~S'''
    World.initialize!("2026-09-15T00:00:00Z")
    reason = "restore, quoted \"world\"\nnext"
    written = World.bump_generation!(reason)
    assert World.read() == written
    assert World.read()["generation_reason"] == reason
    assert {:ok, ^written} = JSON.decode(File.read!(Path.join(Ampd.Store.data_dir(), "world.json")))
    ''')
  end

  test "read-only probes do not create an absent world directory" do
    isolated("""
    dir = Ampd.Store.data_dir()
    assert World.read_raw() == nil
    assert World.read() == nil
    assert World.lineage() == nil
    assert World.manifest_state() == :absent
    refute File.exists?(dir)
    assert_raise RuntimeError, fn -> World.bump_generation!("absent") end
    refute File.exists?(dir)
    """)
  end

  test "initialization creates parents and generation writes remain visible" do
    isolated("""
    meta = World.initialize!("2026-09-15T00:00:00Z")
    assert World.read() == meta
    assert World.lineage()["generation"] == 1
    next = World.bump_generation!("restore", %{"generation" => 1, "snapshot" => "test"})
    assert next["generation"] == 2
    assert World.read() == next
    assert World.lineage()["generation"] == 2
    """)
  end

  test "each lineage read observes replacement, corruption and removal" do
    isolated("""
    first = World.initialize!("2026-09-15T00:00:00Z")
    path = Path.join(Ampd.Store.data_dir(), "world.json")
    replacement = %{first | "generation" => 7}
    File.write!(path, JSON.encode!(replacement))
    assert World.lineage()["generation"] == 7
    File.write!(path, "{broken")
    assert World.lineage() == nil
    File.write!(path, JSON.encode!(replacement))
    assert World.lineage()["generation"] == 7
    File.rm!(path)
    assert World.lineage() == nil
    """)
  end
end
