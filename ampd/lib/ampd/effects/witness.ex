defmodule Ampd.Effects.Witness do
  @moduledoc """
  The durable witness log and its assembler — `wek-r3-trace@3` events,
  one JSON line each, one `:file.sync` each (E-5), **one writer**: the
  journal owner. A participant never appends; it reports its terminal to
  the owner (with its own proof), and the owner assigns `tseq`.

  One file per journal-owner incarnation, `<data_dir>/witness/<epoch>.jsonl`.
  `tseq` is gapless from 1 within a file. The file never declares its own
  expected length: `expected_tseq_end` / `crash_after_tseq` are the
  harness's, supplied to `assemble/3` — a log that could declare its own
  length could not prove it was not truncated.

  A line is written AFTER the durable fact it witnesses (the journal
  record's `Store.save`, the participant's reported terminal). A crash
  between the fact and the line loses the line, never invents one; the
  trace is then incomplete (E-1) or the attempt is LOST (E-2) — named,
  never accepted.
  """

  def dir, do: Path.join(Ampd.Store.data_dir(), "witness")
  def path(epoch), do: Path.join(dir(), epoch <> ".jsonl")

  def open(epoch) do
    File.mkdir_p!(dir())
    {:ok, fd} = :file.open(String.to_charlist(path(epoch)), [:append, :raw, :binary])
    fd
  end

  def close(nil), do: :ok
  def close(fd), do: :file.close(fd)

  @doc "Append one event. Raises if the write or the sync fails — the owner then crashes rather than acknowledging a transition its evidence cannot show."
  def append!(fd, tseq, event) when is_map(event) do
    line = JSON.encode!(Map.put(event, "tseq", tseq)) <> "\n"
    :ok = :file.write(fd, line)
    :ok = :file.sync(fd)
    :ok
  end

  # ------------------------------------------------------------ reading
  @doc "Every incarnation file in the witness dir, oldest first (by epoch sequence)."
  def files do
    case File.ls(dir()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort_by(&epoch_seq/1)
        |> Enum.map(&Path.join(dir(), &1))

      _ ->
        []
    end
  end

  defp epoch_seq(name) do
    case Regex.run(~r/^e(\d+)-/, name) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  def read(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  def epoch_of(path), do: path |> Path.basename() |> String.replace_suffix(".jsonl", "")

  # ---------------------------------------------------------- assembling
  @doc """
  Assemble a `wek-r3-trace@3` from incarnation files.

  `shape` is the HARNESS's declaration of what the run was:

    * `{:run, expected_tseq_end}` — every file concatenated into ONE run
      segment (a `journal_restart` inside it is a restart the run survived;
      `tseq` is renumbered consecutively).
    * `{:crash, crash_after_tseq}` — the first file is a run segment that
      crashed after that many events; the second file is the linked
      recovery segment. Exactly two files are expected.

  The declared numbers are compared by the verifier against what the log
  holds (E-1); a mismatch is `EVIDENCE_INCOMPLETE`, never a quiet fix.
  """
  def assemble(files, shape, revision) do
    segments =
      case shape do
        {:run, expected_end} ->
          events = files |> Enum.flat_map(&read/1) |> renumber()

          [
            %{
              "id" => "s1",
              "kind" => "run",
              "epoch" => epoch_of(hd(files)),
              "expected_tseq_end" => expected_end,
              "events" => events
            }
          ]

        {:crash, crash_after} ->
          [run, rec] = files

          [
            %{
              "id" => "s1",
              "kind" => "run",
              "epoch" => epoch_of(run),
              "crash_after_tseq" => crash_after,
              "events" => renumber(read(run))
            },
            %{
              "id" => "s2",
              "kind" => "recovery",
              "after" => "s1",
              "epoch" => epoch_of(rec),
              "events" => renumber(read(rec))
            }
          ]
      end

    %{"schema" => "wek-r3-trace@3", "super_revision" => revision, "segments" => segments}
  end

  defp renumber(events),
    do: events |> Enum.with_index(1) |> Enum.map(fn {e, i} -> Map.put(e, "tseq", i) end)
end
