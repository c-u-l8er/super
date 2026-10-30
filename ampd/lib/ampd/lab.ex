defmodule Ampd.Lab do
  @moduledoc """
  The lab's record, read and shown, never acted on (UI Part 9, task 9.2).

  The lab's daily check leaves one fixed record, `lab-status/1`, at a path
  this instance's device settings name. This process reads it and publishes
  `lab-view@1` at `"lab"` in the operator projection, in `Ampd.Fleet`'s
  pattern: a supervised reader, an ordered-boundary participant with no
  mutations, one read.

    * **Where.** `SUPER_LAB_STATUS` wins when set, and an empty value turns
      the reader off. Otherwise `super/lab.json` in this instance's STATE
      folder (`$XDG_STATE_HOME`, else `$HOME/.local/state`): a regular file,
      schema `super-device-lab@1`, an absolute `recordPath`. Never
      `~/.config/super/`: every unit on a machine reads that folder, and a
      state folder belongs to one instance, so only the instance whose
      settings name a record shows one.
    * **Whole or nothing.** Every declared field is checked, and one bad value
      anywhere makes the view `"unavailable"` with one fixed word, `why`, and
      no reading. Undeclared fields are dropped at every level, a collection
      the lab could not read included.
    * **Text stays data.** Strings pass through unchanged, bounded in bytes and
      free of control characters. Nothing here parses, rephrases, joins or
      links a text field, and no field of the view is derived from the words
      in one. The only words the runtime adds are `schema`, `status`, `why`,
      `confirmation` and the four keys inside it.
    * **Read only.** It opens two files, the settings and the record, for
      reading, and nothing else, and opens neither unless it is a regular
      file. It never runs the check and never reaches a machine, a container
      or a drive.

  The view; for `why`, the first that applies wins:

      unconfigured   no path
      unavailable    missing | unreadable | too-large (the file over 32,768 B)
                     | malformed (not a JSON object) | unknown-schema
                     | malformed (any other rule) | out-of-range
                     (valid_for_hours over 8,760) | future (a time more than
                     5 s ahead, to the microsecond) | too-large (the view
                     over 33,792 B encoded)
      configured     record (declared fields only) and confirmation

  `read/2` owns the file's rules (the first three); `decode/2` owns the rest,
  so a caller holding bytes gets exactly what the reader would show for them.

  **Reading.** Each tick the record is read again when its type, size,
  modification time, change time, inode or device changed since the last
  reading; on every tick while the view is `future` (only the clock cures
  that); and on every tick while the last reading's stamp is racy, that is,
  while its modification or change time was not at least 2 s older than that
  reading. A stamp holds whole seconds, so a same-size rewrite within the
  second of a reading changes none of its fields; a racy stamp is therefore
  not trusted until a reading finds both times settled. Otherwise the view is
  only re-aged, so `expired` flips with no file change. The first reading is
  taken at start and announced once.
  """
  use GenServer

  @settings_limit 65_536
  @record_limit 32_768
  @view_limit 33_792
  @ahead_ms 5_000
  @tick_ms 1_000
  @settle_s 2
  @max_valid_hours 8_760
  @id_max 120
  @text_max 500
  @view_schema "lab-view@1"
  @count_keys ~w(ok failed skipped running unavailable)

  # The supervised reader takes no options. The suite may pass `name:` (nil
  # starts an unnamed reader), `path:` (instead of the settings), `notify:` (a
  # pid told `{Ampd.Lab, :touched}` instead of the coordinator) and `tick_ms:`.
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  # **Converted, as `Ampd.Fleet` is.** This process owns no world state: its
  # view is a bounded, ephemeral read of the lab's record. But
  # `Ampd.Projection` reads it at `"lab"` while building the operator
  # projection, which runs inside an ordered observation, so the client call
  # crosses the total order's process boundary like any participant's and goes
  # through `Ampd.Participant.call`. A bare call's exit here would pass the
  # coordinator's narrow `rescue ... in Ampd.Participant.Failure` untouched and
  # take the whole observation down as an exit rather than a classified
  # refusal.
  #
  # Nothing a client sends mutates anything, so the list is empty. It stays
  # declared so the module reads as a participant to every census; and the
  # membership test is `Enum.member?/2` rather than `in`, because `tag in []`
  # folds to a constant `false` that `--warnings-as-errors` turns into a build
  # failure (see `Ampd.Fleet`).
  @participant_mutations ~w()a

  defp ask(msg, timeout \\ 5_000) do
    tag = if is_tuple(msg), do: elem(msg, 0), else: msg
    Ampd.Participant.call(__MODULE__, msg, class(tag), timeout: timeout)
  end

  @doc false
  # Public so the closure gate and the falsifiers read the classification
  # rather than infer it.
  def class(tag), do: if(Enum.member?(@participant_mutations, tag), do: :mutate, else: :read)

  @doc "This instance's view of the lab's record, `lab-view@1`."
  def projection, do: ask(:projection)

  # The path is found once, as the fleet finds its own. The first reading is
  # taken here, so the projection never carries a placeholder `why`, and it is
  # announced once by the `:announce` message, so a restart's new view reaches
  # every subscriber.
  def init(opts) do
    path =
      case Keyword.fetch(opts, :path) do
        {:ok, path} -> path
        :error -> record_path()
      end

    state = %{
      path: path,
      stamp: :none,
      view: nil,
      racy: false,
      notify: Keyword.get(opts, :notify),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)
    }

    {_action, state} = tick(state, now(), wall())
    send(self(), :announce)
    Process.send_after(self(), :refresh, state.tick_ms)
    {:ok, state}
  end

  def handle_call(:projection, _, state), do: {:reply, state.view, state}

  def handle_info(:announce, state) do
    announce(state.notify)
    {:noreply, state}
  end

  # `touched()` only when the view moved, so `expired` flipping fires it once
  # and a re-read that finds the same view fires nothing.
  def handle_info(:refresh, state) do
    {_action, next} = tick(state, now(), wall())
    if next.view != state.view, do: announce(state.notify)
    Process.send_after(self(), :refresh, state.tick_ms)
    {:noreply, next}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp announce(nil), do: Ampd.AuthorityCoordinator.touched()
  defp announce(pid) when is_pid(pid), do: send(pid, {__MODULE__, :touched})

  @doc false
  # One tick over explicit clocks: `{:read | :reage | :none, state}`. `now_ms`
  # judges the record's own times; `wall_ms` is the OS clock a file's times are
  # kept in, and judges whether this reading's stamp may be trusted. Public so
  # the suite drives both clocks and sees which the tick did.
  def tick(%{path: nil} = state, _now_ms, _wall_ms),
    do: {:none, Map.merge(state, %{stamp: nil, view: unconfigured(), racy: false})}

  def tick(%{path: path} = state, now_ms, wall_ms) do
    current = stamp(path)

    if reread?(state.stamp, current, state.view, Map.get(state, :racy, false)) do
      next = %{stamp: current, view: read(path, now_ms), racy: racy?(current, wall_ms)}
      {:read, Map.merge(state, next)}
    else
      {:reage, %{state | view: reage(state.view, now_ms)}}
    end
  end

  @doc false
  # Read again while the last stamp is racy, when anything the stamp holds
  # changed, or while the reading is refused as `future`.
  def reread?(last, current, view, racy), do: racy or last != current or retry?(view)

  @doc false
  # A stamp is racy when its modification or change time is not at least 2 s
  # older than the reading it was taken for. One line, so a plant can name it.
  def racy?(%{mtime: m, ctime: c}, wall_ms), do: wall_ms < (max(m, c) + @settle_s) * 1_000
  def racy?(_stamp, _wall_ms), do: false

  defp retry?(%{"status" => "unavailable", "why" => "future"}), do: true
  defp retry?(_), do: false

  @doc false
  # What a change of the record is judged by: type, size, both times, inode
  # and device.
  def stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, s} ->
        %{
          type: s.type,
          size: s.size,
          mtime: s.mtime,
          ctime: s.ctime,
          inode: s.inode,
          device: s.major_device
        }

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> :error
  end

  defp now, do: System.system_time(:millisecond)
  defp wall, do: System.os_time(:millisecond)

  # ------------------------------------------------------------ where

  @doc """
  The record's path, or `nil`. `SUPER_LAB_STATUS` wins when set, and `""`
  gives `nil`. Otherwise the settings file `super/lab.json` under
  `$XDG_STATE_HOME`, or under `$HOME/.local/state` when that is unset, empty
  or relative: a regular file (anything else is never opened, so a FIFO
  cannot block the start), at most 65,536 bytes, schema `super-device-lab@1`,
  an absolute `recordPath`. Anything else gives `nil`.
  """
  def record_path(env \\ System.get_env()) do
    case Map.fetch(env, "SUPER_LAB_STATUS") do
      {:ok, ""} -> nil
      {:ok, path} -> path
      :error -> saved_record_path(env)
    end
  end

  defp saved_record_path(env) do
    base =
      absolute(env["XDG_STATE_HOME"]) ||
        case absolute(env["HOME"]) do
          nil -> nil
          home -> Path.join(home, ".local/state")
        end

    with base when is_binary(base) <- base,
         settings = Path.join(base, "super/lab.json"),
         {:ok, %File.Stat{type: :regular}} <- File.stat(settings),
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @settings_limit <-
           File.open(settings, [:read, :binary], &IO.binread(&1, @settings_limit + 1)),
         {:ok, %{"schema" => "super-device-lab@1", "recordPath" => path}} <-
           JSON.decode(bytes) do
      absolute(path)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp absolute(path) when is_binary(path), do: if(Path.type(path) == :absolute, do: path)
  defp absolute(_), do: nil

  # ------------------------------------------------------------ the view

  defp unconfigured, do: %{"schema" => @view_schema, "status" => "unconfigured"}

  defp unavailable(why), do: %{"schema" => @view_schema, "status" => "unavailable", "why" => why}

  @doc "The view of the file at `path` at the clock `now_ms`. Never raises."
  def read(path, now_ms) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> read_regular(path, now_ms)
      {:ok, _} -> unavailable("unreadable")
      {:error, reason} when reason in [:enoent, :enotdir] -> unavailable("missing")
      {:error, _} -> unavailable("unreadable")
    end
  rescue
    _ -> unavailable("unreadable")
  end

  defp read_regular(path, now_ms) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @record_limit + 1)) do
      {:ok, :eof} ->
        decode("", now_ms)

      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > @record_limit ->
        unavailable("too-large")

      {:ok, bytes} when is_binary(bytes) ->
        decode(bytes, now_ms)

      _ ->
        unavailable("unreadable")
    end
  end

  @doc "The view of these bytes at the clock `now_ms` (what `read/2` uses). Never raises."
  def decode(bytes, now_ms) do
    case JSON.decode(bytes) do
      {:ok, %{"schema" => "lab-status/1"} = doc} -> document(doc, now_ms)
      {:ok, %{}} -> unavailable("unknown-schema")
      _ -> unavailable("malformed")
    end
  rescue
    _ -> unavailable("malformed")
  end

  # Over the same rules twice: first with no limit on time, so a broken rule
  # is `malformed`; then the bound on `valid_for_hours`, `out-of-range`; then
  # the five-second limit, `future`.
  defp document(doc, now_ms) do
    case record(doc, nil) do
      {:ok, rec} -> bounded(doc, rec, now_ms)
      :error -> unavailable("malformed")
    end
  end

  defp bounded(doc, rec, now_ms) do
    if in_range?(rec), do: timely(doc, now_ms), else: unavailable("out-of-range")
  end

  # One line, so a plant can name it.
  defp in_range?(rec), do: Map.get(rec, "valid_for_hours", 0) <= @max_valid_hours

  # The latest a `time` may be, in microseconds.
  defp timely(doc, now_ms) do
    case record(doc, (now_ms + @ahead_ms) * 1_000) do
      {:ok, rec} -> configured(rec, now_ms)
      :error -> unavailable("future")
    end
  end

  defp configured(rec, now_ms) do
    view =
      reage(
        %{
          "schema" => @view_schema,
          "status" => "configured",
          "record" => rec,
          "confirmation" => confirmation(rec)
        },
        now_ms
      )

    if byte_size(JSON.encode!(view)) > @view_limit, do: unavailable("too-large"), else: view
  end

  defp confirmation(%{"finished_at" => finished} = rec) do
    hours = Map.get(rec, "valid_for_hours")

    %{
      "finished_at" => finished,
      "valid_for_hours" => hours,
      "expires_at" => expires_at(finished, hours),
      "expired" => false
    }
  end

  defp expires_at(_finished, nil), do: nil

  defp expires_at(finished, hours) do
    {:ok, at, _} = DateTime.from_iso8601(finished)

    at
    |> DateTime.add(round(hours * 3600), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc """
  The same view with `confirmation.expired` recomputed for `now_ms`: true once
  `now_ms` is after `expires_at`. Any other view is returned unchanged.
  """
  def reage(
        %{"status" => "configured", "confirmation" => %{"expires_at" => at} = c} = view,
        now_ms
      )
      when is_binary(at) and is_integer(now_ms) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} ->
        %{view | "confirmation" => %{c | "expired" => now_ms > DateTime.to_unix(dt, :millisecond)}}

      _ ->
        view
    end
  end

  def reage(view, _now_ms), do: view

  # ------------------------------------------------------------ the record

  defp record(doc, lim) do
    case check(shape(:record), doc, lim) do
      {:ok, rec} -> if references?(rec), do: {:ok, rec}, else: :error
      :error -> :error
    end
  end

  # A checked `how` must name one of the copies' check methods, and every id
  # waiting on the person must be an open ask.
  defp references?(rec), do: methods_known?(rec["copies"]) and asks_known?(rec["asks"])

  defp methods_known?(%{"state" => "available", "check_methods" => methods, "items" => copies}) do
    copies
    |> Enum.flat_map(& &1["places"])
    |> Enum.all?(fn place ->
      case place["checked"] do
        %{"how" => how} -> Map.has_key?(methods, how)
        _ -> true
      end
    end)
  end

  defp methods_known?(_), do: true

  defp asks_known?(%{"state" => "available", "items" => asks, "waiting_on_you" => waiting}) do
    open = MapSet.new(asks, & &1["id"])
    Enum.all?(waiting, &MapSet.member?(open, &1))
  end

  defp asks_known?(_), do: true

  # `check(spec, value, lim)` is `{:ok, declared}` or `:error`. `lim` is the
  # latest a `time` may be, in microseconds, or nil for no limit.
  defp check(:id, v, _), do: ok_if(str?(v, 1, @id_max), v)
  defp check(:text, v, _), do: ok_if(str?(v, 0, @text_max), v)
  defp check(:n, v, _), do: ok_if(is_integer(v) and v >= 0, v)
  defp check(:int, v, _), do: ok_if(is_integer(v), v)
  defp check(:number, v, _), do: ok_if(is_number(v), v)
  defp check(:positive, v, _), do: ok_if(is_number(v) and v > 0, v)
  defp check(:byte, v, _), do: ok_if(is_integer(v) and v >= 0 and v <= 255, v)
  defp check(:bool, v, _), do: ok_if(is_boolean(v), v)
  defp check(:date, v, _), do: ok_if(date?(v), v)
  defp check(:ftime, v, _), do: ok_if(time_us(v) != nil, v)

  defp check(:hex64, v, _),
    do: ok_if(is_binary(v) and String.match?(v, ~r/\A[0-9a-f]{64}\z/), v)

  defp check(:exit_result, v, _),
    do:
      ok_if(
        is_binary(v) and String.match?(v, ~r/\A(ok|unavailable|failed \(exit [0-9]{1,3}\))\z/),
        v
      )

  defp check(:time, v, lim) do
    case time_us(v) do
      nil -> :error
      us -> ok_if(lim == nil or us <= lim, v)
    end
  end

  defp check(:counts, v, _) when is_map(v),
    do: ok_if(Enum.all?(v, fn {k, x} -> k in @count_keys and is_integer(x) and x >= 0 end), v)

  defp check({:methods, max}, v, _) when is_map(v) and map_size(v) <= max,
    do: ok_if(Enum.all?(v, fn {k, x} -> str?(k, 1, @id_max) and str?(x, 0, @text_max) end), v)

  defp check({:const, c}, v, _), do: ok_if(v === c, v)
  defp check({:one_of, list}, v, _), do: ok_if(v in list, v)
  defp check({:null_or, _spec}, nil, _), do: {:ok, nil}
  defp check({:null_or, spec}, v, lim), do: check(spec, v, lim)
  defp check({:or_word, word, _spec}, word, _), do: {:ok, word}
  defp check({:or_word, _word, spec}, v, lim), do: check(spec, v, lim)

  defp check({:list, min, max, spec, key}, v, lim)
       when is_list(v) and length(v) >= min and length(v) <= max do
    case all(v, spec, lim, []) do
      {:ok, items} -> if unique?(items, key), do: {:ok, items}, else: :error
      :error -> :error
    end
  end

  defp check({:obj, fields}, v, lim) when is_map(v), do: take_fields(fields, v, lim, %{})

  defp check({:collection, fields}, %{"state" => "available"} = v, lim) do
    head = [
      {"state", {:const, "available"}, :req},
      {"observed_at", {:null_or, :time}, :req}
    ]

    check({:obj, head ++ fields}, v, lim)
  end

  # A collection the lab could not read: its reason, checked, and nothing else.
  # Any other key, `items` included, is undeclared here and dropped.
  defp check({:collection, _fields}, %{"state" => "unavailable"} = v, lim) do
    unread = [
      {"state", {:const, "unavailable"}, :req},
      {"observed_at", {:null_or, :time}, :req},
      {"why", :text, :req}
    ]

    check({:obj, unread}, v, lim)
  end

  defp check({:form, name}, v, lim) when is_map(v), do: check(form(name, v), v, lim)
  defp check(_spec, _v, _lim), do: :error

  defp ok_if(true, v), do: {:ok, v}
  defp ok_if(_, _), do: :error

  defp take_fields([], _v, _lim, acc), do: {:ok, acc}

  defp take_fields([{key, spec, need} | rest], v, lim, acc) do
    case Map.fetch(v, key) do
      {:ok, x} ->
        case check(spec, x, lim) do
          {:ok, c} -> take_fields(rest, v, lim, Map.put(acc, key, c))
          :error -> :error
        end

      :error when need == :opt ->
        take_fields(rest, v, lim, acc)

      :error ->
        :error
    end
  end

  defp all([], _spec, _lim, acc), do: {:ok, Enum.reverse(acc)}

  defp all([x | rest], spec, lim, acc) do
    case check(spec, x, lim) do
      {:ok, c} -> all(rest, spec, lim, [c | acc])
      :error -> :error
    end
  end

  defp unique?(_items, nil), do: true
  defp unique?(items, :self), do: length(Enum.uniq(items)) == length(items)
  defp unique?(items, key), do: length(Enum.uniq_by(items, &Map.get(&1, key))) == length(items)

  defp str?(s, min, max),
    do:
      is_binary(s) and byte_size(s) >= min and byte_size(s) <= max and
        not String.match?(s, ~r/[\x00-\x1f\x7f]/)

  defp time_us(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :microsecond)
      _ -> nil
    end
  end

  defp time_us(_), do: nil

  defp date?(v) when is_binary(v),
    do:
      String.match?(v, ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/) and
        match?({:ok, _}, Date.from_iso8601(v))

  defp date?(_), do: false

  # Entries with more than one form; the form is chosen by one field and the
  # chosen form is then checked whole.
  defp form(:place, %{"expected" => false}),
    do: {:obj, [{"id", :id, :req}, {"plain", :text, :req}, {"expected", :bool, :req}]}

  defp form(:place, %{"expected" => true}), do: shape(:place)

  # Only `state: "unavailable"` chooses the unread form. Any other item is a
  # measurement, where `state` is undeclared and dropped.
  defp form(:space, %{"state" => "unavailable"}),
    do:
      {:obj,
       [
         {"id", :id, :req},
         {"machine", :id, :req},
         {"plain", :text, :req},
         {"state", {:const, "unavailable"}, :req}
       ]}

  defp form(:space, _), do: shape(:space_item)

  defp form(:job, %{"runs_state" => _}),
    do:
      {:obj,
       shape(:job) ++
         [
           {"run_counts", {:const, nil}, :req},
           {"runs", {:const, nil}, :req},
           {"runs_state", {:const, "unavailable"}, :req},
           {"why", :text, :req}
         ]}

  defp form(:job, _),
    do:
      {:obj,
       shape(:job) ++
         [
           {"run_counts", :counts, :req},
           {"runs", {:list, 0, 16, shape(:run), nil}, :req},
           {"runs_omitted", :counts, :opt}
         ]}

  defp form(_name, _value), do: :invalid

  # ------------------------------------------------------------ lab-status/1
  #
  # The lab's committed record (A-72 revision 5, `lab/watch/lab-status.py`),
  # as AMENDMENT-1 section 4 states it. Caps are the lab's own.
  defp shape(:record) do
    {:obj,
     [
       {"schema", {:const, "lab-status/1"}, :req},
       {"run_id", :id, :req},
       {"machine", :id, :req},
       {"started_at", :time, :req},
       {"finished_at", :time, :req},
       {"window_started_at", :time, :req},
       {"window_finished_at", :time, :req},
       {"how", {:one_of, ~w(timer by_hand unavailable)}, :req},
       {"script_sha256", {:null_or, :hex64}, :req},
       {"valid_for_hours", :positive, :opt},
       {"rules_note", {:list, 0, 16, :text, nil}, :req},
       {"trimmed",
        {:list, 0, 8,
         {:one_of, ~w(non-ok-recent-3 non-ok-recent-1 retries-counted-only notes-40)}, nil},
        :opt},
       {"verdict", {:collection, shape(:verdict)}, :req},
       {"copies", {:collection, shape(:copies)}, :req},
       {"pools", {:collection, shape(:pools)}, :req},
       {"space", {:collection, shape(:space)}, :req},
       {"jobs", {:collection, shape(:jobs)}, :req},
       {"watches", {:collection, shape(:watches)}, :req},
       {"sign_in", {:collection, shape(:sign_in)}, :req},
       {"also_checked", {:collection, shape(:also_checked)}, :req},
       {"asks", {:collection, shape(:asks)}, :req}
     ]}
  end

  defp shape(:verdict) do
    [
      {"overall", {:one_of, ~w(clean warning failed)}, :req},
      {"counts", {:obj, [{"failed", :n, :req}, {"warning", :n, :req}]}, :req},
      {"items",
       {:list, 0, 64,
        {:obj,
         [
           {"id", :id, :req},
           {"level", {:one_of, ~w(failed warning)}, :req},
           {"plain", :text, :req}
         ]}, "id"}, :req},
      {"line", :text, :req},
      {"rules",
       {:obj,
        [
          {"judge_sha256", {:null_or, :hex64}, :req},
          {"laws", :text, :req},
          {"valid_for_hours_reason", :text, :req}
        ]}, :req}
    ]
  end

  defp shape(:copies) do
    [
      {"check_methods", {:methods, 32}, :req},
      {"items", {:list, 0, 32, shape(:copy), "id"}, :req}
    ]
  end

  defp shape(:copy) do
    {:obj,
     [
       {"id", :id, :req},
       {"plain", :text, :req},
       {"lives_on", :text, :req},
       {"places", {:list, 1, 8, {:form, :place}, "id"}, :req}
     ]}
  end

  defp shape(:place) do
    {:obj,
     [
       {"id", :id, :req},
       {"plain", :text, :req},
       {"expected", :bool, :req},
       {"max_age_hours", :number, :req},
       {"level", {:one_of, ~w(ok warning failed unavailable)}, :req},
       {"checked", shape(:checked), :req},
       {"newest_name", :text, :opt},
       {"newest_at", :time, :opt},
       {"placed_at", :time, :opt},
       {"observed_at", :time, :opt},
       {"age_from", {:one_of, ~w(checked_at unknown)}, :opt},
       {"age_hours", :number, :opt}
     ]}
  end

  defp shape(:checked) do
    {:obj,
     [
       {"result", {:one_of, ~w(match mismatch readable_only not_checked unavailable)}, :req},
       {"how", :id, :opt},
       {"where", :text, :opt},
       {"at", :time, :opt},
       {"detail", :text, :opt}
     ]}
  end

  defp shape(:pools), do: [{"items", {:list, 0, 8, shape(:pool), "name"}, :req}]

  defp shape(:pool) do
    {:obj,
     [
       {"name", :id, :req},
       {"plain_name", :text, :req},
       {"machine", :id, :req},
       {"health", :id, :req},
       {"last_scrub",
        {:or_word, "unavailable",
         {:obj,
          [
            {"finished_at", :time, :req},
            {"repaired", :text, :req},
            {"errors", :n, :req}
          ]}}, :req},
       {"drives", {:or_word, "unavailable", {:list, 0, 16, shape(:drive), nil}}, :req},
       {"observed_at", :time, :req},
       {"drives_observed_at", :time, :opt},
       {"size_bytes", :n, :opt},
       {"free_bytes", :n, :opt}
     ]}
  end

  # SMART's words, kept as the strings the lab recorded.
  defp shape(:drive) do
    {:obj,
     [
       {"id", :id, :req},
       {"health", :text, :opt},
       {"realloc", :text, :opt},
       {"pending", :text, :opt},
       {"uncorrect", :text, :opt},
       {"crc", :text, :opt}
     ]}
  end

  defp shape(:space), do: [{"items", {:list, 0, 16, {:form, :space}, "id"}, :req}]

  defp shape(:space_item) do
    {:obj,
     [
       {"id", :id, :req},
       {"machine", :id, :req},
       {"plain", :text, :req},
       {"free_bytes", :n, :req},
       {"size_bytes", :n, :req},
       {"measured_at", :time, :req}
     ]}
  end

  defp shape(:jobs) do
    [
      {"runs_policy", {:const, "non_ok_and_last_ok"}, :req},
      {"trigger_basis", {:one_of, ~w(inferred recorded)}, :req},
      {"items", {:list, 0, 32, {:form, :job}, "id"}, :req}
    ]
  end

  defp shape(:job) do
    [
      {"id", :id, :req},
      {"plain", :text, :req},
      {"machine", :text, :req},
      {"schedule", :text, :req},
      {"container", :text, :opt},
      {"timer", {:one_of, ~w(enabled disabled not_installed unavailable)}, :req},
      {"next_at", :ftime, :opt},
      {"trigger_basis", {:one_of, ~w(inferred recorded)}, :opt}
    ]
  end

  defp shape(:run) do
    {:obj,
     [
       {"start_at", {:null_or, :time}, :req},
       {"end_at", {:null_or, :time}, :req},
       {"result", {:one_of, ~w(ok failed skipped running unavailable)}, :req},
       {"exit_code", {:null_or, :byte}, :req},
       {"trigger", {:one_of, ~w(scheduled by_hand unavailable)}, :req},
       {"note", :text, :opt},
       {"retries", {:list, 0, 3, :text, nil}, :opt},
       {"retries_count", :n, :opt},
       {"retries_omitted", :n, :opt}
     ]}
  end

  defp shape(:watches), do: [{"items", {:list, 0, 8, shape(:watch), "id"}, :req}]

  defp shape(:watch) do
    {:obj,
     [
       {"id", :id, :req},
       {"plain", :text, :req},
       {"machine", :id, :req},
       {"started_on", :date, :req},
       {"length_days", :n, :req},
       {"day", :int, :req},
       {"ended", :bool, :req},
       {"readings", {:list, 0, 32, shape(:reading), "id"}, :req},
       {"level", {:one_of, ~w(ok warning failed)}, :req},
       {"rule", :text, :req}
     ]}
  end

  defp shape(:reading) do
    {:obj,
     [
       {"id", :id, :req},
       {"plain", :text, :req},
       {"result", {:one_of, ~w(ok warning failed unavailable)}, :req},
       {"detail", :text, :req},
       {"observed_at", :time, :opt}
     ]}
  end

  defp shape(:sign_in) do
    [
      {"machine", :id, :req},
      {"renewal", {:one_of, ~w(configured not_configured unavailable)}, :req},
      {"expires_at", :ftime, :req},
      {"renewals_in_window", :n, :req},
      {"warnings_in_window", :n, :req},
      {"last_renewed_at", :time, :opt},
      {"long_term_ends_at", :ftime, :opt}
    ]
  end

  defp shape(:also_checked) do
    [
      {"items",
       {:list, 0, 16,
        {:obj,
         [
           {"id", :id, :req},
           {"plain", :text, :req},
           {"result", :exit_result, :req},
           {"observed_at", :time, :opt}
         ]}, "id"}, :req}
    ]
  end

  defp shape(:asks) do
    [
      {"items",
       {:list, 0, 64,
        {:obj,
         [
           {"id", :id, :req},
           {"plain", :text, :req},
           {"line", {:null_or, :text}, :req},
           {"changed_at", :time, :req},
           {"addressed_to", :id, :req},
           {"since", :text, :req},
           {"record", :text, :req}
         ]}, "id"}, :req},
      {"recently_closed",
       {:list, 0, 64,
        {:obj,
         [
           {"id", :id, :req},
           {"state", {:one_of, ~w(answered withdrawn)}, :req},
           {"changed_at", :time, :req},
           {"record", :text, :req}
         ]}, "id"}, :req},
      {"waiting_on_you", {:list, 0, 64, :id, :self}, :req},
      {"note", :text, :req}
    ]
  end
end
