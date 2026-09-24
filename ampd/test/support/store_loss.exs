defmodule Ampd.TestStoreLoss do
  @moduledoc """
  Lose exactly one authority store from disk, whichever backend holds it.

  A DETS store is its own file, so losing it is deleting the file. The four
  stores `Ampd.AuthorityLog` backs share one log, so losing ONE of them — the
  scenario these tests are about, "the disk loses exactly one authority store
  while the world lives on" — is the log rewritten without that store's ops,
  every other store's history intact and the records re-sequenced gaplessly.
  Deleting the whole log would lose all four and test a different world.
  """
  alias Ampd.AuthorityLog

  def lose!(dir, name) do
    if AuthorityLog.backed?(name) do
      AuthorityLog.close()
      p = AuthorityLog.path(dir)
      {:ok, records} = AuthorityLog.records(File.read!(p))

      frames =
        records
        |> Enum.map(fn r ->
          Map.update!(r, "ops", &Enum.reject(&1, fn op -> elem(op, 1) == name end))
        end)
        |> Enum.with_index(1)
        |> Enum.map(fn {r, t} -> AuthorityLog.frame(Map.put(r, "t", t)) end)

      File.write!(p, [AuthorityLog.header() | frames])
    else
      File.rm_rf!(Path.join(dir, "#{name}.dets"))
    end
  end

  @doc "Is `name` physically present on disk, in its own file or in the log?"
  def on_disk?(dir, name) do
    if AuthorityLog.backed?(name),
      do: name in AuthorityLog.present(dir),
      else: File.exists?(Path.join(dir, "#{name}.dets"))
  end
end
