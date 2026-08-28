defmodule Ampd.Frame do
  @moduledoc """
  Bytes on the wire, and the two limits a field limit cannot express.

  ## The size invariant that was not holding

  `Ampd.Wire` refused an argument over 64 KB by checking each **top-level**
  argument:

      is_binary(a) and byte_size(a) > 64_000

  A 5 MB string is not a top-level binary once it is a value inside a map,
  and `request_grant`'s third argument is a map. So this was accepted, and
  stored:

      request_grant("github.pr.merge", "traaviis/trvm",
                    %{"reason" => String.duplicate("A", 5_242_880)})

  Reproduced before it was fixed: it minted `gq_0001` carrying 5 242 880
  bytes of reason. The nesting check walked the same map for *depth* and
  never looked at what the leaves weighed.

  Two limits close it, and they are different limits:

    * **`logical_size/2`** — a recursive walk, so a field limit means the
      field, not the field's first level. `Ampd.CommandSpec` uses it for
      every `{:map, n}` field.

    * **`max_bytes/0`** — the whole encoded frame, 256 KB. A per-field
      limit cannot bound a command with eight fields, and "the size of an
      arbitrary Elixir term" is a fuzzy thing to write a protocol against.
      The encoded frame is not fuzzy: it is the bytes that arrived.

  The frame limit is enforced **by the socket driver**, via `packet: 4`
  plus `packet_size`, so an oversized frame is refused before its bytes are
  copied into the VM. A limit that allocates the thing it is rejecting is a
  limit that makes the attack cheaper.

  ## The schemas

      command@1               client → runtime   a command, named args
      reply@1                 runtime → client   the result of one command
      projection-snapshot@1   runtime → client   pushed, carries a revision
      hello@1                 runtime → client   sent once, on accept

  **No frame carries an actor, and none carries a peer handle.** The
  connection determines the identity — see `Ampd.Transport`. There is no
  field in which to claim one, which is a stronger property than validating
  a claim, and it is why the acceptance falsifier for impersonation is
  "unphrasable" rather than "refused".
  """

  @max_bytes 256 * 1024
  @max_depth 12

  def max_bytes, do: @max_bytes
  def max_depth, do: @max_depth

  @doc """
  Recursive byte weight of a term, short-circuiting at `cap`.

  Returns `{:ok, n}` when the term weighs `n ≤ cap`, or `{:over, n}` with
  the partial sum that already exceeded it. Short-circuiting matters: the
  point of a limit is to stop before doing the work, and summing a hostile
  5 MB term to find out it is 5 MB is doing the work.

  Keys are counted as well as values. A map of a hundred thousand empty
  string values weighs what its keys weigh, and a limit that ignores keys
  is a limit with a hole in it the shape of the keys.
  """
  def logical_size(term, cap \\ @max_bytes) do
    case walk(term, 0, cap) do
      n when n > cap -> {:over, n}
      n -> {:ok, n}
    end
  end

  defp walk(_term, acc, cap) when acc > cap, do: acc
  defp walk(v, acc, _cap) when is_binary(v), do: acc + byte_size(v)
  defp walk(v, acc, _cap) when is_atom(v), do: acc + 8
  defp walk(v, acc, _cap) when is_number(v), do: acc + 8

  defp walk(v, acc, cap) when is_list(v) do
    Enum.reduce_while(v, acc, fn x, a ->
      a2 = walk(x, a, cap)
      if a2 > cap, do: {:halt, a2}, else: {:cont, a2}
    end)
  end

  defp walk(v, acc, cap) when is_map(v) and not is_struct(v) do
    Enum.reduce_while(v, acc, fn {k, x}, a ->
      a2 = k |> walk(a, cap) |> then(&walk(x, &1, cap))
      if a2 > cap, do: {:halt, a2}, else: {:cont, a2}
    end)
  end

  defp walk(_v, acc, _cap), do: acc + 8

  @doc "Nesting depth of a term, capped so a hostile shape is not walked to the bottom."
  def depth(v, d \\ 0)
  def depth(_, d) when d > @max_depth, do: d

  def depth(v, d) when is_map(v) and not is_struct(v),
    do: v |> Map.values() |> Enum.reduce(d, fn x, a -> max(a, depth(x, d + 1)) end)

  def depth(v, d) when is_list(v), do: Enum.reduce(v, d, fn x, a -> max(a, depth(x, d + 1)) end)
  def depth(_v, d), do: d

  @doc """
  Decode one frame's bytes.

  Total over any input: any bytes at all yield a decoded frame or a named
  error. Returns `{:ok, %{"command" => word, "args" => args, ...}}` or
  `{:error, code, detail}`.
  """
  def decode(bytes) when is_binary(bytes) do
    cond do
      byte_size(bytes) > @max_bytes ->
        {:error, "frame-too-large", %{"bytes" => byte_size(bytes), "max" => @max_bytes}}

      true ->
        case safe_json(bytes) do
          {:ok, %{} = f} -> validate(f)
          {:ok, other} -> {:error, "invalid-frame", %{"reason" => "frame must be an object", "got" => kind(other)}}
          :error -> {:error, "invalid-frame", %{"reason" => "not valid JSON"}}
        end
    end
  end

  def decode(_), do: {:error, "invalid-frame", %{"reason" => "frame must be bytes"}}

  defp validate(f) do
    cond do
      depth(f) > @max_depth ->
        {:error, "invalid-frame", %{"reason" => "frame nested too deeply", "max" => @max_depth}}

      f["schema"] != "command@1" ->
        {:error, "invalid-frame",
         %{"reason" => "unknown frame schema", "got" => to_string(f["schema"] || "<absent>"),
           "expected" => "command@1"}}

      not is_binary(f["command"]) ->
        {:error, "invalid-frame", %{"reason" => "command must be a string"}}

      byte_size(f["command"]) > 64 ->
        {:error, "unknown-command", %{"bytes" => byte_size(f["command"])}}

      # There is deliberately no `peer_id`, no `actor`, and no `channel`
      # field. A frame carrying one is refused rather than ignored: a
      # client that thinks it is choosing its identity must be told it is
      # not, and silently dropping the field teaches it that it worked.
      Enum.any?(~w(peer_id actor channel), &Map.has_key?(f, &1)) ->
        {:error, "identity-not-claimable",
         %{"reason" => "identity comes from the connection, never from a frame",
           "offending_fields" => Enum.filter(~w(peer_id actor channel), &Map.has_key?(f, &1))}}

      not (is_map(f["args"]) or is_list(f["args"]) or is_nil(f["args"])) ->
        {:error, "invalid-command-arguments", %{"reason" => "args must be an object", "got" => kind(f["args"])}}

      not (is_nil(f["client_request_id"]) or
             (is_binary(f["client_request_id"]) and byte_size(f["client_request_id"]) <= 128)) ->
        {:error, "invalid-frame", %{"reason" => "client_request_id must be a short string"}}

      true ->
        {:ok,
         %{
           "command" => f["command"],
           "args" => f["args"] || %{},
           "client_request_id" => f["client_request_id"]
         }}
    end
  end

  # The JSON decoder is not ours and a hostile document is the first thing
  # a socket sees. `[[[[…]]]]` 60 000 deep is 60 KB — well under the frame
  # limit — and recursive descent on it is a stack the caller did not
  # choose to spend. Catching here keeps "decoding is total" true of the
  # library too, not just of our own clauses.
  defp safe_json(bytes) do
    try do
      case JSON.decode(bytes) do
        {:ok, v} -> {:ok, v}
        {:error, _} -> :error
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  @doc "Encode a frame. Refuses to emit one larger than the limit it enforces on the way in."
  def encode(map) when is_map(map) do
    body = JSON.encode!(map)

    if byte_size(body) > @max_bytes,
      do: {:error, "frame-too-large", %{"bytes" => byte_size(body), "max" => @max_bytes}},
      else: {:ok, body}
  end

  @doc """
  Encode, or encode a refusal *about* being unable to encode.

  A projection that has grown past the frame limit must not become
  silence. The client is told the frame was too large and what its
  revision was, so it can ask for a narrower read rather than waiting for
  a push that will never come.
  """
  def encode!(map) do
    case encode(map) do
      {:ok, body} ->
        body

      {:error, code, detail} ->
        JSON.encode!(%{
          "schema" => "reply@1",
          "client_request_id" => map["client_request_id"],
          "result" => %{
            "allow" => false,
            "reason" => "The runtime's answer did not fit in one frame.",
            "refusal" => Ampd.Refusal.new(code,
              component: "Ampd.Frame",
              retryable: false,
              requires_human: false,
              public_message: "The runtime's answer did not fit in one frame.",
              operator_detail: detail)
          }
        })
    end
  end

  defp kind(v) when is_binary(v), do: "string"
  defp kind(v) when is_list(v), do: "array"
  defp kind(v) when is_map(v), do: "object"
  defp kind(v) when is_number(v), do: "number"
  defp kind(v) when is_boolean(v), do: "boolean"
  defp kind(nil), do: "null"
  defp kind(_), do: "term"
end
