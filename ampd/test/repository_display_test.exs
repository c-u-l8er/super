defmodule Ampd.RepositoryDisplayTest do
  use ExUnit.Case, async: false
  test "operator repository labels disclose only leaf names and retain unique references" do
    Ampd.reset()
    base = Path.join(System.tmp_dir!(), "super-display-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    refs = for parent <- ["one", "two"] do
      path = Path.join([base, parent, "super"])
      File.mkdir_p!(path)
      {:ok, repo} = Ampd.Authority.register_repository(path)
      repo["ref"]
    end
    projection = Ampd.Projection.operator()
    for ref <- refs do
      assert projection["repositories"][ref] == %{"ref" => ref, "name" => "super"}
    end
    assert Enum.uniq(refs) == refs
    refute inspect(projection["repositories"]) =~ base
  end
end
