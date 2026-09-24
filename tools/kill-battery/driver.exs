# kill-battery driver — continuous effects through Super's real effect path, killed from outside.
#
#   cd ampd && MIX_ENV=test AMPD_DATA_DIR=<world> KB_ACKS=<file> KB_REPORT=<file> [KB_SEED=1] \
#     mix run ../tools/kill-battery/driver.exs
#
# Run by `tools/kill-battery/battery.mjs`, which SIGKILLs this BEAM at a random moment and boots it
# again on the same world. On every boot, before any new effect, this writes a RECOVERY REPORT of
# what the runtime recovered (seals, every effect, every receipt, every grant, the recovery listing,
# the witness files' tails). The parent checks that report against the acknowledgements.
#
# THE ROUTE is the write-boundary suite's C1 (`test/b2_write_boundary_test.exs`): a one-shot grant for
# `github.pr.draft`, then `Gateway.perform/4` with the default adapter. Through the same Effects,
# Receipts and GrantRegistry saves and the same witness as every effect. No daemon, no TRVM.
#
# ACKNOWLEDGEMENTS go to KB_ACKS, outside the data dir (seeding resets the data dir). One JSON line per
# event, written with `:file.write` on a raw fd, which is one write(2). A write that has returned is in
# the kernel's page cache and SURVIVES the process being SIGKILLed; it would not survive the MACHINE
# losing power, which this battery does not test. So no fsync is taken here, and the side file adds no
# sync to the timing under test. An `ack` line is written only after `perform` has returned, so every
# ack line names a transition the runtime acknowledged.
alias Ampd.{Authority, Effects, Gateway, GrantRegistry, Receipts}

cap = "github.pr.draft"
resource = "traaviis/trvm"
req = %{"er" => "er-github.pr.draft", "rev" => 1, "params" => Ampd.Core.params()["pr.draft"]}

{:ok, fd} = :file.open(System.fetch_env!("KB_ACKS"), [:append, :raw, :binary])
now = fn -> System.os_time(:microsecond) end
w = fn map -> :ok = :file.write(fd, JSON.encode!(Map.put(map, "t_us", now.())) <> "\n") end

# ------------------------------------------------------------------ the recovery report
witness =
  for path <- Ampd.Effects.Witness.files() do
    lines = path |> File.read!() |> String.split("\n")
    {body, last} = {Enum.drop(lines, -1), List.last(lines)}
    decodes = fn l -> match?({:ok, _}, JSON.decode(l)) end

    %{
      "file" => Path.basename(path),
      "complete_lines" => Enum.count(body, &(&1 != "")),
      # a file ends in "\n" when its last append completed; anything after the last "\n" is a torn line
      "torn_tail_bytes" => byte_size(last),
      "torn_tail_decodes" => if(last == "", do: nil, else: decodes.(last)),
      "undecodable_complete_lines" => Enum.count(body, &(&1 != "" and not decodes.(&1)))
    }
  end

seals = for {mod, why} <- Ampd.seals(), do: %{"store" => inspect(mod), "reason" => why}

report = %{
  "schema" => "kill-battery-recovery@1",
  "os_pid" => System.pid(),
  "data_dir" => Ampd.Store.data_dir(),
  "world" => Ampd.World.read(),
  "seals" => seals,
  "effects" =>
    for e <- Effects.all() do
      %{
        "id" => e["id"],
        "state" => e["state"],
        "history" => Enum.map(e["history"] || [], & &1["state"]),
        "grant_ref" => e["grant_ref"],
        "idempotency_key" => e["idempotency_key"]
      }
    end,
  "receipts" =>
    for r <- Receipts.all() do
      %{"id" => r["id"], "kind" => r["kind"], "effect_ref" => r["effect_ref"]}
    end,
  "grants" =>
    for g <- GrantRegistry.list(), g["capability"] == cap do
      %{"id" => g["id"], "status" => g["status"], "consumptions" => g["consumptions"] || []}
    end,
  "recovery_listing" => (if seals == [], do: Effects.recovery_listing(), else: nil),
  # The authority log's own account (a tree without one reports nil): the torn tails it truncated and
  # named on this boot, and its counters.
  "authority_log" =>
    if(Code.ensure_loaded?(Ampd.AuthorityLog) and Process.whereis(Ampd.AuthorityLog),
      do: Map.drop(Ampd.AuthorityLog.status(), ["stores"]),
      else: nil
    ),
  "witness" => witness
}

File.write!(System.fetch_env!("KB_REPORT"), JSON.encode!(report))
w.(%{"event" => "boot", "os_pid" => System.pid(), "sealed" => seals != [],
     "effects" => length(report["effects"]), "receipts" => length(report["receipts"])})

if seals != [] do
  # A sealed world takes no more effects; the parent starts a new one.
  w.(%{"event" => "sealed_stop"})
  System.halt(0)
end

if System.get_env("KB_SEED") == "1" do
  Ampd.reset_demo()
  Authority.revoke_domain(cap)
  w.(%{"event" => "seeded"})
end

w.(%{"event" => "loop_started"})

Stream.iterate(1, &(&1 + 1))
|> Enum.each(fn i ->
  g = Authority.one_shot(cap)
  w.(%{"event" => "grant", "i" => i, "grant" => g["id"]})
  w.(%{"event" => "perform_start", "i" => i, "grant" => g["id"]})
  r = Gateway.perform(cap, resource, Gateway.ctx(), req)

  w.(%{"event" => "ack", "i" => i, "grant" => g["id"], "allow" => r["allow"] == true,
       "effect_id" => r["effect_id"], "receipt_id" => get_in(r, ["receipt", "id"]),
       "reason" => if(r["allow"], do: nil, else: r["reason"])})

  unless r["allow"] do
    w.(%{"event" => "refused_stop"})
    System.halt(3)
  end
end)
