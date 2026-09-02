defmodule Ampd.Carrier.Terminal do
  @moduledoc """
  D.1.3c·2b — the grammar of an attach answer, and the one place a
  descriptor count is a semantic fact.

  ## Why this is not in `Ampd.Worktree.EffectChannel`

  That module knows `SCM_RIGHTS`, framing, correlation and ownership. It
  does not know what a terminal is, and teaching it would make the
  descriptor-carrying transport specific to the one operation that uses it
  today.

      EffectChannel        SCM_RIGHTS transport, ownership, correlation
      this module          what a terminal attach answer is allowed to be

  ## The cardinality is a rule, and it was previously only a sentence

  The frozen contract says:

      success   → exactly one descriptor
      refusal   → exactly zero descriptors

  and until this module existed nothing enforced it. `request_with_fd/5`
  returned whatever list arrived, so a host answering *attached* with no
  descriptor, or *refused* with one, or *attached* with two, would have
  handed a plausible-looking result to the code that is about to decide
  possession. The valid cases were tested; the malformed ones were not
  refused.

  **Every rejection closes every adopted socket.** They are already managed
  by the time they get here, so disposal is `:socket.close/1` and not a
  descriptor sink — but a rejection that returned without closing would be a
  protocol error that leaks, which is the shape this lane keeps finding.

  ## No socket list crosses into ORDERED B

  The success return is one socket, not a list of one. A caller holding a
  list has to decide what a second element would mean, and the answer —
  *this response was invalid* — belongs here, once.
  """

  alias Ampd.Worktree.EffectChannel

  @attach_request "carrier-pty-attach-request@1"
  @attach_observation "carrier-pty-attach-observation@1"

  @doc "The schema a host attach answer must carry."
  def observation_schema, do: @attach_observation

  @doc """
  Ask the host to attach to a Carrier's terminal.

  Addressed by `carrier_ref` and `carrier_epoch` — the Carrier's incarnation,
  never a pathname and never a terminal. Returns exactly what
  `interpret/2` returns.
  """
  def attach(carrier_ref, carrier_epoch)
      when is_binary(carrier_ref) and is_binary(carrier_epoch) do
    case Ampd.Bridge.carrier_endpoint() do
      nil ->
        {:error,
         "no host carrier channel is possessed — refusing to resolve and execute the host by name instead"}

      %{sock: sock, incarnation: inc} ->
        body = %{
          "schema" => @attach_request,
          "op" => "pty-attach",
          "carrier_ref" => carrier_ref,
          "carrier_epoch" => carrier_epoch
        }

        case EffectChannel.request_with_fd(
               sock,
               inc,
               body,
               EffectChannel.deadline_ms(),
               @attach_observation
             ) do
          {:ok, obs, sockets} -> interpret(obs, sockets)
          {:error, why} -> {:error, why}
        end
    end
  end

  @doc """
  The attach grammar, as a total function over an observation and the
  sockets that came with it.

  Pure and separately callable so the malformed shapes can be falsified
  without a host willing to produce them — a real host never will, which is
  exactly why nothing had checked.

      {:ok, observation, socket}    attached, and exactly one stream
      {:refused, observation}       refused, and no stream
      {:error, reason}              anything else — sockets closed
  """
  def interpret(obs, sockets) when is_map(obs) and is_list(sockets) do
    attached? = obs["attached"] == true
    refusal = obs["refused"]
    refused? = is_binary(refusal) and refusal != ""

    case {attached?, refused?, sockets} do
      {true, false, [sock]} ->
        {:ok, obs, sock}

      {false, true, []} ->
        {:refused, obs}

      # Everything below is a protocol failure, and each is named rather
      # than collapsed, because "the host answered wrongly" is not a repair
      # instruction and these have different ones.
      {true, false, []} ->
        reject(sockets, "the host reported an attachment and sent no stream descriptor")

      {true, false, many} ->
        reject(
          sockets,
          "the host reported one attachment and sent #{length(many)} stream descriptors"
        )

      {false, true, some} ->
        reject(
          sockets,
          "the host refused the attach and sent #{length(some)} stream descriptor(s) with the refusal"
        )

      {true, true, _} ->
        reject(sockets, "the host answered both attached and refused")

      {false, false, _} ->
        reject(sockets, "the host answered neither attached nor refused")
    end
  end

  defp reject(sockets, why) do
    Enum.each(sockets, &:socket.close/1)
    {:error, "the attach answer was not a valid #{@attach_observation}: #{why}"}
  end
end
