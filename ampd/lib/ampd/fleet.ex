defmodule Ampd.Fleet do
  @moduledoc """
  Bounded, ephemeral host observations. The operator-configured local collector
  owns SSH; this process reads its atomic snapshot and publishes through the
  ordinary operator projection. No enrollment, authority, commands or readiness
  are inferred from a host being reachable. Stale observations expire in-view.
  """
  use GenServer
  @limit 65_536
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def projection, do: GenServer.call(__MODULE__, :projection)

  def init(_) do
    path = snapshot_path()
    send(self(), :refresh)
    {:ok, %{path: path, view: empty(if(path, do: "unavailable", else: "unconfigured"))}}
  end

  # Device settings are local operator input, never part of the world projection.
  # An explicit empty override disables observation, even when settings are saved.
  def snapshot_path(env \\ System.get_env()) do
    case Map.fetch(env, "SUPER_FLEET_SNAPSHOT") do
      {:ok, ""} -> nil
      {:ok, path} -> path
      :error -> saved_snapshot_path(env)
    end
  end

  defp saved_snapshot_path(env) do
    base =
      absolute(env["XDG_CONFIG_HOME"]) ||
        case absolute(env["HOME"]) do
          nil -> nil
          home -> Path.join(home, ".config")
        end

    with base when is_binary(base) <- base,
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @limit <-
           File.open(
             Path.join(base, "super/fleet.json"),
             [:read, :binary],
             &IO.binread(&1, @limit + 1)
           ),
         {:ok, %{"schema" => "super-device-fleet@1", "snapshotPath" => path}} <-
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
  def handle_call(:projection, _, state), do: {:reply, state.view, state}

  def handle_info(:refresh, state) do
    view = if state.path, do: read(state.path), else: empty("unconfigured")
    if view != state.view, do: Ampd.AuthorityCoordinator.touched()
    Process.send_after(self(), :refresh, 1_000)
    {:noreply, %{state | view: view}}
  end

  defp empty(status), do: %{"schema" => "fleet-view@1", "status" => status, "hosts" => []}

  defp read(path) do
    with {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @limit <-
           File.open(path, [:read, :binary], &IO.binread(&1, @limit + 1)),
         {:ok, value} <- JSON.decode(bytes) do
      normalize(value, System.system_time(:millisecond))
    else
      _ -> empty("unavailable")
    end
  rescue
    _ -> empty("unavailable")
  end

  def normalize(%{"schema" => "fleet-snapshot@1", "hosts" => hosts}, now)
      when is_list(hosts) and length(hosts) <= 8 do
    rows = Enum.map(hosts, &host(&1, now))
    ids = Enum.map(rows, & &1["id"])

    if Enum.any?(rows, &is_nil/1) or length(Enum.uniq(ids)) != length(ids),
      do: empty("unavailable"),
      else: %{"schema" => "fleet-view@1", "status" => "configured", "hosts" => rows}
  rescue
    _ -> empty("unavailable")
  end

  def normalize(_, _), do: empty("unavailable")

  defp host(h, now) do
    with true <- is_map(h),
         true <- text?(h["id"], 64),
         true <- text?(h["label"], 100),
         true <- h["status"] in ["observed", "unavailable"],
         at when is_integer(at) <- h["observedAt"],
         true <- at <= now + 5_000,
         true <- text?(h["nextStep"], 300),
         true <- text?(h["reason"], 300, true) do
      status = if now - at > 90_000, do: "stale", else: h["status"]
      base = Map.take(h, ["id", "label", "observedAt", "nextStep", "reason"])

      if h["status"] == "observed" do
        i = h["inventory"]

        with true <- is_map(i),
             true <- text?(i["hostname"], 100),
             true <- i["os"] in ["Linux", "FreeBSD"],
             true <- text?(i["release"], 100),
             true <- i["hypervisor"] in ["proxmox", "bhyve", "none"],
             true <- is_integer(i["logicalCpus"]) and i["logicalCpus"] in 1..4096,
             true <- is_integer(i["memoryBytes"]) and i["memoryBytes"] > 0,
             guests when is_list(guests) and length(guests) <= 24 <- i["guests"],
             true <- Enum.all?(guests, &guest?/1),
             true <- length(Enum.uniq_by(guests, & &1["id"])) == length(guests) do
          inventory =
            Map.take(i, ["hostname", "os", "release", "hypervisor", "logicalCpus", "memoryBytes"])

          guests =
            Enum.map(guests, fn g ->
              Map.take(g, ["id", "label", "status"])
              |> Map.put("status", if(status == "observed", do: g["status"], else: "unknown"))
            end)

          with {:ok, workers} <- workers(h["workers"], now) do
            Map.merge(base, %{
              "status" => status,
              "inventory" => Map.put(inventory, "guests", guests),
              "workers" => workers,
              "workerReady" => ready?(workers, status)
            })
          else
            _ -> nil
          end
        else
          _ -> nil
        end
      else
        with {:ok, workers} <- workers(h["workers"], now) do
          Map.merge(base, %{
            "status" => status,
            "workers" => workers,
            "workerReady" => ready?(workers, status)
          })
        else
          _ -> nil
        end
      end
    else
      _ -> nil
    end
  end

  # Worker readiness is DERIVED here and nowhere else: from an answer the collector
  # got out of the guest's own check endpoint (`ready`), aged like the host
  # observation (an answer older than the window reads as no answer), and only
  # while the host itself is currently observed. A snapshot that merely SAYS
  # `workerReady: true` without a fresh answer behind it is still false.
  @ready_window_ms 90_000
  defp ready?(workers, "observed"), do: Enum.any?(workers, & &1["ready"])
  defp ready?(_, _), do: false
  defp workers(nil, _), do: {:ok, []}

  defp workers(list, now) when is_list(list) and length(list) <= 2 do
    rows = Enum.map(list, &worker(&1, now))
    ids = Enum.map(rows, &(&1 && &1["guest"]))

    if Enum.any?(rows, &is_nil/1) or length(Enum.uniq(ids)) != length(ids),
      do: :error,
      else: {:ok, rows}
  end

  defp workers(_, _), do: :error

  defp worker(w, now) do
    with true <- is_map(w),
         true <- text?(w["guest"], 64),
         true <- is_boolean(w["ready"]),
         at when is_integer(at) <- w["checkedAt"],
         true <- at <= now + 5_000,
         true <- text?(w["reason"], 300, true),
         {:ok, last} <- last_check(w["lastCheck"]) do
      fresh = now - at <= @ready_window_ms

      %{
        "guest" => w["guest"],
        "checkedAt" => at,
        "ready" => w["ready"] and fresh,
        "reason" =>
          if(w["ready"] and not fresh,
            do: "The last readiness answer has expired.",
            else: w["reason"]
          ),
        "lastCheck" => last
      }
    else
      _ -> nil
    end
  end

  defp last_check(nil), do: {:ok, nil}

  defp last_check(%{"id" => id, "state" => state, "at" => at} = l)
       when is_binary(id) and is_integer(at) and
              state in ["prepared", "reserved", "unknown", "completed"] do
    verdict = l["verdict"]

    if Regex.match?(~r/^fc-[a-f0-9]{32}$/, id) and
         (is_nil(verdict) or verdict in ["pass", "fail"]),
       do: {:ok, %{"id" => id, "state" => state, "verdict" => verdict, "at" => at}},
       else: :error
  end

  defp last_check(_), do: :error

  defp guest?(g),
    do:
      is_map(g) and text?(g["id"], 64) and text?(g["label"], 100) and
        g["status"] in ["running", "stopped", "present", "unknown"]

  defp text?(s, max, allow_empty \\ false),
    do:
      is_binary(s) and byte_size(s) <= max and (allow_empty or byte_size(s) > 0) and
        not String.match?(s, ~r/[\x00-\x1f\x7f]/)
end
