defmodule Ampd.AuthorityLog.Delta do
  @moduledoc """
  What changed between a registry's last durable state and its next one, as
  a short list of ops — and how replay applies them.

  A registry's state is a map of top-level fields. The diff is taken in the
  registry's own process at `Ampd.Store.save/2` time, against the state it
  last saved, so **no registry changed shape** to move onto the log:

      field unchanged (the same term)   nothing
      field removed                     {:unset, store, field}
      a list that kept its prefix       {:list, store, field, len, [{index, element}]}
      a map that only gained keys       {:merge, store, field, %{added}}
      anything else                     {:set, store, field, value}
      no durable state yet              {:init, store, whole_state}

  The list case is the one that matters. The effect, receipt, grant and
  approval collections are lists the registries append to and update in
  place with `Enum.map/2`, which returns an unchanged element as the SAME
  term — so walking the old and new lists together costs one pointer
  comparison per unchanged element (`===` short-circuits on identity), and
  only the changed and appended elements are serialized. A list that shrank,
  or where more than a quarter changed (an insertion in the middle shifts
  everything after it), is written whole with `{:set, …}`: always correct,
  merely larger.

  The map case exists for retention (`Ampd.Retention`): each store's index of
  what it has retired only ever gains keys, and writing it whole on every
  retirement would make the retirement record grow with history. A map field
  whose every old key is still present with the same term (a pointer
  comparison, as for lists) is written as the added keys alone. Anything else
  — a key removed, a value changed — is `{:set, …}` exactly as before.

  `len` in a list op is a LOWER bound, applied as `max`. Two writers' list ops
  on one list therefore commute when they touch different indices, which is
  what lets a concurrent append be written while an open transaction's
  append is still held (`Ampd.AuthorityLog.group/1`). A hole — an index a
  length covers and no durable op ever wrote, because its writer's
  transaction never committed — is skipped when the list is materialized.
  """

  # ------------------------------------------------------------------ diff

  def diff(name, :absent, cur), do: [{:init, name, cur}]

  def diff(name, prev, cur) when is_map(prev) and is_map(cur) do
    changed =
      Enum.flat_map(cur, fn {k, cv} ->
        case Map.fetch(prev, k) do
          {:ok, pv} when pv === cv -> []
          {:ok, pv} when is_list(pv) and is_list(cv) -> list_diff(name, k, pv, cv)
          {:ok, pv} when is_map(pv) and is_map(cv) -> map_diff(name, k, pv, cv)
          _ -> [{:set, name, k, cv}]
        end
      end)

    removed =
      for {k, _} <- prev, not Map.has_key?(cur, k), do: {:unset, name, k}

    changed ++ removed
  end

  defp list_diff(name, k, pv, cv) do
    case walk(pv, cv, 0, [], 0) do
      {:ok, puts, len, n} when n <= 64 or n * 4 <= len -> [{:list, name, k, len, puts}]
      _ -> [{:set, name, k, cv}]
    end
  end

  # Growth only: every old key still maps to the SAME term. An empty or
  # shrunk map, or any changed value, is written whole.
  defp map_diff(name, k, pv, cv) do
    grew? =
      map_size(pv) > 0 and map_size(cv) > map_size(pv) and
        Enum.all?(pv, fn {pk, v} ->
          case Map.fetch(cv, pk) do
            {:ok, cv2} -> cv2 === v
            :error -> false
          end
        end)

    if grew?,
      do: [{:merge, name, k, Map.reject(cv, fn {ck, _} -> Map.has_key?(pv, ck) end)}],
      else: [{:set, name, k, cv}]
  end

  defp walk([p | ps], [c | cs], i, acc, n) when p === c, do: walk(ps, cs, i + 1, acc, n)
  defp walk([_ | ps], [c | cs], i, acc, n), do: walk(ps, cs, i + 1, [{i, c} | acc], n + 1)
  defp walk([], [], i, acc, n), do: {:ok, Enum.reverse(acc), i, n}
  defp walk([], [c | cs], i, acc, n), do: walk([], cs, i + 1, [{i, c} | acc], n + 1)
  defp walk([_ | _], [], _i, _acc, _n), do: :shrunk

  # ---------------------------------------------------------------- replay
  #
  # An image is a map of field → {:v, value} | {:l, len, %{index => element}}.

  def apply_op({:init, name, s}, images), do: Map.put(images, name, encode(s))

  def apply_op({:set, name, k, v}, images),
    do: Map.update(images, name, %{k => field(v)}, &Map.put(&1, k, field(v)))

  def apply_op({:merge, name, k, added}, images) do
    img = Map.get(images, name, %{})

    v =
      case Map.get(img, k) do
        {:v, m} when is_map(m) -> Map.merge(m, added)
        _ -> added
      end

    Map.put(images, name, Map.put(img, k, {:v, v}))
  end

  def apply_op({:unset, name, k}, images),
    do: Map.update(images, name, %{}, &Map.delete(&1, k))

  def apply_op({:list, name, k, len, puts}, images) do
    img = Map.get(images, name, %{})

    {old, m} =
      case Map.get(img, k) do
        {:l, l, m} -> {l, m}
        {:v, list} when is_list(list) -> {length(list), indexed(list)}
        _ -> {0, %{}}
      end

    m = Enum.reduce(puts, m, fn {i, x}, m -> Map.put(m, i, x) end)
    Map.put(images, name, Map.put(img, k, {:l, max(old, len), m}))
  end

  def materialize(img) do
    Map.new(img, fn
      {k, {:v, v}} ->
        {k, v}

      {k, {:l, len, m}} ->
        {k, for(i <- 0..(len - 1)//1, Map.has_key?(m, i), do: Map.fetch!(m, i))}
    end)
  end

  @doc """
  Close the holes replay can leave. After a crash, a concurrent write that was
  durable can sit past an index whose writer's transaction never committed;
  materializing skips the hole, so the image is re-encoded densely before any
  registry diffs against it — otherwise the registry's next append would name
  an index the image already holds.
  """
  def compact(img) do
    if Enum.any?(img, fn {_, f} -> match?({:l, len, m} when map_size(m) != len, f) end),
      do: img |> materialize() |> encode(),
      else: img
  end

  defp encode(s), do: Map.new(s, fn {k, v} -> {k, field(v)} end)
  defp field(v) when is_list(v), do: {:l, length(v), indexed(v)}
  defp field(v), do: {:v, v}
  defp indexed(list), do: list |> Enum.with_index() |> Map.new(fn {x, i} -> {i, x} end)

  # ------------------------------------------------ what a transaction holds
  #
  # The keys an open transaction's ops touch, at three grains — a whole store
  # (`:init`), a whole field (`:set`/`:unset`), one list index (`:list`) — so
  # a concurrent write can be checked against them before it is written.

  def no_keys,
    do: %{stores: MapSet.new(), whole: MapSet.new(), fields: MapSet.new(), idx: MapSet.new()}

  def keys(ops, acc) do
    Enum.reduce(ops, acc, fn
      {:init, n, _}, a ->
        %{a | stores: MapSet.put(a.stores, n), whole: MapSet.put(a.whole, n)}

      {:set, n, k, _}, a ->
        %{a | stores: MapSet.put(a.stores, n), fields: MapSet.put(a.fields, {n, k})}

      {:unset, n, k}, a ->
        %{a | stores: MapSet.put(a.stores, n), fields: MapSet.put(a.fields, {n, k})}

      {:merge, n, k, _}, a ->
        %{a | stores: MapSet.put(a.stores, n), fields: MapSet.put(a.fields, {n, k})}

      {:list, n, k, _len, puts}, a ->
        idx = Enum.reduce(puts, a.idx, fn {i, _}, s -> MapSet.put(s, {n, k, i}) end)
        %{a | stores: MapSet.put(a.stores, n), idx: MapSet.put(idx, {n, k})}
    end)
  end

  def conflicts?(ops, held) do
    Enum.any?(ops, fn
      {:init, n, _} ->
        MapSet.member?(held.stores, n)

      {:set, n, k, _} ->
        field_held?(held, n, k)

      {:unset, n, k} ->
        field_held?(held, n, k)

      {:merge, n, k, _} ->
        field_held?(held, n, k)

      {:list, n, k, _len, puts} ->
        MapSet.member?(held.whole, n) or MapSet.member?(held.fields, {n, k}) or
          Enum.any?(puts, fn {i, _} -> MapSet.member?(held.idx, {n, k, i}) end)
    end)
  end

  defp field_held?(held, n, k),
    do:
      MapSet.member?(held.whole, n) or MapSet.member?(held.fields, {n, k}) or
        MapSet.member?(held.idx, {n, k})
end
