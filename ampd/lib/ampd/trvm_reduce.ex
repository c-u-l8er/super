defmodule Ampd.TrvmReduce do
  @moduledoc """
  The `trvm.reduce` capability's result contract — the one bounded
  computation Super carries through the B2 write boundary
  (`wek/b2/NEXT_COMPUTATION_PROPOSAL.md` §3.3–§3.4).

  Three things live here, and nothing else:

    * `adapter/2` — wraps a reducer call (the managed-Node executor over the
      checked Wasm host, supplied by the caller as a function so this module
      never names an executor) as the `adapter` argument of
      `Ampd.Gateway.perform/5`. It returns a RESULT MAP only when the host
      reported a `candidate` with `workerExited: true` and the guardian reaped
      its child (`{:ok, ...}` from the bridge); on every other outcome it
      RAISES, so `perform_attempt` journals UNKNOWN with the reason and never
      calls `emit_receipt`.
    * `validate!/2` — the strict shape and identity checks of §3.3's table:
      the re-hashed term must equal the request's, the digest and length are
      shaped, `interactions` is bounded and informational, and the world
      identifiers are copied from the request, never from the host.
    * `receipt_fields/2` — the per-capability allowlist `Ampd.Gateway` merges
      UNDER its fixed fields. Empty for every other capability.

  **Result honesty is not decided here.** A well-shaped wrong digest passes
  every check below (falsifier F-D); the harness's reference comparison owns
  that, and the receipt carries the digest so the comparison has something to
  read.
  """

  @max_output 1_048_576
  @max_interactions 50_000_000
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @allowlist %{
    "trvm.reduce" =>
      ~w(term_sha256 nf_sha256 nf_bytes interactions worker_exited job_retired guardian_status sem scenario_digest epoch
         executor host port module_sha256)
  }
  # The executor's identity: which kind produced the result, and -- for a daemon on another host -- where and which
  # module it reports. Present when the executor says so; a receipt without them is the managed one-shot kind's.
  @optional ~w(host port module_sha256)

  @doc "The receipt-carried result fields a capability may carry; `[]` for all others."
  def allowlist(cap), do: Map.get(@allowlist, cap, [])

  @doc """
  The result fields the receipt carries for `cap`, validated by shape, unknown
  keys dropped. `nil` (an adapter that returned nothing) carries nothing.
  """
  def receipt_fields(cap, result) when is_map(result) do
    result
    |> Map.take(allowlist(cap))
    |> Enum.filter(fn {k, v} -> shaped?(k, v) end)
    |> Map.new()
  end

  def receipt_fields(_cap, _), do: %{}

  defp shaped?("term_sha256", v), do: is_binary(v) and Regex.match?(@hex64, v)
  defp shaped?("nf_sha256", v), do: is_binary(v) and Regex.match?(@hex64, v)
  defp shaped?("nf_bytes", v), do: is_integer(v) and v >= 1 and v <= @max_output
  defp shaped?("interactions", v), do: is_integer(v) and v >= 0 and v <= @max_interactions
  defp shaped?("worker_exited", v), do: is_boolean(v)
  defp shaped?("job_retired", v), do: is_boolean(v)
  defp shaped?("guardian_status", v), do: v == 0
  defp shaped?("sem", v), do: is_binary(v) and String.starts_with?(v, "sem-")
  defp shaped?("scenario_digest", v), do: is_binary(v)
  defp shaped?("epoch", v), do: is_integer(v) and v >= 1
  defp shaped?("executor", v), do: v in ~w(managed resident remote)
  defp shaped?("host", v), do: is_binary(v) and byte_size(v) in 1..253
  defp shaped?("port", v), do: is_integer(v) and v in 1..65535
  defp shaped?("module_sha256", v), do: is_binary(v) and Regex.match?(@hex64, v)
  defp shaped?(_, _), do: false

  @doc """
  Build the adapter for one request. `reduce` is `(term_bytes -> outcome)` where
  outcome is the bridge's answer: `{:ok, %{candidate: host_result}}` or
  `{:refused, reason}`. `params` are the request's params (`sem`,
  `scenario_digest`, `epoch`, `term_sha256`, `term_bytes`); `term` is the
  exact bytes to reduce — carried beside the request, never inside it, since
  the params are the effect's idempotency key.
  """
  def adapter(reduce, params, term)
      when is_function(reduce, 1) and is_map(params) and is_binary(term) do
    fn _attempt -> result_from(reduce.(term), term, params) end
  end

  @doc """
  The result map from a bridge outcome, or a raise naming the host outcome.
  Only a reaped child (`{:ok, ...}`) carrying a `candidate` with
  `workerExited: true` becomes a result.
  """
  def result_from({:ok, %{candidate: %{"status" => "candidate"} = c}}, term, params)
      when :erlang.map_get("workerExited", c) == true or
             :erlang.map_get("jobRetired", c) == true do
    # The forward rule (TRVM resident README §6): a reaped one-shot worker (`workerExited: true`) OR a retired job id
    # from a live resident worker (`jobRetired: true`). The receipt says which; the reference gate stays the honesty check.
    output = c["output"]

    unless is_binary(output), do: raise("trvm.reduce: host candidate without output")

    validate!(
      %{
        "term_sha256" => sha256(term),
        "nf_sha256" => sha256(output),
        "nf_bytes" => byte_size(output),
        "interactions" => c["interactions"],
        "worker_exited" => c["workerExited"] == true,
        "job_retired" => c["jobRetired"] == true,
        "guardian_status" => 0,
        "sem" => params["sem"],
        "scenario_digest" => params["scenario_digest"],
        "epoch" => params["epoch"],
        "executor" => c["executor"] || "managed"
      }
      |> Map.merge(Map.take(c, @optional)),
      params
    )
  end

  def result_from({:ok, %{candidate: c}}, _term, _params),
    do:
      raise(
        "trvm.reduce: host outcome #{inspect(c["status"])} is not a candidate with a confirmed worker exit"
      )

  def result_from({:refused, reason}, _term, _params),
    do: raise("trvm.reduce: executor refused: #{inspect(reason)}")

  def result_from(other, _term, _params),
    do: raise("trvm.reduce: unrecognised executor outcome #{inspect(other)}")

  @doc "Refuse to commit (raise) unless every field is shaped and the identities match the request."
  def validate!(result, params) do
    for k <- allowlist("trvm.reduce"), not (k in @optional and not Map.has_key?(result, k)) do
      unless shaped?(k, result[k]),
        do: raise("trvm.reduce: result field #{k} is not shaped: #{inspect(result[k])}")
    end

    unless result["term_sha256"] == params["term_sha256"],
      do: raise("trvm.reduce: the reduced term is not the requested term")

    for k <- ~w(sem scenario_digest epoch) do
      unless result[k] == params[k],
        do: raise("trvm.reduce: result #{k} does not equal the request's")
    end

    result
  end

  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
