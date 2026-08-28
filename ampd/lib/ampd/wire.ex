defmodule Ampd.Wire do
  @moduledoc """
  The decoder is security code.

  `Ampd.Control.command/3` dispatches on Elixir function-head patterns and
  takes an **atom** command. That is fine for callers inside the BEAM, who
  are already trusted enough to construct atoms. It is not fine for the
  first byte off a socket:

      request_effect([])        → FunctionClauseError
      approve_effect([1])       → FunctionClauseError
      preflight(42)             → FunctionClauseError

  A crash is not a refusal. It takes the connection handler down, it
  produces no `correlation_id`, and it tells the caller nothing about what
  to do — which is the exact failure mode C1.1.0 spent a round removing
  from the store layer and C1.1.2 removed from the command layer.

  So: **decoding is total.** Any term at all — any shape, any depth, any
  garbage — yields either a decoded command or a named refusal.

  ## What moved out of here in C1.1

  The vocabulary and the argument shapes used to live in this module, as
  shape checks beside `Ampd.Control`'s function heads. Both are now
  declared in `Ampd.CommandSpec`, and this module is what *applies* the
  declaration. The split is the one the review asked for:

      Ampd.CommandSpec   what may be said
      Ampd.Wire          checking that what arrived may be said
      Ampd.Control       what it means

  That inversion also removed an arity hazard rather than catching it.
  `Ampd.CommandSpec.bind/2` fills every declared field, so it emits exactly
  the declared arity and a `preflight` with one argument cannot be
  constructed through this path. The `rescue` below stays anyway: it now
  guards against a `Ampd.Control` clause this module cannot see rather than
  against a shape it failed to check, and a boundary whose safety depends
  on two modules agreeing should not also depend on them agreeing.

  ## Never `String.to_atom/1`

  Atoms are not garbage-collected and the table has a hard ceiling
  (`+t`, one million by default). A decoder that turns an incoming command
  word into an atom hands any peer a way to exhaust it and take the node
  down — a denial of service that survives the connection closing. The
  mapping is a fixed map of literal atoms in `Ampd.CommandSpec`, and
  anything not on it is `unknown-command`.

  ## What is still the transport's job

  Per-peer rate limiting, and the privileged bridge that alone may bind a
  connection to an identity — `Ampd.Bridge`. Frame size is no longer on
  that list: `Ampd.Frame` owns it, and enforces it at the socket driver.
  """

  @doc "Every command word a wire caller may send, as `{string, atom}`."
  defdelegate vocabulary, to: Ampd.CommandSpec

  @doc "The declared aggregate frame limit. Per-field limits are in `Ampd.CommandSpec`."
  defdelegate max_frame_bytes, to: Ampd.Frame, as: :max_bytes

  @doc "Maximum nesting depth of any argument."
  defdelegate max_depth, to: Ampd.Frame, as: :max_depth

  @doc """
  Decode one wire command. Total over any input.

  Returns `{:ok, {cmd_atom, positional_args}}` or `{:refused, refusal@1}`.
  `args` may be a map of named fields — the wire form — or a positional
  list, which is what in-BEAM callers use. Both are validated against the
  same declared types.
  """
  def decode(peer_id, cmd_word, args)

  def decode(peer_id, cmd_word, args) when is_binary(cmd_word) do
    cond do
      not (is_binary(peer_id) or is_nil(peer_id)) ->
        {:refused, refuse("invalid-peer-handle", %{"got" => tag(peer_id)})}

      byte_size(cmd_word) > 64 ->
        {:refused, refuse("unknown-command", %{"bytes" => byte_size(cmd_word)})}

      Ampd.Frame.depth(args) > Ampd.Frame.max_depth() ->
        {:refused,
         refuse("invalid-command-arguments",
           %{"reason" => "argument nested too deeply", "max" => Ampd.Frame.max_depth()})}

      true ->
        case Ampd.CommandSpec.bind(cmd_word, args) do
          {:ok, cmd, values} -> {:ok, {cmd, values}}
          {:error, code, detail} -> {:refused, refuse(code, detail)}
        end
    end
  end

  def decode(_peer_id, cmd_word, _args),
    do: {:refused, refuse("unknown-command", %{"got" => tag(cmd_word)})}

  @doc """
  Decode and issue. The only entry point a transport should ever call.
  """
  def command(peer_id, cmd_word, args) do
    case decode(peer_id, cmd_word, args) do
      {:refused, r} ->
        %{"allow" => false, "reason" => r["public_message"], "refusal" => project(r, peer_id)}

      {:ok, {cmd, decoded}} ->
        try do
          Ampd.Control.command(peer_id, cmd, decoded)
        rescue
          e in [FunctionClauseError, BadArityError, ArgumentError, KeyError, BadMapError] ->
            r =
              refuse("invalid-command-arguments", %{
                "command" => cmd_word,
                "arity" => length(decoded),
                "error" => inspect(e.__struct__)
              })

            %{"allow" => false, "reason" => r["public_message"], "refusal" => project(r, peer_id)}
        end
    end
  end

  # Refusals minted here are projected by the *peer's* channel where one
  # exists, and as an agent otherwise — an unidentified caller gets the
  # narrower answer, never the wider one.
  defp project(r, peer_id) do
    case Ampd.Peer.resolve(peer_id) do
      %{"channel" => :human_control} -> Ampd.Refusal.project(r, :human_control)
      _ -> Ampd.Refusal.project(r, :general)
    end
  end

  defp tag(v) when is_binary(v), do: "binary"
  defp tag(v) when is_list(v), do: "list"
  defp tag(v) when is_map(v), do: "map"
  defp tag(v) when is_integer(v), do: "integer"
  defp tag(v) when is_atom(v), do: "atom"
  defp tag(_), do: "term"

  defp refuse(code, detail) do
    Ampd.Refusal.new(code,
      component: "Ampd.Wire",
      retryable: false,
      requires_human: false,
      public_message: message(code),
      operator_detail: detail
    )
  end

  defp message("invalid-command-arguments"), do: "The command arguments were not the shape this command takes."
  defp message("invalid-peer-handle"), do: "This channel is not bound to an identity."
  defp message("identity-not-claimable"), do: "Identity comes from the connection, not from the command."
  defp message("frame-too-large"), do: "That frame is larger than this protocol accepts."
  defp message(_), do: "No such command."
end
