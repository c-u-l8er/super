defmodule Ampd.BotIdentity do
  @moduledoc """
  A durable conversational identity in the existing loci store. Registration
  mints an actor name but no credential, grant, observation right or process.
  The operator may inspect the directory; an agent sees only its own identity.
  """
  @fields ~w(client_ref workspace_ref name role instructions group provider)
  @limits %{
    "client_ref" => 100,
    "name" => 320,
    "role" => 400,
    "instructions" => 16000,
    "group" => 320
  }
  def fields, do: @fields
  def within_budget?(bots), do: match?({:ok, _}, Ampd.Frame.logical_size(bots, 64 * 1024))

  def budget_refusal,
    do:
      refuse(
        "bot-directory-full",
        "Registered bot profiles exceed 64 KB. Shorten instructions before saving."
      )

  def validate(fields, state) when is_map(fields) do
    cond do
      Enum.sort(Map.keys(fields)) != Enum.sort(@fields) ->
        refuse("bot-fields-invalid", "Bot fields are incomplete or unsupported.")

      Enum.any?(@limits, fn {key, limit} ->
        value = fields[key]

        not is_binary(value) or byte_size(value) > limit or String.contains?(value, <<0>>) or
            (key != "instructions" and String.trim(value) == "")
      end) ->
        refuse("bot-fields-invalid", "Enter a name, role, group and valid instructions.")

      not Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, fields["client_ref"]) ->
        refuse("bot-client-ref-invalid", "The local bot reference is invalid.")

      fields["provider"] not in ~w(codex claude ollama openai anthropic) ->
        refuse("bot-provider-invalid", "Choose a supported provider.")

      not Map.has_key?(state["workspaces"], fields["workspace_ref"]) ->
        refuse("workspace-unknown", "Choose an existing workspace.")

      true ->
        :ok
    end
  end

  def validate(_, _), do: refuse("bot-fields-invalid", "Bot fields must be an object.")

  def refuse(code, message) do
    {:refused,
     Ampd.Refusal.new(code,
       component: "bot-identity",
       requires_human: true,
       public_message: message
     )}
  end
end
