defmodule Ampd.Refusal do
  @moduledoc """
  `refusal@1` — one refusal, two projections.

  A refusal naming `RECOVERY-STATE-MISSING · grant_registry: world
  w-82b8… (generation 7) …` is operationally useful and also describes the
  state of the authority store. Sending that to every local agent leaks
  recovery topology; sending `permission denied` instead produces retry
  loops, because the agent cannot tell "ask a human" from "try again".

  So neither. One structured object, projected differently per channel:

      general channel  →  code · component · retryable · requires_human
                          public_message · correlation_id
      human control    →  all of the above + operator_detail

  The agent learns *what to do*. The operator learns *what happened*.
  """

  @schema "refusal@1"

  @doc """
  Build a refusal. `public_message` must be safe for any local caller;
  everything topology-shaped belongs in `operator_detail`.

  There is **one** code, and it is the true one. C1.1.1 carried a second
  `public_code` field written at each call site, which put the disclosure
  policy in the hands of whoever happened to be constructing a refusal:
  one caller forgetting it, or setting it wrong, silently widened
  disclosure, and no test naming the *visible* code could have caught it.

  **Redaction is a property of the projection, not of the object.** See
  `agent_code/1`, which is the whole policy, in one place, exhaustively
  tested.
  """
  def new(code, opts \\ []) do
    Ampd.RefusalLog.record(%{
      "schema" => @schema,
      "code" => to_string(code),
      "component" => opts[:component],
      "retryable" => Keyword.get(opts, :retryable, false),
      "requires_human" => Keyword.get(opts, :requires_human, false),
      "public_message" => opts[:public_message] || default_message(code),
      "operator_detail" => opts[:operator_detail] || %{},
      "correlation_id" => "rf-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
    })
  end

  defp default_message("recovery-state-missing"),
    do: "Authority state is unavailable; human recovery is required."

  defp default_message("recovery-state-untrusted"),
    do: "Authority state cannot be trusted; human recovery is required."

  defp default_message("orphaned-world"),
    do: "This world's identity is unresolved; human recovery is required."

  defp default_message("world-meta-untrusted"),
    do: "This world's manifest is not valid; human recovery is required."

  defp default_message("world-meta-unsupported"),
    do: "This world was written by a newer build; human recovery is required."

  defp default_message("world-meta-migration-required"),
    do: "This world needs a migration before it can be opened; human recovery is required."

  defp default_message("unordered-authority-mutation"),
    do: "Authority may only be changed through the authority API."

  # ---- near-miss classes -------------------------------------------
  # These name what the caller should *do*. None of them names a resource,
  # a run, a workspace, or another actor: a refusal is also an answer, and
  # a caller who can ask freely can map what it is not allowed to touch by
  # reading the answers carefully. The comparison lives in operator_detail.
  defp default_message("authority-missing"),
    do: "No applicable grant covers the requested action."

  defp default_message("actor-mismatch"),
    do: "No applicable grant covers the requested action."

  defp default_message("scope-mismatch"),
    do: "No applicable grant covers the requested resource."

  defp default_message("one-shot-consumed"),
    do: "The one-shot authority for this capability has been used."

  defp default_message("run-expired"),
    do: "The grant covering this was scoped to a run that has ended."

  defp default_message("workspace-mismatch"),
    do: "The grant covering this belongs to another workspace."

  defp default_message("capability-undeclared"),
    do: "That capability is not declared by any installed pack surface."

  defp default_message("pack-not-installed"),
    do: "The pack declaring that capability is not installed."

  defp default_message("invalid-grant-duration"),
    do: "That is not a grant duration this system can enforce."

  defp default_message("grant-widening-refused"),
    do: "Approving a request may narrow it, never widen it."

  defp default_message("denied-by-default"),
    do: "That capability is denied by default; only a narrow one-shot grant can cover it."

  defp default_message("placement-denied"),
    do: "No eligible site can run this effect under the governing policy."

  defp default_message("approval-required"),
    do: "Consent for this exact intent does not exist yet."

  defp default_message("request-missing"),
    do: "This capability needs an explicit request; nothing hashes an empty intent."

  defp default_message(_), do: "The request was refused."

  @doc """
  The **entire** disclosure policy for refusal codes, in one function.

  A code is normally its own agent-facing form. `actor-mismatch` is not:
  told apart from `authority-missing` it says *somebody else holds this
  capability*, and an agent that may ask about arbitrary capabilities can
  map the rest of the machine's authority one bit at a time. Every other
  class describes the caller's own grant, the request, or the runtime.

  Adding a code that needs hiding means adding a clause here — not
  remembering a keyword at a call site three modules away.
  """
  def agent_code("actor-mismatch"), do: "authority-missing"
  def agent_code(code) when is_binary(code), do: code

  @doc """
  Project a refusal for a channel. `:human_control` sees everything; an
  agent never sees `operator_detail`, and reads `agent_code/1` as its
  `code`.
  """
  def project(nil, _origin), do: nil
  def project(r, :human_control), do: r

  def project(r, _agent) do
    r
    |> Map.put("code", agent_code(r["code"]))
    |> Map.delete("operator_detail")
  end

  @doc """
  Project a whole gateway result for a channel. The free-text `reason`
  can itself carry operator detail, so on the general channel it is
  replaced by the refusal's public message rather than merely trimmed.
  """
  def project_result(result, origin) when is_map(result) do
    case result["refusal"] do
      nil ->
        result

      r ->
        result
        |> Map.put("refusal", project(r, origin))
        |> then(fn res ->
          if origin == :human_control,
            do: res,
            else: Map.put(res, "reason", r["public_message"])
        end)
    end
  end

  def project_result(other, _origin), do: other

  @doc """
  The refusal code for a seal reason.

  Every reason string a seal can carry begins with its own code token, so
  this matches on the **prefix**. It used to test `String.contains?`, in an
  order where `"UNTRUSTED"` was checked first — and every
  `WORLD-META-UNTRUSTED · …` reason contains that substring, so it always
  matched the earlier branch. The `world-meta-untrusted` code was
  therefore unreachable: no input on this machine could produce it, and
  an invalid manifest reported itself as a damaged store, sending an
  operator to repair a `.dets` file that was never the problem.

  It lives here, once, because the same mapping was written out twice —
  in the gateway and in the ordered-mutation refusal — and only one of the
  two ever knew about `WORLD-META` at all.
  """
  def seal_code(reason) when is_binary(reason) do
    cond do
      String.starts_with?(reason, "WORLD-META-UNSUPPORTED") -> "world-meta-unsupported"
      String.starts_with?(reason, "WORLD-META-MIGRATION-REQUIRED") -> "world-meta-migration-required"
      String.starts_with?(reason, "WORLD-META-UNTRUSTED") -> "world-meta-untrusted"
      String.starts_with?(reason, "ORPHANED-WORLD") -> "orphaned-world"
      String.starts_with?(reason, "RECOVERY-STATE-UNTRUSTED") -> "recovery-state-untrusted"
      true -> "recovery-state-missing"
    end
  end
end
