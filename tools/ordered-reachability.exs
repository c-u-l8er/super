# ordered-reachability — which cross-process crossings can execute inside the
# total order, derived from compiled BEAM abstract code rather than from grep.
#
# C1.0b·2 shipped a per-module count of `GenServer.call(__MODULE__, …)` as a
# ratchet. A ratchet cannot grow unnoticed, which is worth having, and it is
# the wrong shape for a completeness claim: it counts client helpers no
# transaction ever reaches and misses every call made to another module by
# name. This asks the question the ratchet cannot:
#
#     which cross-process calls are transitively reachable while executing
#     an AuthorityCoordinator ordered transaction or ordered observation?
#
# The input is `_build/*/lib/ampd/ebin/*.beam`, so what is measured is what
# the compiler produced — including calls the source spells through a `|>`,
# a macro, or a wrapper three modules away.
#
# WHERE IT CANNOT SEE, IT SAYS SO. Every dynamic dispatch — `apply/3`, a fun
# value called through a variable, a remote call whose module is computed —
# is emitted in `opaque`, because a census that silently drops what it cannot
# resolve is a census that reports completeness it does not have.

defmodule Census do
  # Reached through one of these, the path ENDS: the callee runs in another
  # process. What that process does next is its own risk and is reported
  # separately as fan-out.
  @crossings %{
    {GenServer, :call, 2} => "GenServer.call/2",
    {GenServer, :call, 3} => "GenServer.call/3",
    {GenServer, :cast, 2} => "GenServer.cast/2",
    {GenServer, :stop, 1} => "GenServer.stop/1",
    {GenServer, :stop, 2} => "GenServer.stop/2",
    {GenServer, :stop, 3} => "GenServer.stop/3",
    {GenServer, :multi_call, 2} => "GenServer.multi_call/2",
    {GenServer, :multi_call, 3} => "GenServer.multi_call/3",
    {GenServer, :multi_call, 4} => "GenServer.multi_call/4",
    {:gen_server, :call, 2} => ":gen_server.call/2",
    {:gen_server, :call, 3} => ":gen_server.call/3",
    {:gen_server, :send_request, 2} => ":gen_server.send_request/2",
    {:gen_statem, :call, 2} => ":gen_statem.call/2",
    {:gen_statem, :call, 3} => ":gen_statem.call/3",
    {Agent, :get, 2} => "Agent.get/2",
    {Agent, :get, 3} => "Agent.get/3",
    {Agent, :update, 2} => "Agent.update/2",
    {Agent, :update, 3} => "Agent.update/3",
    {Agent, :get_and_update, 2} => "Agent.get_and_update/2",
    {Task, :await, 1} => "Task.await/1",
    {Task, :await, 2} => "Task.await/2",
    {Task, :await_many, 1} => "Task.await_many/1",
    {Task, :await_many, 2} => "Task.await_many/2",
    {Task, :async, 1} => "Task.async/1",
    {Task, :async, 3} => "Task.async/3",
    {Task.Supervisor, :async, 2} => "Task.Supervisor.async/2",
    {Task.Supervisor, :async_nolink, 2} => "Task.Supervisor.async_nolink/2",
    {Task.Supervisor, :start_child, 2} => "Task.Supervisor.start_child/2",
    {:erpc, :call, 4} => ":erpc.call/4",
    {:rpc, :call, 4} => ":rpc.call/4",
    {DynamicSupervisor, :start_child, 2} => "DynamicSupervisor.start_child/2",
    {DynamicSupervisor, :terminate_child, 2} => "DynamicSupervisor.terminate_child/2",
    {Supervisor, :start_child, 2} => "Supervisor.start_child/2",
    {Supervisor, :terminate_child, 2} => "Supervisor.terminate_child/2",
    {Supervisor, :restart_child, 2} => "Supervisor.restart_child/2",
    {Supervisor, :delete_child, 2} => "Supervisor.delete_child/2",
    {:dets, :insert, 2} => ":dets.insert/2",
    {:dets, :lookup, 2} => ":dets.lookup/2",
    {:dets, :delete, 2} => ":dets.delete/2",
    {:dets, :sync, 1} => ":dets.sync/1",
    {:dets, :open_file, 2} => ":dets.open_file/2",
    {:dets, :close, 1} => ":dets.close/1",
    {:dets, :match_object, 2} => ":dets.match_object/2",
    {:dets, :foldl, 3} => ":dets.foldl/3"
  }

  # The boundary itself. Reaching one of these IS the converted path.
  @converted %{
    {Ampd.Participant, :call, 3} => "Ampd.Participant.call/3",
    {Ampd.Participant, :call, 4} => "Ampd.Participant.call/4"
  }

  # A crossing of the operating system, not of a BEAM process. A failure here
  # is a return value or an exception in THIS process; it cannot exit the
  # caller from outside, so it is not a participant. Recorded, not required.
  @os_boundary %{
    {:socket, :send, 2} => ":socket.send/2",
    {:socket, :send, 3} => ":socket.send/3",
    {:socket, :sendmsg, 2} => ":socket.sendmsg/2",
    {:socket, :sendmsg, 3} => ":socket.sendmsg/3",
    {:socket, :recv, 2} => ":socket.recv/2",
    {:socket, :recv, 3} => ":socket.recv/3",
    {:socket, :recv, 4} => ":socket.recv/4",
    {:socket, :recvmsg, 1} => ":socket.recvmsg/1",
    {:socket, :recvmsg, 2} => ":socket.recvmsg/2",
    {:socket, :recvmsg, 4} => ":socket.recvmsg/4",
    {:socket, :recvmsg, 5} => ":socket.recvmsg/5",
    {:socket, :connect, 2} => ":socket.connect/2",
    {:socket, :accept, 1} => ":socket.accept/1",
    {:socket, :accept, 2} => ":socket.accept/2",
    {:socket, :close, 1} => ":socket.close/1",
    {:gen_tcp, :send, 2} => ":gen_tcp.send/2",
    {:gen_tcp, :recv, 2} => ":gen_tcp.recv/2",
    {:gen_tcp, :recv, 3} => ":gen_tcp.recv/3",
    {Port, :command, 2} => "Port.command/2",
    {Port, :close, 1} => "Port.close/1",
    {System, :cmd, 2} => "System.cmd/2",
    {System, :cmd, 3} => "System.cmd/3"
  }

  # A `handle_*` runs in the participant, not in the caller. Reaching a
  # module through a crossing must not walk into its server half.
  @server_callbacks [
    :handle_call,
    :handle_cast,
    :handle_info,
    :handle_continue,
    :init,
    :terminate,
    :code_change
  ]

  def crossings, do: @crossings
  def converted, do: @converted
  def os_boundary, do: @os_boundary
  def server_callbacks, do: @server_callbacks

  # ---------------------------------------------------------------- loading

  def load(ebin) do
    ebin
    |> Path.join("Elixir.Ampd*.beam")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn beam, acc ->
      {:ok, {mod, [abstract_code: {:raw_abstract_v1, forms}]}} =
        :beam_lib.chunks(String.to_charlist(beam), [:abstract_code])

      src =
        Enum.find_value(forms, fn
          {:attribute, _, :file, {f, _}} -> List.to_string(f)
          _ -> nil
        end)

      Enum.reduce(forms, acc, fn
        {:function, _, name, arity, clauses}, a ->
          Map.put(a, {mod, name, arity}, %{clauses: clauses, src: src})

        _, a ->
          a
      end)
    end)
  end

  # ------------------------------------------------------------------ walk
  #
  # One generic fold over the Erlang abstract format. Everything below reads
  # the same node stream: calls, fun literals, and the places the stream
  # stops being readable.

  def scan(ast, self_mod) do
    ast |> nodes(self_mod) |> Enum.reverse()
  end

  defp nodes(ast, self_mod), do: walk(ast, self_mod, [])

  defp walk(list, m, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, m, &2))

  # A remote call with both module and function literal — resolvable.
  defp walk({:call, loc, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args}, m, acc) do
    acc = [{:call, {mod, fun, length(args)}, line(loc), args} | acc]
    walk(args, m, acc)
  end

  # A remote call whose module or function is computed. NOT resolvable.
  defp walk({:call, loc, {:remote, _, modx, funx}, args}, m, acc) do
    acc = [{:opaque, :computed_remote, line(loc), {shape(modx), shape(funx)}} | acc]
    walk([modx, funx | args], m, acc)
  end

  # A local call — same module.
  defp walk({:call, loc, {:atom, _, fun}, args}, m, acc) do
    acc = [{:call, {m, fun, length(args)}, line(loc), args} | acc]
    walk(args, m, acc)
  end

  # Applying a value held in a variable: a fun the census cannot follow.
  defp walk({:call, loc, {:var, _, v}, args}, m, acc) do
    acc = [{:opaque, :fun_value, line(loc), {v, length(args)}} | acc]
    walk(args, m, acc)
  end

  defp walk({:call, loc, other, args}, m, acc) do
    acc = [{:opaque, :computed_callee, line(loc), shape(other)} | acc]
    walk([other | args], m, acc)
  end

  # A captured named function — `&Mod.f/1`. Resolvable, and it is a *value*,
  # so it is recorded as a reference rather than a call: whether it runs
  # depends on who holds it.
  defp walk({:fun, loc, {:function, {:atom, _, mod}, {:atom, _, f}, {:integer, _, a}}}, _m, acc),
    do: [{:capture, {mod, f, a}, line(loc)} | acc]

  defp walk({:fun, loc, {:function, f, a}}, m, acc) when is_atom(f) and is_integer(a),
    do: [{:capture, {m, f, a}, line(loc)} | acc]

  defp walk({:fun, _loc, {:clauses, cs}}, m, acc), do: walk(cs, m, acc)
  defp walk({:named_fun, _loc, _n, cs}, m, acc), do: walk(cs, m, acc)

  defp walk(t, m, acc) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.reduce(acc, &walk(&1, m, &2))

  defp walk(_, _m, acc), do: acc

  defp shape({:atom, _, a}), do: a
  defp shape({:var, _, v}), do: {:var, v}
  defp shape(other) when is_tuple(other), do: elem(other, 0)
  defp shape(other), do: other

  def line({l, _c}), do: l
  def line(l) when is_integer(l), do: l
  def line(kw) when is_list(kw), do: line(Keyword.get(kw, :location, 0))
  def line(_), do: 0
end

# --------------------------------------------------------------------- roots
#
# The ordered region is entered in exactly three ways, and the closure it
# runs comes from the CALLER. So the roots are not functions of the
# coordinator: they are the `fn` literals handed to it, wherever they are
# written — plus the coordinator's own body, which runs on every operation.

defmodule Roots do
  @entries [
    {Ampd.AuthorityCoordinator, :transact, 1, :transact},
    {Ampd.AuthorityCoordinator, :transact, 2, :transact},
    {Ampd.AuthorityCoordinator, :transact, 3, :transact},
    {Ampd.AuthorityCoordinator, :observe, 1, :observe},
    {Ampd.AuthorityCoordinator, :observe, 2, :observe},
    {Ampd.AuthorityCoordinator, :observe_once, 1, :observe_once},
    {Ampd.AuthorityCoordinator, :observe_once, 2, :observe_once},
    {Ampd.Authority, :tx, 1, :transact},
    {Ampd.Authority, :tx, 2, :transact},
    # `Ampd.Projection.framed/2` runs its closure OUTSIDE the order when the
    # optimistic seqlock settles and INSIDE it when it does not — and the
    # pessimistic path is not exotic: it is what a busy world produces. A
    # crossing reachable only on that path is still reachable.
    {Ampd.Projection, :framed, 2, :observe},
    {Ampd.Projection, :framed_once, 2, :observe_once}
  ]

  # CHECKED AND NOT AN ENTRY POINT. `Ampd.Authority.in_world/2` reads like
  # one — `Ampd.Control` wraps the whole of `dispatch/3` in it — and it is
  # not: it writes `:ampd_expected_world` into the process dictionary and
  # calls `fun.()` in the CALLER. What makes dispatch ordered is the
  # `Projection.framed/2` inside that closure, not `in_world` around it.
  # Treating it as an entry admitted every command handler as ordered and
  # inflated this census by a factor of three.
  @not_entries [{Ampd.Authority, :in_world, 2}]

  def not_entries, do: @not_entries

  def entry_kinds do
    Map.new(@entries, fn {m, f, a, k} -> {{m, f, a}, k} end)
  end

  # The coordinator's own ordered region: everything `handle_call({:tx…})`
  # and the observe handlers execute is inside the total order too, and a
  # crossing there is reachable on EVERY operation rather than on one.
  def coordinator_seeds do
    [
      {Ampd.AuthorityCoordinator, :handle_call, 3},
      {Ampd.AuthorityCoordinator, :handle_continue, 2},
      {Ampd.AuthorityCoordinator, :handle_info, 2}
    ]
  end

  def find(defs) do
    kinds = entry_kinds()

    for {{mod, fun, ar}, %{clauses: cs}} <- defs,
        binds = bindings(cs),
        node <- Census.scan(cs, mod),
        match?({:call, _, _, _}, node),
        {:call, target, ln, args} = node,
        kind = Map.get(kinds, target),
        kind != nil,
        # `transact/1` calling `transact/3`, `observe/1` calling `observe/2`,
        # `framed/2` calling `do_framed/3`: an entry forwarding to itself is
        # plumbing. Admitting it as an imprecise root re-admits the whole
        # coordinator as if it were somebody's closure.
        not Map.has_key?(kinds, {mod, fun, ar}),
        root <- closure_roots(mod, fun, ar, kind, target, ln, args, binds) do
      root
    end
  end

  # `transact(fn -> … end)` gives an exact root: only the closure body is
  # inside the order. `transact(f)` where `f` is a variable does not — the
  # census cannot see what it holds, so the whole enclosing function is
  # admitted as a root and the imprecision is RECORDED rather than hidden.
  defp closure_roots(mod, fun, ar, kind, target, ln, args, binds) do
    case fun_arg(target, args, binds) do
      {:literal, cs} ->
        [
          %{
            id: "#{inspect(mod)}.#{fun}/#{ar}@#{ln}",
            kind: kind,
            enclosing: "#{inspect(mod)}.#{fun}/#{ar}",
            module: mod,
            line: ln,
            precise: true,
            body: cs
          }
        ]

      {:capture, {cm, cf, ca}} ->
        [
          %{
            id: "#{inspect(mod)}.#{fun}/#{ar}@#{ln}->&#{inspect(cm)}.#{cf}/#{ca}",
            kind: kind,
            enclosing: "#{inspect(mod)}.#{fun}/#{ar}",
            module: mod,
            line: ln,
            precise: true,
            seed: {cm, cf, ca},
            body: []
          }
        ]

      :opaque ->
        [
          %{
            id: "#{inspect(mod)}.#{fun}/#{ar}@#{ln}?",
            kind: kind,
            enclosing: "#{inspect(mod)}.#{fun}/#{ar}",
            module: mod,
            line: ln,
            precise: false,
            body: []
          }
        ]
    end
  end

  # `in_world/2` takes the lineage first and the closure second; every other
  # entry takes the closure first.
  defp fun_arg(t, args, binds) do
    case pick(t, args) do
      nil -> :opaque
      a -> classify(a, binds)
    end
  end

  defp pick({Ampd.Projection, :framed, 2}, [_, a]), do: a
  defp pick({Ampd.Projection, :framed_once, 2}, [_, a]), do: a
  defp pick(_, [a | _]), do: a
  defp pick(_, []), do: nil

  defp classify({:fun, _, {:clauses, cs}}, _), do: {:literal, cs}

  defp classify({:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, _),
    do: {:capture, {m, f, a}}

  # `run = fn -> dispatch(peer, cmd, args) end` then `framed(lineage, run)`.
  # The closure is a variable at the call site and a literal three lines
  # above it, in the same body. Not resolving it made `Ampd.Control`'s whole
  # command dispatch — every read command in the tree — an imprecise root.
  defp classify({:var, _, v}, binds) do
    case Map.fetch(binds, v) do
      {:ok, cs} -> {:literal, cs}
      :error -> :opaque
    end
  end

  defp classify(_, _), do: :opaque

  @doc "Every `Var = fn … end` in a function body, so a call site can resolve one."
  def bindings(ast), do: collect(ast, %{})

  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)

  defp collect({:match, _, {:var, _, v}, {:fun, _, {:clauses, cs}}}, acc),
    do: collect(cs, Map.put(acc, v, cs))

  defp collect(t, acc) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.reduce(acc, &collect/2)

  defp collect(_, acc), do: acc
end

# ------------------------------------------------------------------- closure

defmodule Reach do
  def run(defs, roots) do
    seeds =
      Enum.flat_map(roots, fn r ->
        from_body =
          r.body
          |> Census.scan(r.module)
          |> Enum.flat_map(fn
            {:call, t, ln, _} -> [{t, ln}]
            {:capture, t, ln} -> [{t, ln}]
            _ -> []
          end)

        from_seed = if r[:seed], do: [{r.seed, r.line}], else: []

        # An imprecise root admits its whole enclosing function.
        from_enclosing =
          if r.precise do
            []
          else
            case Map.fetch(defs, split(r.enclosing)) do
              {:ok, %{}} -> [{split(r.enclosing), r.line}]
              _ -> []
            end
          end

        Enum.map(from_body ++ from_seed ++ from_enclosing, fn {t, ln} -> {r.id, t, ln} end)
      end)

    coord_seeds =
      for mfa <- Roots.coordinator_seeds(), Map.has_key?(defs, mfa) do
        {"AuthorityCoordinator@ordered-region", mfa, 0}
      end

    walk(defs, seeds ++ coord_seeds)
  end

  # **This was wrong and it failed silently.** It built `:"Ampd.Control"`
  # where the compiled atom is `:"Elixir.Ampd.Control"`, so every
  # imprecise-root fallback `Map.fetch`ed nothing and admitted nothing —
  # the census reported a smaller reachable set BECAUSE it could not see,
  # which is the exact failure mode this artifact exists to make loud.
  defp split(str) do
    [modfun, ar] = String.split(str, "/")
    parts = String.split(modfun, ".")
    {mod_parts, [fun]} = Enum.split(parts, length(parts) - 1)
    {Module.concat(mod_parts), String.to_atom(fun), String.to_integer(ar)}
  end

  defp walk(defs, seeds) do
    init = %{seen: MapSet.new(), crossings: [], opaque: [], reached: MapSet.new()}

    Enum.reduce(seeds, init, fn {root, mfa, _ln}, acc ->
      descend(defs, mfa, root, [root], acc)
    end)
  end

  defp descend(defs, {mod, fun, ar} = mfa, root, path, acc) do
    key = {root, mfa}

    cond do
      MapSet.member?(acc.seen, key) ->
        acc

      # A crossing terminates the path: what follows runs elsewhere.
      Map.has_key?(Census.crossings(), mfa) or Map.has_key?(Census.converted(), mfa) or
          Map.has_key?(Census.os_boundary(), mfa) ->
        acc

      not Map.has_key?(defs, mfa) ->
        acc

      # Never walk into a module's server half.
      fun in Census.server_callbacks() and mod != Ampd.AuthorityCoordinator ->
        acc

      true ->
        acc = %{acc | seen: MapSet.put(acc.seen, key), reached: MapSet.put(acc.reached, mfa)}
        %{clauses: cs} = Map.fetch!(defs, mfa)
        here = "#{inspect(mod)}.#{fun}/#{ar}"

        Enum.reduce(Census.scan(cs, mod), acc, fn
          {:call, target, ln, args}, a ->
            visit(defs, target, ln, args, root, path ++ [here], a)

          {:capture, target, ln}, a ->
            visit(defs, target, ln, [], root, path ++ [here], a)

          {:opaque, why, ln, detail}, a ->
            %{
              a
              | opaque: [
                  %{root: root, in: here, at: ln, why: why, detail: inspect(detail)} | a.opaque
                ]
            }
        end)
    end
  end

  defp visit(defs, target, ln, args, root, path, acc) do
    cond do
      name = Map.get(Census.crossings(), target) ->
        record(acc, root, path, target, name, ln, args, :beam)

      name = Map.get(Census.converted(), target) ->
        record(acc, root, path, target, name, ln, args, :converted)

      name = Map.get(Census.os_boundary(), target) ->
        record(acc, root, path, target, name, ln, args, :os)

      true ->
        descend(defs, target, root, path, acc)
    end
  end

  defp record(acc, root, path, {_m, _f, _a}, primitive, ln, args, kind) do
    site = List.last(path) || root

    c = %{
      root: root,
      site: site,
      path: path,
      primitive: primitive,
      kind: kind,
      at: ln,
      target: server_of(args),
      op: op_of(args)
    }

    %{acc | crossings: [c | acc.crossings]}
  end

  # The first argument of a call/cast names the participant, when it is
  # written literally. `__MODULE__` has already been expanded by the
  # compiler, so a self-call resolves to a real module name here.
  defp server_of([{:atom, _, m} | _]), do: inspect(m)
  defp server_of([{:tuple, _, [{:atom, _, :via} | _]} | _]), do: ":via"
  defp server_of([{:var, _, v} | _]), do: "?#{v}"
  defp server_of([h | _]) when is_tuple(h), do: "?#{elem(h, 0)}"
  defp server_of(_), do: "?"

  defp op_of([_, op | _]), do: op_shape(op)
  defp op_of(_), do: "-"

  defp op_shape({:atom, _, a}), do: inspect(a)
  defp op_shape({:tuple, _, [{:atom, _, tag} | rest]}), do: "{#{inspect(tag)}, …#{length(rest)}}"
  defp op_shape({:var, _, v}), do: "?#{v}"
  defp op_shape(t) when is_tuple(t), do: "?#{elem(t, 0)}"
  defp op_shape(_), do: "?"
end

# ---------------------------------------------------------------------- main

root = Path.expand(Path.join(__DIR__, ".."))
ebin = Path.join(root, "ampd/_build/dev/lib/ampd/ebin")

unless File.dir?(ebin) do
  IO.puts(:stderr, "REFUSING — no compiled beams at #{ebin}. Run `mix compile` in ampd/ first.")
  System.halt(2)
end

defs = Census.load(ebin)
roots = Roots.find(defs)
res = Reach.run(defs, roots)

# Fold the crossings into one row per (function, participant, primitive), so
# a row survives a line moving. The roots that reach it are the evidence.
grouped =
  res.crossings
  |> Enum.group_by(fn c -> {c.site, c.target, c.primitive, c.op} end)
  |> Enum.map(fn {{site, target, primitive, op}, cs} ->
    %{
      "id" => "#{site} -> #{target} :: #{primitive} #{op}",
      "in" => site,
      "participant" => target,
      "primitive" => primitive,
      "op" => op,
      "kind" => cs |> hd() |> Map.get(:kind) |> to_string(),
      "lines" => cs |> Enum.map(& &1.at) |> Enum.uniq() |> Enum.sort(),
      "roots" => cs |> Enum.map(& &1.root) |> Enum.uniq() |> Enum.sort(),
      "shortest_path" => cs |> Enum.min_by(&length(&1.path)) |> Map.get(:path)
    }
  end)
  |> Enum.sort_by(& &1["id"])

opaque =
  res.opaque
  |> Enum.group_by(fn o -> {o.in, o.why, o.detail} end)
  |> Enum.map(fn {{inf, why, detail}, os} ->
    %{
      "in" => inf,
      "why" => to_string(why),
      "detail" => detail,
      "lines" => os |> Enum.map(& &1.at) |> Enum.uniq() |> Enum.sort(),
      "roots" => os |> Enum.map(& &1.root) |> Enum.uniq() |> Enum.sort()
    }
  end)
  |> Enum.sort_by(&{&1["in"], &1["why"], &1["detail"]})

by_kind = Enum.frequencies_by(grouped, & &1["kind"])

out = %{
  "generated_by" => "tools/ordered-reachability.exs",
  "beams" => Path.relative_to(ebin, root),
  "roots" => %{
    "count" => length(roots),
    "precise" => Enum.count(roots, & &1.precise),
    "imprecise" =>
      roots |> Enum.reject(& &1.precise) |> Enum.map(& &1.id) |> Enum.sort(),
    "list" =>
      roots
      |> Enum.map(fn r ->
        %{
          "id" => r.id,
          "kind" => to_string(r.kind),
          "enclosing" => r.enclosing,
          "line" => r.line,
          "precise" => r.precise
        }
      end)
      |> Enum.sort_by(& &1["id"])
  },
  "functions_reached" => MapSet.size(res.reached),
  "crossings" => grouped,
  "totals" => %{
    "crossings" => length(grouped),
    "beam" => Map.get(by_kind, "beam", 0),
    "converted" => Map.get(by_kind, "converted", 0),
    "os" => Map.get(by_kind, "os", 0),
    "opaque" => length(opaque)
  },
  "opaque" => opaque
}

json = JSON.encode!(out)
target = Path.join(root, "tools/ordered-reachability.json")
File.write!(target, json <> "\n")

IO.puts("""

  ordered reachability · derived from #{Path.relative_to(ebin, root)}

    roots            #{length(roots)}  (#{Enum.count(roots, & &1.precise)} precise, #{Enum.count(roots, &(not &1.precise))} imprecise)
    functions        #{MapSet.size(res.reached)} reachable inside the order
    crossings        #{length(grouped)}
      BEAM process   #{Map.get(by_kind, "beam", 0)}   (unconverted)
      converted      #{Map.get(by_kind, "converted", 0)}   (through Ampd.Participant)
      OS boundary    #{Map.get(by_kind, "os", 0)}   (not a participant)
    opaque           #{length(opaque)}  places the census cannot follow

  wrote tools/ordered-reachability.json
""")
