defmodule Ampd.AuthorityLog.RowDigest do
  @moduledoc """
  `archive-row-digest@1`: what a retirement record commits to about each row
  it moves into the authority archive.

  ## Why

  Each archive frame carries a CRC-32. That catches an accident and nothing
  else: anything that rewrites a frame can recompute it. A copy re-framed that
  way, with a receipt's `nf_sha256` changed and a used grant made to read
  unspent, booted clean and was served as genuine (the benchmarking lane's
  `b6-2026-09-25/int-V`).

  So the store that retires a row computes this digest from its WORKING row,
  which is still authoritative at that moment, and keeps it in its retirement
  index entry. That entry is written by the same authority-log record that
  removes the row from the working list. Every read of an archived row checks
  the row against it (`Ampd.AuthorityLog.archived_row/5`, `check_batch/6`,
  `archived_rows/3`). The log and the
  archive are separate files, so the archive alone can no longer change what
  a read returns without the read saying so.

  **It is never computed from the archive.** A digest taken from what the
  archive holds would bless whatever is there. Rows retired before digests
  existed stay without one, and read as unverified.

  ## What it does not do

  It binds the archive to the log. A writer who can change both consistently
  is not stopped by it: that needs a key or an outside anchor, and neither is
  part of this.

  ## The encoding, version 1

  The digest is SHA-256 over `"archive-row-digest@1\\n"` followed by the
  canonical form of `[store, key field, key, batch, row]`, so it names the
  row's identity and the batch its retirement put it in as well as its
  content. It is stored as `"ard1:"` followed by the unpadded base64url of the
  hash: 48 printable bytes, small enough to live inside the process heap
  rather than as a shared binary.

  The canonical form is defined here, not borrowed. `:erlang.term_to_binary/2`
  with `:deterministic` is only promised stable within one OTP major release,
  and a digest has to verify after an upgrade. `Ampd.Core.canon/1` is JSON and
  has no form for an atom other than `nil`/`true`/`false`, a float or a
  tuple, and a digest has to be total over whatever a row holds. Every term
  is one tag byte, then a 32-bit big-endian length or count, then its
  content:

      a  atom           name's byte length, then the UTF-8 name
      i  integer        digit count, then the decimal digits ("-" first if negative)
      f  float          no length; the 8-byte IEEE 754 big-endian value
      b  binary         byte length, then the bytes
      t  bitstring      bit length, then the bits zero-padded to a byte
      l  proper list    element count, then each element
      L  improper list  count of heads, then each head, then the tail
      u  tuple          element count, then each element
      m  map            pair count, then each key and value, ordered by the
                        key's canonical bytes
      x  anything else  (pid, port, reference, fun) byte length, then
                        `term_to_binary/1`; never expected in a stored row,
                        and here only so that the encoding is total
  """

  @version "ard1"
  @domain "archive-row-digest@1\n"

  @doc "The version tag every digest this build writes begins with."
  def version, do: @version

  @doc """
  The digest a retirement index entry keeps for `row`: the row of `store`
  whose `field` is `key`, retired in `batch`.
  """
  def of(store, field, key, batch, row) do
    hash = :crypto.hash(:sha256, [@domain | enc([store, field, key, batch, row])])
    @version <> ":" <> Base.url_encode64(hash, padding: false)
  end

  @doc """
  Check `row` against the digest its retirement committed (`nil` when the row
  was retired without one):

      :verified
      {:unverified, why}   no digest, or one this build cannot recompute
      {:mismatch, why}     the row is not the row the log committed
  """
  def check(store, _field, key, batch, _row, nil),
    do:
      {:unverified,
       "archive-row-unverified · #{store} #{key} in batch #{batch} was retired without a content digest"}

  def check(store, field, key, batch, row, @version <> ":" <> _ = committed) do
    if of(store, field, key, batch, row) == committed,
      do: :verified,
      else:
        {:mismatch,
         "archive-row-mismatch · #{store} #{key} in batch #{batch} does not match its retirement digest"}
  end

  def check(store, _field, key, batch, _row, other) do
    tag = if is_binary(other), do: other |> String.split(":", parts: 2) |> hd(), else: inspect(other)

    {:unverified,
     "archive-row-unverified · #{store} #{key} in batch #{batch} carries a digest this build cannot check (#{tag})"}
  end

  @doc false
  # The canonical form, as iodata. Public for the tests that pin it.
  def enc(a) when is_atom(a), do: sized(?a, Atom.to_string(a))
  def enc(i) when is_integer(i), do: sized(?i, Integer.to_string(i))
  def enc(f) when is_float(f), do: <<?f, f::float-size(64)-big>>
  def enc(b) when is_binary(b), do: sized(?b, b)

  def enc(t) when is_bitstring(t) do
    bits = bit_size(t)
    pad = rem(8 - rem(bits, 8), 8)
    [<<?t, bits::32>>, <<t::bitstring, 0::size(pad)>>]
  end

  def enc(l) when is_list(l) do
    case split(l, 0, []) do
      {n, heads, []} -> [<<?l, n::32>> | Enum.map(heads, &enc/1)]
      {n, heads, tail} -> [<<?L, n::32>>, Enum.map(heads, &enc/1), enc(tail)]
    end
  end

  def enc(t) when is_tuple(t),
    do: [<<?u, tuple_size(t)::32>> | Enum.map(Tuple.to_list(t), &enc/1)]

  def enc(m) when is_map(m) do
    pairs =
      m
      |> Enum.map(fn {k, v} -> {IO.iodata_to_binary(enc(k)), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [k | enc(v)] end)

    [<<?m, map_size(m)::32>> | pairs]
  end

  def enc(other), do: sized(?x, :erlang.term_to_binary(other))

  defp sized(tag, b), do: [<<tag, byte_size(b)::32>>, b]

  # The heads of a list and what ends it: `[]` for a proper list.
  defp split([h | t], n, acc), do: split(t, n + 1, [h | acc])
  defp split(tail, n, acc), do: {n, Enum.reverse(acc), tail}
end
