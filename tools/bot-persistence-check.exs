[phase, expected_path] = System.argv()
case phase do
  "create" ->
    {human, _agent} = Ampd.attach_pair("bot-persistence-check")
    %{"workspace" => ws} = Ampd.Control.command(human, :open_workspace, ["Persistence test"])
    fields = %{"client_ref" => "persistent-builder", "workspace_ref" => ws["id"], "name" => "Persistent Builder", "role" => "Implementation", "instructions" => "Review changes", "group" => "Super", "provider" => "ollama"}
    %{"bot" => bot} = Ampd.Control.command(human, :register_bot, Enum.map(Ampd.BotIdentity.fields(), &fields[&1]))
    File.write!(expected_path, :erlang.term_to_binary(bot))
    IO.puts("held bot registered in isolated persistent world")
  "read" ->
    expected = expected_path |> File.read!() |> :erlang.binary_to_term([:safe])
    actual = Ampd.Loci.bot(expected["id"])
    if actual != expected, do: raise("bot identity changed across process restart")
    if Ampd.GrantRegistry.list() != [], do: raise("registration or restart granted authority")
    IO.puts("held entire runtime restart preserves bot identity without granting authority")
end
