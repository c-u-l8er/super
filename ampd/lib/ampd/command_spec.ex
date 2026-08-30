defmodule Ampd.CommandSpec do
  @moduledoc """
  `command-spec@1` — **what may be said**, declared once.

  `Ampd.Control` implements what a command *means*. This module declares
  what a command *is*: which channel may send it, what fields it carries,
  what each field's type and size are, and which are required. One object,
  and everything downstream is derived from it — the wire vocabulary, the
  argument validation, the channel eligibility check in `Ampd.Control`, and
  the documentation table below.

  ## Why this is not `Ampd.Control`'s function heads

  Until now the protocol *was* the Elixir dispatch clauses: `Ampd.Wire`
  built its vocabulary from `Ampd.Control`'s command lists, and argument
  validity meant "some `dispatch/3` clause matched". That works exactly as
  long as both ends of the protocol are this BEAM.

  The moment bytes cross a socket there is a protocol, and a protocol
  derived from function heads has no version, no field names, no way to
  add an optional field, and no way for a Rust client to know what to send
  without reading Elixir. It also cannot express a limit: a function head
  says `is_binary(reason)`, never `reason ≤ 4 KB`.

  ## Named fields, not positions

  Wire commands carry named arguments:

      %{"schema" => "command@1", "command" => "approve_effect",
        "args" => %{"request_id" => "er_0041", "approval_id" => "ap_0092"}}

  not `["er_0041", "ap_0092"]`. Positions are fine *inside* the BEAM,
  where `Ampd.Control.command/3` still takes a list — `bind/2` is what
  turns names into that list, in the order declared here. But on a
  long-lived wire, positions cannot be extended: adding `deadline` or
  `trace_parent` to a command later means either appending and hoping
  every client counts the same, or a new command word. Names cost one map
  and remove the whole problem.

  A second consequence, which matters more than the evolution story:
  because `bind/2` fills every declared field, it always produces exactly
  the declared arity. The "well-typed but no clause" case that
  `Ampd.Wire` has to `rescue` — `preflight` with one argument — cannot be
  constructed through this path at all.

  ## The channel is part of the schema

  `channel:` is declared per command, and `Ampd.Control` derives its
  `@agent`/`@human` partition from here rather than keeping its own lists.
  Those were two hand-maintained sources for one fact; a command added to
  `Ampd.Control` and forgotten in `Ampd.Wire`'s vocabulary was unreachable,
  and the reverse was worse.

  ## Sizes

  Per-field limits, because "the argument is under 64 KB" was never the
  invariant anyone wanted:

      capability    128 B      resource      512 B
      reason          4 KB     request        64 KB
      note            4 KB     scope           4 KB

  The aggregate limit is `Ampd.Frame`'s business — a field limit cannot
  bound a command with eight fields, and neither can bound the bytes a
  socket has already read.
  """

  @schema "command-spec@1"
  @version 1

  def schema, do: @schema
  def version, do: @version

  # Sizes are named rather than inline so the table below reads as a
  # contract instead of arithmetic.
  @cap_bytes 128
  @resource_bytes 512
  @reason_bytes 4 * 1024
  @request_bytes 64 * 1024
  @scope_bytes 4 * 1024
  @max_expected_ids 512

  # A worktree leaf name. 64 B rather than 512 because it becomes one path
  # segment, and the limit that matters is the one the filesystem has —
  # `Ampd.Worktree.legal_name?/1` narrows it much further, to a character
  # class. This bound exists so an oversized name is refused by the
  # protocol before any module has to reason about it.
  @name_bytes 64

  # ---------------------------------------------------------------------
  # The registry. `fields` is an ordered list: the order *is* the internal
  # positional calling convention `Ampd.Control.command/3` receives.
  # ---------------------------------------------------------------------
  @commands %{
    # ------------------------------------------------------------ agent
    "agent_projection" => %{cmd: :agent_projection, channel: :agent, kind: :read, retry: :safe, fields: []},
    "preflight" => %{
      cmd: :preflight,
      channel: :agent,
      kind: :read,
      retry: :once,
      fields: [
        %{name: "capability", type: {:string, @cap_bytes}, required: true},
        %{name: "resource", type: {:string, @resource_bytes}, required: true},
        %{name: "request", type: {:map, @request_bytes}, required: false, default: nil}
      ]
    },
    "request_effect" => %{
      cmd: :request_effect,
      channel: :agent,
      kind: :mutation,
      fields: [
        %{name: "capability", type: {:string, @cap_bytes}, required: true},
        %{name: "resource", type: {:string, @resource_bytes}, required: true},
        %{name: "request", type: {:map, @request_bytes}, required: false, default: nil}
      ]
    },
    "request_grant" => %{
      cmd: :request_grant,
      channel: :agent,
      kind: :mutation,
      fields: [
        %{name: "capability", type: {:string, @cap_bytes}, required: true},
        %{name: "resource", type: {:string, @resource_bytes}, required: true},
        # `options` defaults to an empty map, never nil: `Ampd.Control`
        # indexes it, and `nil["duration"]` raises where `%{}["duration"]`
        # is the absent value the caller meant.
        %{name: "options", type: {:map, @reason_bytes}, required: false, default: %{}}
      ]
    },

    # ---------------------------------------------------------- human
    "operator_projection" => %{cmd: :operator_projection, channel: :human_control, kind: :read, retry: :safe, fields: []},
    "recovery_status" => %{cmd: :recovery_status, channel: :human_control, kind: :read, retry: :safe, fields: []},
    "approve_effect" => %{
      cmd: :approve_effect,
      channel: :human_control,
      kind: :mutation,
      fields: [
        %{name: "request_id", type: {:id, "er_"}, required: true},
        %{name: "approval_id", type: {:id, "ap_"}, required: true}
      ]
    },
    "deny_effect" => %{
      cmd: :deny_effect,
      channel: :human_control,
      kind: :mutation,
      fields: [
        %{name: "approval_id", type: {:id, "ap_"}, required: true},
        %{name: "note", type: {:string, @reason_bytes}, required: false, default: nil}
      ]
    },
    "revoke_grant" => %{
      cmd: :revoke_grant,
      channel: :human_control,
      kind: :mutation,
      fields: [%{name: "grant_id", type: {:id, "gr_"}, required: true}]
    },

    # `expected_ids` is **required**. A bulk revocation with no confirmed
    # set is the operation this command exists to make impossible to say
    # by accident — see `Ampd.GrantRegistry.revoke_matching/2`.
    "revoke_capability_domain" => %{
      cmd: :revoke_capability_domain,
      channel: :human_control,
      kind: :mutation,
      fields: [
        %{name: "scope", type: {:map, @scope_bytes}, required: true},
        %{name: "expected_ids", type: {:ids, "gr_", @max_expected_ids}, required: true}
      ]
    },
    "approve_grant_request" => %{
      cmd: :approve_grant_request,
      channel: :human_control,
      kind: :mutation,
      fields: [
        %{name: "request_id", type: {:id, "gq_"}, required: true},
        # nil means "as requested"; the enum is closed either way.
        %{name: "duration", type: {:enum, ~w(once run agent workspace)}, required: false, default: nil}
      ]
    },
    "deny_grant_request" => %{
      cmd: :deny_grant_request,
      channel: :human_control,
      kind: :mutation,
      fields: [
        %{name: "request_id", type: {:id, "gq_"}, required: true},
        %{name: "note", type: {:string, @reason_bytes}, required: false, default: nil}
      ]
    },

    # ------------------------------------------------------- both / open
    "inspect_refusal" => %{
      cmd: :inspect_refusal,
      channel: :both,
      kind: :read,
      retry: :once,
      fields: [%{name: "correlation_id", type: {:string, 128}, required: true}]
    },
    "runtime_status" => %{cmd: :runtime_status, channel: :open, kind: :read, retry: :safe, fields: []},

    # A subscription is a wire concern, not an authority one: it asks the
    # runtime to push this channel's own projection when it changes. What
    # arrives is whatever `Ampd.Projection` would already answer on this
    # channel, so it grants no read the channel did not already have.
    "subscribe" => %{cmd: :subscribe, channel: :both, kind: :mutation, fields: []},
    "unsubscribe" => %{cmd: :unsubscribe, channel: :both, kind: :mutation, fields: []},

    # History is paged rather than pushed. Both channels may ask; each gets
    # its own — an operator sees the world's, an agent sees only its own,
    # which is the same filter the projections already apply.
    "list_receipts" => %{
      cmd: :list_receipts,
      channel: :both,
      kind: :read,
      retry: :safe,
      fields: [
        %{name: "cursor", type: {:id, "rcpt-"}, required: false, default: nil},
        %{name: "limit", type: {:count, 200}, required: false, default: 50}
      ]
    },
    "list_effect_history" => %{
      cmd: :list_effect_history,
      channel: :both,
      kind: :read,
      retry: :safe,
      fields: [
        %{name: "cursor", type: {:id, "ef_"}, required: false, default: nil},
        %{name: "limit", type: {:count, 200}, required: false, default: 50}
      ]
    },
    "list_grant_requests" => %{
      cmd: :list_grant_requests,
      channel: :both,
      kind: :read,
      retry: :safe,
      fields: [
        %{name: "cursor", type: {:id, "gq_"}, required: false, default: nil},
        %{name: "limit", type: {:count, 200}, required: false, default: 50}
      ]
    },

    # ------------------------------------------------- loci · D.1.1
    #
    # **Not one of these declares a path-typed field, and that is the
    # point of the slice.** Every reference below is an opaque id minted
    # by the runtime. A Lane that somehow learned a host path has no
    # command to say it in, so the confinement argument in
    # `Ampd.Worktree` is not the only thing standing between a Lane and
    # the filesystem — the grammar is.
    #
    # `open_lane` takes a `repository_ref`, never a repository path.
    # Registering a repository is a host-level trust decision made
    # through `Ampd.Worktree.register_repository!/1`, and it is recorded
    # in the D.1.1 ambient-authority census as exactly that rather than
    # dressed up as a typed command.
    "open_workspace" => %{
      cmd: :open_workspace,
      channel: :human_control,
      kind: :mutation,
      fields: [%{name: "name", type: {:string, @name_bytes}, required: true}]
    },
    "open_goal" => %{
      cmd: :open_goal,
      channel: :human_control,
      kind: :mutation,
      fields: [
        %{name: "workspace_ref", type: {:id, "ws_"}, required: true},
        %{name: "title", type: {:string, @reason_bytes}, required: true}
      ]
    },
    "open_lane" => %{
      cmd: :open_lane,
      channel: :human_control,
      kind: :mutation,
      fields: [
        %{name: "goal_ref", type: {:id, "gl_"}, required: true},
        %{name: "actor", type: {:string, @cap_bytes}, required: true},
        %{name: "repository_ref", type: {:id, "rp_"}, required: true},
        %{name: "base_revision", type: {:string, @cap_bytes}, required: false, default: nil}
      ]
    },
    "establish_worktree" => %{
      cmd: :establish_worktree,
      channel: :agent,
      kind: :mutation,
      fields: [
        %{name: "locus_ref", type: {:id, "ln_"}, required: true},
        %{name: "name", type: {:string, @name_bytes}, required: true}
      ]
    },

    # `retry: :once`, not `:safe`. Both of these refuse — that is most of
    # what they do — and `Ampd.Refusal.new/2` records into the refusal
    # ring as it constructs. A read that writes as it decides must not be
    # speculated on under the seqlock; declaring these `:safe` would have
    # one client command deposit four refusals and show the client one,
    # which is the defect the `retry:` field was added to prevent.
    "observe_worktree" => %{
      cmd: :observe_worktree,
      channel: :agent,
      kind: :read,
      retry: :once,
      fields: [%{name: "capability_ref", type: {:id, "wc_"}, required: true}]
    },
    "attach_locus" => %{
      cmd: :attach_locus,
      channel: :agent,
      kind: :read,
      retry: :once,
      fields: [%{name: "locus_ref", type: {:id, "ln_"}, required: true}]
    },
    "list_loci" => %{cmd: :list_loci, channel: :both, kind: :read, retry: :safe, fields: []},

    # ----------------------------------------------- workers · D.1.2
    #
    # **Six words, and not one of them can name a process.** There is no
    # `pid` field, no `command`, no `executable`, no `pty`, no `argv`. A
    # Worker is an assignment; the grammar is what makes "assignment" a
    # thing that cannot quietly become "process", because a field that
    # does not exist cannot be filled in later by accident.
    #
    # The channel split is the load-bearing part. **Creating, closing and
    # re-opening an assignment are `:human_control`** — a person decides
    # who is assigned where, exactly as `open_lane` decides who a Lane is
    # held by, and an agent can no more assign itself to a position than
    # it can open the Lane under it. **Attaching is `:agent`**, because
    # taking up an assignment is something only the Carrier that will
    # fulfil it can do; the human control channel holds no actor and
    # `Ampd.Worker.occupancy/2` refuses it by name.
    "open_worker" => %{
      cmd: :open_worker,
      channel: :human_control,
      kind: :mutation,
      fields: [
        %{name: "locus_ref", type: {:id, "ln_"}, required: true},
        # No `actor` field. The actor is copied from the Lane, so there is
        # no argument in which a person could assign a Worker to someone
        # the Lane is not held by — referential closure by construction
        # rather than by a check that could be forgotten.
        %{name: "purpose", type: {:string, @reason_bytes}, required: true}
      ]
    },
    "close_worker" => %{
      cmd: :close_worker,
      channel: :human_control,
      kind: :mutation,
      fields: [%{name: "worker_ref", type: {:id, "wk_"}, required: true}]
    },
    "reopen_worker" => %{
      cmd: :reopen_worker,
      channel: :human_control,
      kind: :mutation,
      fields: [%{name: "worker_ref", type: {:id, "wk_"}, required: true}]
    },

    # `retry: :once` for the same reason `attach_locus` is: it refuses far
    # more often than it succeeds, and `Ampd.Refusal.new/2` writes to the
    # refusal ring as it constructs. A `:safe` read that refuses deposits
    # one refusal per speculative attempt and shows the client one.
    # **The Carrier is started by the agent that occupies the position.**
    #
    # Not by a person, and not by the host. Occupancy *is* the launch
    # authority — there is deliberately no separate "may start a Carrier"
    # capability, because inventing a grant before anything needs one is the
    # objection three prior slices raised against a new store, applied to the
    # grammar instead. `Ampd.Carrier.admit_start/2` re-derives occupancy and
    # refuses without it, so the channel restriction here is a courtesy and
    # the check is elsewhere.
    #
    # `kind: :mutation`, because it starts an OS process. `retry` is therefore
    # absent by the rule the compile-time guard enforces: a read must declare
    # retry and a mutation must not, since a resubmitted start is how you get
    # two processes for one intent.
    #
    # **No field names a process, a path, an executable or a pty.** The
    # six-word constraint D.1.2 recorded still holds: the Carrier payload is
    # chosen by the host from what it has installed, and a grammar in which a
    # caller could name one would be a grammar where naming something runs it.
    "start_carrier" => %{
      cmd: :start_carrier,
      channel: :agent,
      kind: :mutation,
      fields: [%{name: "locus_ref", type: {:id, "ln_"}, required: true}]
    },
    "stop_carrier" => %{
      cmd: :stop_carrier,
      channel: :agent,
      kind: :mutation,
      fields: []
    },
    "attach_worker" => %{
      cmd: :attach_worker,
      channel: :agent,
      kind: :read,
      retry: :once,
      fields: [%{name: "worker_ref", type: {:id, "wk_"}, required: true}]
    },
    "detach_worker" => %{
      cmd: :detach_worker,
      channel: :agent,
      kind: :read,
      retry: :once,
      fields: []
    },
    "list_workers" => %{cmd: :list_workers, channel: :both, kind: :read, retry: :safe, fields: []}
  }

  # **Every command declares whether it reads or mutates, and the build
  # fails if one does not.**
  #
  # W.1 needs the distinction in two places: a read is safe to assemble
  # under the continuity seqlock in `Ampd.Projection.framed/2` — build it
  # again if the world moved underneath — while a mutation is not, because
  # a mutation *is* the thing that moves the world and retrying it would
  # perform it twice.
  #
  # It is declared here rather than as a list in `Ampd.Control` for the
  # reason the channel classes are: two maintained sources for one fact
  # means a command added to one and forgotten in the other is either
  # unreachable or unchecked, and this one would be unchecked in the
  # direction of serving a projection from the wrong incarnation.
  #
  # `subscribe` is a mutation despite returning a snapshot. It registers a
  # monitor, so retrying it under the seqlock would register twice; its
  # snapshot is made coherent inside `Ampd.Subscriptions.build/1` instead.
  @missing_kind @commands |> Enum.reject(fn {_w, s} -> Map.has_key?(s, :kind) end) |> Enum.map(&elem(&1, 0))
  if @missing_kind != [] do
    raise "command-spec@1: no `kind:` declared for #{inspect(@missing_kind)} — " <>
            "every command must say whether it reads or mutates"
  end

  @doc "Every declared command word."
  def commands, do: Map.keys(@commands)

  # **`kind: :read` does not mean "safe to retry", and assuming it did was
  # a defect.** `Ampd.Refusal.new/2` records into `Ampd.RefusalLog` as it
  # constructs, so a read that can refuse writes as it decides. Under the
  # optimistic seqlock one client command recorded **four** refusals —
  # measured on `preflight` and on `inspect_refusal` — and the client saw
  # one. The ring is bounded, so what it destroys is the meaning of the
  # ring rather than any memory.
  #
  # So the two facts are declared separately, because they are two facts:
  #
  #     kind:  :read | :mutation      may this be assembled under a cursor?
  #     retry: :safe | :once          may it be executed more than once?
  #
  # A mutation has no `retry:` — it is never speculated on. Every read must
  # declare one, and the build fails if it does not.
  @missing_retry @commands
                 |> Enum.filter(fn {_w, s} -> s[:kind] == :read and not Map.has_key?(s, :retry) end)
                 |> Enum.map(&elem(&1, 0))
  if @missing_retry != [] do
    raise "command-spec@1: no `retry:` declared for the read(s) #{inspect(@missing_retry)} — " <>
            "a read that constructs a refusal writes as it decides and must not be speculated on"
  end

  @doc """
  Command atoms that only read. Safe to assemble under a continuity cursor;
  everything else moves the world.
  """
  def reads,
    do: @commands |> Enum.filter(fn {_, s} -> s.kind == :read end) |> Enum.map(fn {_, s} -> s.cmd end) |> Enum.sort()

  @doc """
  Reads that must be executed **exactly once**, on the ordered path, because
  executing them is not free — see `Ampd.Projection.framed_once/2`.
  """
  def retry_once,
    do:
      @commands
      |> Enum.filter(fn {_, s} -> s[:kind] == :read and s[:retry] == :once end)
      |> Enum.map(fn {_, s} -> s.cmd end)
      |> Enum.sort()

  @doc "The spec for one command word, or `nil`."
  def get(word) when is_binary(word), do: Map.get(@commands, word)
  def get(_), do: nil

  @doc """
  The fixed `string → atom` vocabulary.

  Built from literal atoms in the table above, so **`String.to_atom/1` is
  never reachable from a wire word.** The atom table has a hard ceiling and
  is never collected; an interning decoder hands any peer a denial of
  service that outlives the connection.
  """
  def vocabulary, do: Map.new(@commands, fn {w, s} -> {w, s.cmd} end)

  @doc "Command atoms a given channel may send, including `:both` and `:open`."
  def commands_for(:agent), do: atoms_where(&(&1 in [:agent, :both, :open]))
  def commands_for(:human_control), do: atoms_where(&(&1 in [:human_control, :both, :open]))
  def commands_for(:open), do: atoms_where(&(&1 == :open))

  @doc "Command atoms declared for exactly `channel` (no `:both`, no `:open`)."
  def exclusive_to(channel), do: atoms_where(&(&1 == channel))

  defp atoms_where(pred) do
    @commands |> Enum.filter(fn {_, s} -> pred.(s.channel) end) |> Enum.map(fn {_, s} -> s.cmd end) |> Enum.sort()
  end

  @doc """
  Validate `args` against the spec and produce the positional list
  `Ampd.Control.command/3` takes.

  `args` may be a **map** of named fields — the wire form — or a **list**
  of positional values, which is what in-BEAM callers and the conformance
  fixtures use. Both are checked against the same declared types, so the
  positional path is not a way around a limit.

  Returns `{:ok, cmd_atom, [values]}` or `{:error, code, detail}`.
  """
  def bind(word, args) when is_binary(word) do
    case get(word) do
      nil -> {:error, "unknown-command", %{"command" => word}}
      spec -> bind_spec(spec, args)
    end
  end

  def bind(word, _args), do: {:error, "unknown-command", %{"got" => tag(word)}}

  defp bind_spec(spec, args) when is_map(args) and not is_struct(args) do
    unknown = Map.keys(args) -- Enum.map(spec.fields, & &1.name)

    if unknown != [] do
      # An unknown field is refused rather than dropped. Silently ignoring
      # one means a client that misspells `expected_ids` gets a bulk
      # revocation it did not confirm.
      {:error, "invalid-command-arguments",
       %{"reason" => "unknown field", "fields" => Enum.sort(unknown),
         "declared" => Enum.map(spec.fields, & &1.name)}}
    else
      collect(spec, fn f -> {Map.has_key?(args, f.name), Map.get(args, f.name)} end)
    end
  end

  defp bind_spec(spec, args) when is_list(args) do
    if length(args) > length(spec.fields) do
      {:error, "invalid-command-arguments",
       %{"reason" => "too many arguments", "count" => length(args),
         "declared" => length(spec.fields), "fields" => Enum.map(spec.fields, & &1.name)}}
    else
      indexed = Enum.with_index(args) |> Map.new(fn {v, i} -> {i, v} end)

      spec.fields
      |> Enum.with_index()
      |> then(fn _ ->
        collect(spec, fn f ->
          i = Enum.find_index(spec.fields, &(&1.name == f.name))
          {Map.has_key?(indexed, i), Map.get(indexed, i)}
        end)
      end)
    end
  end

  defp bind_spec(_spec, args),
    do: {:error, "invalid-command-arguments", %{"reason" => "arguments must be a map or a list", "got" => tag(args)}}

  # Walks the declared fields in order, so the result is always exactly the
  # declared arity — an absent optional becomes its default, not a shorter
  # list.
  defp collect(spec, fetch) do
    Enum.reduce_while(spec.fields, {:ok, []}, fn f, {:ok, acc} ->
      {present?, value} = fetch.(f)

      cond do
        not present? or value == nil ->
          if Map.get(f, :required, false) do
            {:halt, {:error, "invalid-command-arguments",
                     %{"reason" => "missing required field", "field" => f.name}}}
          else
            {:cont, {:ok, acc ++ [Map.get(f, :default)]}}
          end

        true ->
          case check(f.type, value) do
            :ok -> {:cont, {:ok, acc ++ [value]}}
            {:error, why} -> {:halt, {:error, "invalid-command-arguments", Map.put(why, "field", f.name)}}
          end
      end
    end)
    |> case do
      {:ok, values} -> {:ok, spec.cmd, values}
      {:error, code, detail} -> {:error, code, detail}
    end
  end

  # ------------------------------------------------------------ types
  defp check({:string, max}, v) when is_binary(v) do
    if byte_size(v) > max,
      do: {:error, %{"reason" => "field too large", "bytes" => byte_size(v), "max" => max}},
      else: :ok
  end

  defp check({:string, _}, v), do: {:error, %{"reason" => "expected a string", "got" => tag(v)}}

  defp check({:id, prefix}, v) when is_binary(v) do
    cond do
      byte_size(v) > 128 -> {:error, %{"reason" => "field too large", "bytes" => byte_size(v), "max" => 128}}
      not String.starts_with?(v, prefix) -> {:error, %{"reason" => "identifier has the wrong prefix", "expected_prefix" => prefix}}
      true -> :ok
    end
  end

  defp check({:id, _}, v), do: {:error, %{"reason" => "expected an identifier", "got" => tag(v)}}

  defp check({:map, max}, v) when is_map(v) and not is_struct(v) do
    # Recursive, because the whole point is that a 5 MB string one level
    # down is still 5 MB. `Ampd.Frame.logical_size/1` is the shared walk.
    case Ampd.Frame.logical_size(v, max) do
      {:ok, _} -> :ok
      {:over, n} -> {:error, %{"reason" => "field too large", "bytes_at_least" => n, "max" => max}}
    end
  end

  defp check({:map, _}, v), do: {:error, %{"reason" => "expected a map", "got" => tag(v)}}

  defp check({:count, max}, v) when is_integer(v) do
    if v >= 1 and v <= max,
      do: :ok,
      else: {:error, %{"reason" => "out of range", "given" => v, "min" => 1, "max" => max}}
  end

  defp check({:count, _}, v), do: {:error, %{"reason" => "expected a whole number", "got" => tag(v)}}

  defp check({:enum, allowed}, v) do
    if v in allowed,
      do: :ok,
      else: {:error, %{"reason" => "not an allowed value", "given" => tag_value(v), "allowed" => allowed}}
  end

  defp check({:ids, prefix, max_len}, v) when is_list(v) do
    cond do
      length(v) > max_len ->
        {:error, %{"reason" => "too many identifiers", "count" => length(v), "max" => max_len}}

      not Enum.all?(v, &is_binary/1) ->
        {:error, %{"reason" => "identifiers must be strings"}}

      not Enum.all?(v, &String.starts_with?(&1, prefix)) ->
        {:error, %{"reason" => "identifier has the wrong prefix", "expected_prefix" => prefix}}

      not Enum.all?(v, &(byte_size(&1) <= 128)) ->
        {:error, %{"reason" => "identifier too long", "max" => 128}}

      true ->
        :ok
    end
  end

  defp check({:ids, _, _}, v), do: {:error, %{"reason" => "expected a list of identifiers", "got" => tag(v)}}

  defp tag_value(v) when is_binary(v), do: String.slice(v, 0, 64)
  defp tag_value(v), do: tag(v)

  defp tag(v) when is_binary(v), do: "binary"
  defp tag(v) when is_list(v), do: "list"
  defp tag(v) when is_map(v), do: "map"
  defp tag(v) when is_integer(v), do: "integer"
  defp tag(v) when is_atom(v), do: "atom"
  defp tag(_), do: "term"
end
