defmodule Ampd.LabTest do
  use ExUnit.Case, async: false
  alias Ampd.Lab

  # The lab's record of 2026-10-16, cut to one or two entries of each form
  # (superlane/t67 AMENDMENT-1 section 4). Every field in it is declared, so
  # the configured view's `record` equals it exactly.
  @example ~S"""
  {
  "schema":"lab-status/1",
  "run_id":"20261016-1952-watch",
  "machine":"px13",
  "started_at":"2026-10-16T19:52:33-05:00",
  "finished_at":"2026-10-16T19:56:24-05:00",
  "window_started_at":"2026-10-15T19:52:33-05:00",
  "window_finished_at":"2026-10-16T19:52:33-05:00",
  "how":"by_hand",
  "script_sha256":"e3e8f01090d76c604894d81b1d1b727026b16cf0b535ab0e3890fbc748b33722",
  "valid_for_hours":26,
  "rules_note":["Finding ids are positional; stable ids, and model ids for pools, disks and drives, later (A72-5)."],
  "verdict":{"state":"available","observed_at":"2026-10-16T19:56:24-05:00","overall":"warning","counts":{"failed":0,"warning":1},"items":[{"id":"finding-1","level":"warning","plain":"S3 compared 0 files"}],"line":"lab-daily-watch: WARNING day 7 of 14: 1 warnings (S3 compared 0 files)","rules":{"judge_sha256":"14dc00c28d336d0b104c62b5fafa1fe7caeb4fdb8c104ecabfba57cd892026af","laws":"WATCH-LAWS.md (W1-W21)","valid_for_hours_reason":"The check runs once a day: a record stays good until the next day's run plus two hours of slack."}},
  "copies":{"state":"available","observed_at":"2026-10-16T19:56:24-05:00","check_methods":{"s1-hash":"the copy's sums, made at the source, compared","gitec-readback":"refs read back from gitec"},"items":[{"id":"keycloak","plain":"Keycloak's database copies","lives_on":"CT 150 (Keycloak)","places":[{"id":"locuchest","plain":"locuchest's backup folder","expected":true,"max_age_hours":26,"newest_name":"20261016T081016Z","newest_at":"2026-10-16T03:10:16-05:00","placed_at":"2026-10-16T03:37:56-05:00","observed_at":"2026-10-16T19:52:45-05:00","checked":{"how":"s1-hash","where":"px13","at":"2026-10-16T03:41:23-05:00","result":"match","detail":"55 of 55"},"age_hours":16.3,"level":"ok"},{"id":"mac","plain":"the Mac","expected":false}]},{"id":"projectmac","plain":"the ProjectMac repository","lives_on":"the Mac","places":[{"id":"gitec","plain":"gitec (CT 120)","expected":true,"max_age_hours":30,"observed_at":"2026-10-16T19:56:17-05:00","checked":{"how":"gitec-readback","where":"px13","at":"2026-10-16T18:20:06-05:00","result":"match","detail":"ok OK"},"age_from":"checked_at","age_hours":1.7,"level":"ok"},{"id":"github","plain":"GitHub","expected":true,"max_age_hours":30,"checked":{"result":"unavailable","detail":"its evidence could not be read (KeyError)"},"age_from":"unknown","level":"unavailable"}]}]},
  "pools":{"state":"available","observed_at":"2026-10-16T19:52:37-05:00","items":[{"name":"backup4t","plain_name":"the terramaster silo one","machine":"locuchest","health":"ONLINE","last_scrub":{"finished_at":"2026-10-11T00:36:39-05:00","repaired":"0B","errors":0},"drives":[{"id":"WD-WX62D318T70J","health":"PASSED","realloc":"0","pending":"0","uncorrect":"0","crc":"0"}],"observed_at":"2026-10-16T19:52:37-05:00","drives_observed_at":"2026-10-16T19:52:37-05:00","size_bytes":3985729650688,"free_bytes":3371494833536},{"name":"terramaster-four-bays","plain_name":"the terramaster four bays","machine":"locuchest","health":"unavailable","last_scrub":"unavailable","drives":"unavailable","observed_at":"2026-10-16T19:52:37-05:00"}]},
  "space":{"state":"available","observed_at":"2026-10-16T19:52:33-05:00","items":[{"id":"px13-root","machine":"px13","plain":"the PX13's root disk","free_bytes":70321811456,"size_bytes":969450344448,"measured_at":"2026-10-16T19:52:33-05:00"},{"id":"locuchest-root","machine":"locuchest","plain":"locuchest's root disk","state":"unavailable"}]},
  "jobs":{"state":"available","observed_at":"2026-10-16T19:56:18-05:00","runs_policy":"non_ok_and_last_ok","trigger_basis":"inferred","items":[{"id":"gitec-push","plain":"the 2-hourly gitec push","machine":"px13","schedule":"every 2 hours at :17","timer":"enabled","next_at":"2026-10-16T20:17:00-05:00","run_counts":{"ok":11,"failed":1},"runs":[{"start_at":"2026-10-16T08:17:01-05:00","end_at":"2026-10-16T08:19:40-05:00","result":"failed","exit_code":1,"trigger":"scheduled","note":"FAILED: 1 of 53 repositories (super-live)","retries":["mirror-retry 1: super-live"],"retries_count":1},{"start_at":"2026-10-16T18:17:01-05:00","end_at":"2026-10-16T18:20:06-05:00","result":"ok","exit_code":0,"trigger":"scheduled"}],"runs_omitted":{"ok":10}},{"id":"projectmac-push","plain":"the Mac's ProjectMac push","machine":"the Mac","schedule":"every 2 hours (launchd)","timer":"unavailable","run_counts":null,"runs":null,"runs_state":"unavailable","why":"not read from the PX13 (the Mac is not reached by the check)"},{"id":"daily-check","plain":"the lab's daily check","machine":"px13","schedule":"09:40 daily (by hand until the timer)","timer":"not_installed","trigger_basis":"recorded","run_counts":{"ok":1},"runs":[{"start_at":"2026-10-16T19:52:33-05:00","end_at":"2026-10-16T19:56:24-05:00","result":"ok","exit_code":0,"trigger":"by_hand","note":"20261016-1952-watch (this run)"}]}]},
  "watches":{"state":"available","observed_at":"2026-10-16T19:53:17-05:00","items":[{"id":"ram-watch","plain":"locuchest's RAM watch","machine":"locuchest","started_on":"2026-10-10","length_days":14,"day":7,"ended":false,"readings":[{"id":"kernel","plain":"kernel memory errors","result":"ok","detail":"0 hits","observed_at":"2026-10-16T19:53:17-05:00"},{"id":"s3","plain":"S3: the silo copies compared","result":"warning","detail":"not read"}],"level":"warning","rule":"Stop the watch and replace both sticks on any kernel hit or any copy difference."}]},
  "sign_in":{"state":"available","observed_at":"2026-10-16T19:52:46-05:00","machine":"px13","renewal":"configured","expires_at":"2026-10-16T21:44:46-05:00","renewals_in_window":3,"warnings_in_window":0,"last_renewed_at":"2026-10-16T13:45:04-05:00","long_term_ends_at":"2026-10-31T01:23:58-05:00"},
  "also_checked":{"state":"available","observed_at":"2026-10-16T19:53:17-05:00","items":[{"id":"wifi-lock","plain":"the PX13's Wi-Fi lock (R165)","result":"ok","observed_at":"2026-10-16T19:52:33-05:00"},{"id":"cd-floor-01","plain":"cd-floor-01","result":"failed (exit 1)"}]},
  "asks":{"state":"available","observed_at":"2026-10-11T15:00:00-05:00","items":[{"id":"daily-check-timer","plain":"Turn on the daily check's 09:40 timer.","line":"yes, install the lab daily check timer","changed_at":"2026-10-11T08:35:00-05:00","addressed_to":"travis","since":"2026-10-11","record":"e77e2b28"}],"recently_closed":[{"id":"gitleaks","state":"answered","changed_at":"2026-10-11T09:51:00-05:00","record":"71bac30c"}],"waiting_on_you":["daily-check-timer"],"note":"only what lab chats recorded; closed in the last 7 days: recently_closed"}
  }
  """

  defp doc, do: JSON.decode!(@example)

  # The record's latest `time`: its finish.
  defp now, do: ms("2026-10-16T19:56:24-05:00")

  defp ms(at) do
    {:ok, dt, _} = DateTime.from_iso8601(at)
    DateTime.to_unix(dt, :millisecond)
  end

  defp iso(at_ms), do: at_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  defp iso_us(at_us), do: at_us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp view(d), do: Lab.decode(JSON.encode!(d), now())
  defp view_at(d, at_ms), do: Lab.decode(JSON.encode!(d), at_ms)

  defp unavailable(why), do: %{"schema" => "lab-view@1", "status" => "unavailable", "why" => why}

  defp configured?(v), do: v["status"] == "configured"

  defp at(path), do: Enum.map(path, fn i when is_integer(i) -> Access.at(i); k -> k end)
  defp set(d, path, v), do: put_in(d, at(path), v)

  defp drop(d, [key]), do: Map.delete(d, key)

  defp drop(d, path) do
    {parent, [key]} = Enum.split(path, -1)
    update_in(d, at(parent), &Map.delete(&1, key))
  end

  defp pad(bytes, size), do: bytes <> String.duplicate(" ", size - byte_size(bytes))

  defp tmp do
    dir = Path.join(System.tmp_dir!(), "lab-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_settings(base, record_path) do
    File.mkdir_p!(Path.join(base, "super"))

    File.write!(
      Path.join(base, "super/lab.json"),
      JSON.encode!(%{"schema" => "super-device-lab@1", "recordPath" => record_path})
    )
  end

  # A reader's state before its first tick.
  defp fresh(path), do: %{path: path, stamp: :none, view: nil, racy: false}

  # The first wall clock (ms) at which a reading of `path` finds both its times
  # at least 2 s older: the stamp is trusted from here on.
  defp settled(path) do
    st = File.stat!(path, time: :posix)
    (max(st.mtime, st.ctime) + 2) * 1_000
  end

  # An unknown key on every map, except the two whose keys are data.
  defp salt(m) when is_map(m) do
    m
    |> Map.new(fn {k, v} ->
      {k, if(k in ["check_methods", "run_counts", "runs_omitted"], do: v, else: salt(v))}
    end)
    |> Map.put("x_unknown", %{"deep" => ["x"]})
  end

  defp salt(l) when is_list(l), do: Enum.map(l, &salt/1)
  defp salt(v), do: v

  describe "where the reader looks" do
    test "the settings live in this instance's state folder, and an explicit override wins" do
      state = Path.join(tmp(), "state")
      env = %{"XDG_STATE_HOME" => state}
      assert Lab.record_path(env) == nil
      write_settings(state, "/lab/lab-status.json")
      assert Lab.record_path(env) == "/lab/lab-status.json"
      assert Lab.record_path(Map.put(env, "SUPER_LAB_STATUS", "")) == nil
      assert Lab.record_path(Map.put(env, "SUPER_LAB_STATUS", "/override.json")) == "/override.json"

      settings = Path.join(state, "super/lab.json")

      good =
        JSON.encode!(%{"schema" => "super-device-lab@1", "recordPath" => "/lab/lab-status.json"})

      File.write!(settings, pad(good, 65_536))
      assert Lab.record_path(env) == "/lab/lab-status.json"

      for bytes <- [
            "{",
            "[]",
            JSON.encode!(%{"schema" => "super-device-fleet@1", "recordPath" => "/lab/a.json"}),
            JSON.encode!(%{"schema" => "super-device-lab@1", "snapshotPath" => "/lab/a.json"}),
            JSON.encode!(%{"schema" => "super-device-lab@1", "recordPath" => "relative.json"}),
            JSON.encode!(%{"schema" => "super-device-lab@1", "recordPath" => 7}),
            pad(good, 65_537)
          ] do
        File.write!(settings, bytes)
        assert Lab.record_path(env) == nil
      end
    end

    test "without a usable XDG_STATE_HOME it reads HOME/.local/state, and never the fleet's folder" do
      dir = tmp()
      home = Path.join(dir, "home")
      write_settings(Path.join(home, ".local/state"), "/lab/a.json")
      assert Lab.record_path(%{"HOME" => home}) == "/lab/a.json"
      assert Lab.record_path(%{"HOME" => home, "XDG_STATE_HOME" => ""}) == "/lab/a.json"
      assert Lab.record_path(%{"HOME" => home, "XDG_STATE_HOME" => "relative"}) == "/lab/a.json"

      # super-silow: its own state folder, which holds no settings.
      assert Lab.record_path(%{"HOME" => home, "XDG_STATE_HOME" => Path.join(dir, "silow")}) ==
               nil

      # Settings only where the fleet's live are not read.
      other = Path.join(dir, "other")
      write_settings(Path.join(other, ".config"), "/lab/b.json")
      assert Lab.record_path(%{"HOME" => other}) == nil

      assert Lab.record_path(%{"HOME" => other, "XDG_CONFIG_HOME" => Path.join(other, ".config")}) ==
               nil

      assert Lab.record_path(%{}) == nil
      assert Lab.record_path(%{"HOME" => "relative"}) == nil
    end

    test "L9: a settings path that is not a regular file gives nil, and a FIFO never blocks" do
      state = Path.join(tmp(), "state")
      File.mkdir_p!(Path.join(state, "super"))
      settings = Path.join(state, "super/lab.json")
      env = %{"XDG_STATE_HOME" => state}

      # A FIFO with no writer: opening it for reading would wait for one.
      assert {_, 0} = System.cmd("mkfifo", [settings])
      assert File.stat!(settings).type == :other

      # Asked in a separate BEAM under an outside deadline: an open blocked on a
      # FIFO can hang the BEAM that made it, so no timeout inside this one can
      # be trusted to return. `timeout` ends the other BEAM after 5 s (killed
      # 2 s later), and any status but 0 fails the law.
      code = "IO.inspect(Ampd.Lab.record_path(#{inspect(env)}))"
      ebin = Path.dirname(to_string(:code.which(Ampd.Lab)))
      {out, status} = System.cmd("timeout", ["-k", "2", "5", "elixir", "-pa", ebin, "-e", code])
      assert status == 0, out
      assert String.trim(out) == "nil"

      File.rm!(settings)
      File.mkdir_p!(settings)
      assert Lab.record_path(env) == nil
    end
  end

  test "the lab's record of 10-16 is configured, whole and unchanged" do
    v = view(doc())
    assert v["schema"] == "lab-view@1"
    assert v["status"] == "configured"
    assert v["record"] == doc()
    assert v |> Map.keys() |> Enum.sort() == ~w(confirmation record schema status)

    assert v["confirmation"] == %{
             "finished_at" => "2026-10-16T19:56:24-05:00",
             "valid_for_hours" => 26,
             "expires_at" => "2026-10-18T02:56:24Z",
             "expired" => false
           }
  end

  test "one schema: another schema is unknown, a non-object is malformed" do
    for s <- ["lab-status/2", "lab-status", "Lab-status/1", nil, 1] do
      assert view(Map.put(doc(), "schema", s)) == unavailable("unknown-schema")
    end

    assert view(Map.delete(doc(), "schema")) == unavailable("unknown-schema")

    for bytes <- ["", "{", "[]", "null", "\"lab-status/1\"", "{\"schema\":\"lab-status/1\"}"] do
      assert Lab.decode(bytes, now()) == unavailable("malformed")
    end
  end

  test "a collection the lab could not read is accepted as unavailable, with nothing of its own" do
    gone = %{"state" => "unavailable", "observed_at" => nil, "why" => "locuchest did not answer"}

    for key <- ~w(verdict copies pools space jobs watches sign_in also_checked asks) do
      v = view(Map.put(doc(), key, gone |> Map.put("extra", 1) |> Map.put("items", [])))
      assert configured?(v), key
      assert v["record"][key] == gone
    end
  end

  test "L5: an unread collection keeps state, observed_at and why; a measured disk drops a state" do
    gone = %{"state" => "unavailable", "observed_at" => nil, "why" => "not read"}
    v = view(set(doc(), ["pools"], Map.put(gone, "items", [%{"name" => "x"}])))
    assert configured?(v)
    assert v["record"]["pools"] == gone

    measured = hd(doc()["space"]["items"])
    v = view(set(doc(), ["space", "items", 0], Map.put(measured, "state", "available")))
    assert configured?(v)
    assert hd(v["record"]["space"]["items"]) == measured

    # Any state but "unavailable" takes the measured form, so it needs a measurement.
    unread = %{"id" => "x", "machine" => "px13", "plain" => "p", "state" => "gone"}
    assert view(set(doc(), ["space", "items", 0], unread)) == unavailable("malformed")
  end

  test "whole or nothing: one defect anywhere makes the whole view malformed" do
    d = doc()
    finding = hd(d["verdict"]["items"])

    defects = [
      {"a missing collection", drop(d, ["verdict"])},
      {"another missing collection", drop(d, ["sign_in"])},
      {"a missing top field", drop(d, ["run_id"])},
      {"a collection neither available nor unavailable", set(d, ["verdict", "state"], "partial")},
      {"a place with expected absent", drop(d, ["copies", "items", 0, "places", 0, "expected"])},
      {"a place with expected not a bool",
       set(d, ["copies", "items", 0, "places", 0, "expected"], "yes")},
      {"how", set(d, ["how"], "cron")},
      {"verdict overall", set(d, ["verdict", "overall"], "unavailable")},
      {"verdict item level", set(d, ["verdict", "items", 0, "level"], "ok")},
      {"checked result",
       set(d, ["copies", "items", 0, "places", 0, "checked", "result"], "equal")},
      {"place level", set(d, ["copies", "items", 0, "places", 0, "level"], "fine")},
      {"age_from", set(d, ["copies", "items", 1, "places", 0, "age_from"], "guessed")},
      {"job timer", set(d, ["jobs", "items", 0, "timer"], "on")},
      {"run result", set(d, ["jobs", "items", 0, "runs", 0, "result"], "ok-ish")},
      {"run trigger", set(d, ["jobs", "items", 0, "runs", 0, "trigger"], "cron")},
      {"jobs trigger_basis", set(d, ["jobs", "trigger_basis"], "guessed")},
      {"runs_policy", set(d, ["jobs", "runs_policy"], "all")},
      {"reading result", set(d, ["watches", "items", 0, "readings", 0, "result"], "fine")},
      {"sign-in renewal", set(d, ["sign_in", "renewal"], "maybe")},
      {"closed ask state", set(d, ["asks", "recently_closed", 0, "state"], "open")},
      {"a time without a zone", set(d, ["started_at"], "2026-10-16T19:52:33")},
      {"a nested time without a zone",
       set(d, ["copies", "items", 0, "places", 0, "newest_at"], "2026-10-16T03:10:16")},
      {"a future-kind time that is no time", set(d, ["sign_in", "expires_at"], "tomorrow")},
      {"a negative byte count", set(d, ["space", "items", 0, "free_bytes"], -1)},
      {"a how that is not a check method",
       set(d, ["copies", "items", 0, "places", 0, "checked", "how"], "sha256sum")},
      {"waiting on a closed ask", set(d, ["asks", "waiting_on_you"], ["gitleaks"])},
      {"waiting twice",
       set(d, ["asks", "waiting_on_you"], ["daily-check-timer", "daily-check-timer"])},
      {"a duplicate verdict id", set(d, ["verdict", "items"], [finding, finding])},
      {"a duplicate place id", set(d, ["copies", "items", 0, "places", 1, "id"], "locuchest")},
      {"a duplicate pool name", set(d, ["pools", "items", 1, "name"], "backup4t")},
      {"uppercase hex", set(d, ["script_sha256"], String.upcase(d["script_sha256"]))},
      {"an exit code over 255", set(d, ["jobs", "items", 0, "runs", 0, "exit_code"], 256)},
      {"an also-checked result", set(d, ["also_checked", "items", 1, "result"], "failed (exit one)")},
      {"an unread job with runs", set(d, ["jobs", "items", 1, "runs"], [])},
      {"a read job marked unread", set(d, ["jobs", "items", 0, "runs_state"], "unavailable")},
      {"a count of an unknown result", set(d, ["jobs", "items", 0, "run_counts", "lost"], 1)},
      {"a date that is not a day", set(d, ["watches", "items", 0, "started_on"], "2026-02-30")},
      {"valid_for_hours zero", set(d, ["valid_for_hours"], 0)},
      {"valid_for_hours a word", set(d, ["valid_for_hours"], "26")},
      {"an unknown trim", set(d, ["trimmed"], ["everything"])},
      {"drives neither a list nor unavailable", set(d, ["pools", "items", 1, "drives"], "none")},
      {"a copy with no places", set(d, ["copies", "items", 0, "places"], [])},
      {"verdict counts half", set(d, ["verdict", "counts"], %{"failed" => 0})},
      {"a watch day not an integer", set(d, ["watches", "items", 0, "day"], 7.0)}
    ]

    assert length(defects) >= 20

    for {label, bad} <- defects do
      assert view(bad) == unavailable("malformed"), label
    end
  end

  test "ids, text and control characters are bounded in bytes" do
    d = doc()

    for {path, ok, bad} <- [
          {["run_id"], String.duplicate("i", 120), String.duplicate("i", 121)},
          {["machine"], String.duplicate("é", 60), String.duplicate("é", 61)},
          {["verdict", "line"], String.duplicate("t", 500), String.duplicate("t", 501)},
          {["verdict", "items", 0, "plain"], "S3 compared 0 files", "S3 compared\n0 files"},
          {["asks", "items", 0, "record"], "e77e2b28", "e77e2b28" <> <<127>>},
          {["copies", "items", 0, "places", 0, "checked", "detail"], "", "55\tof 55"}
        ] do
      assert configured?(view(set(d, path, ok))), inspect(path)
      assert view(set(d, path, bad)) == unavailable("malformed"), inspect(path)
    end
  end

  defp caps do
    at = "2026-10-11T08:35:00-05:00"

    [
      {["rules_note"], 16, fn i -> "note #{i}" end},
      {["trimmed"], 8, fn _ -> "notes-40" end},
      {["verdict", "items"], 64,
       fn i -> %{"id" => "f-#{i}", "level" => "warning", "plain" => "p"} end},
      {["copies", "items"], 32,
       fn i ->
         %{
           "id" => "c-#{i}",
           "plain" => "p",
           "lives_on" => "x",
           "places" => [%{"id" => "mac", "plain" => "the Mac", "expected" => false}]
         }
       end},
      {["copies", "items", 0, "places"], 8,
       fn i -> %{"id" => "p-#{i}", "plain" => "p", "expected" => false} end},
      {["pools", "items"], 8,
       fn i ->
         %{
           "name" => "pool-#{i}",
           "plain_name" => "p",
           "machine" => "locuchest",
           "health" => "ONLINE",
           "last_scrub" => "unavailable",
           "drives" => "unavailable",
           "observed_at" => at
         }
       end},
      {["pools", "items", 0, "drives"], 16, fn i -> %{"id" => "d-#{i}"} end},
      {["space", "items"], 16,
       fn i ->
         %{"id" => "s-#{i}", "machine" => "px13", "plain" => "p", "state" => "unavailable"}
       end},
      {["jobs", "items"], 32,
       fn i ->
         %{
           "id" => "j-#{i}",
           "plain" => "p",
           "machine" => "px13",
           "schedule" => "s",
           "timer" => "unavailable",
           "run_counts" => nil,
           "runs" => nil,
           "runs_state" => "unavailable",
           "why" => "w"
         }
       end},
      {["jobs", "items", 0, "runs"], 16,
       fn _ ->
         %{
           "start_at" => nil,
           "end_at" => nil,
           "result" => "ok",
           "exit_code" => 0,
           "trigger" => "scheduled"
         }
       end},
      {["jobs", "items", 0, "runs", 0, "retries"], 3, fn i -> "retry #{i}" end},
      {["watches", "items"], 8,
       fn i ->
         %{
           "id" => "w-#{i}",
           "plain" => "p",
           "machine" => "locuchest",
           "started_on" => "2026-10-10",
           "length_days" => 14,
           "day" => 7,
           "ended" => false,
           "readings" => [],
           "level" => "ok",
           "rule" => "r"
         }
       end},
      {["watches", "items", 0, "readings"], 32,
       fn i -> %{"id" => "r-#{i}", "plain" => "p", "result" => "ok", "detail" => "d"} end},
      {["also_checked", "items"], 16,
       fn i -> %{"id" => "x-#{i}", "plain" => "p", "result" => "ok"} end},
      {["asks", "items"], 64,
       fn i ->
         %{
           "id" => if(i == 1, do: "daily-check-timer", else: "a-#{i}"),
           "plain" => "p",
           "line" => nil,
           "changed_at" => at,
           "addressed_to" => "travis",
           "since" => "2026-10-11",
           "record" => "r"
         }
       end},
      {["asks", "recently_closed"], 64,
       fn i -> %{"id" => "c-#{i}", "state" => "answered", "changed_at" => at, "record" => "r"} end}
    ]
  end

  test "every list holds at most its cap: the cap is accepted, one more is not" do
    d = doc()

    for {path, cap, make} <- caps() do
      assert configured?(view(set(d, path, Enum.map(1..cap, make)))), inspect(path)

      assert view(set(d, path, Enum.map(1..(cap + 1), make))) == unavailable("malformed"),
             inspect(path)
    end

    methods = fn n ->
      Map.merge(d["copies"]["check_methods"], Map.new(1..n, &{"m-#{&1}", "a method"}))
    end

    assert configured?(view(set(d, ["copies", "check_methods"], methods.(30))))
    assert view(set(d, ["copies", "check_methods"], methods.(31))) == unavailable("malformed")
  end

  test "the record file is at most 32,768 bytes" do
    path = Path.join(tmp(), "lab-status.json")
    bytes = JSON.encode!(doc())
    File.write!(path, pad(bytes, 32_768))
    assert Lab.read(path, now()) == view(doc())
    File.write!(path, pad(bytes, 32_769))
    assert Lab.read(path, now()) == unavailable("too-large")
  end

  test "the configured view is at most 33,792 bytes, as JSON encodes it" do
    base = doc() |> set(["verdict", "line"], "") |> set(["verdict", "rules", "laws"], "")
    conf = view(base)["confirmation"]

    size = fn d ->
      byte_size(
        JSON.encode!(%{
          "schema" => "lab-view@1",
          "status" => "configured",
          "record" => d,
          "confirmation" => conf
        })
      )
    end

    item = fn i ->
      %{"id" => "f-#{100 + i}", "level" => "warning", "plain" => String.duplicate("w", 480)}
    end

    filled =
      Enum.reduce_while(1..64, set(base, ["verdict", "items"], []), fn i, d ->
        next = update_in(d, ["verdict", "items"], &(&1 ++ [item.(i)]))
        if size.(next) <= 33_792, do: {:cont, next}, else: {:halt, d}
      end)

    gap = 33_792 - size.(filled)
    assert gap >= 0 and gap < 600
    half = div(gap, 2)

    exact =
      filled
      |> set(["verdict", "line"], String.duplicate("l", half))
      |> set(["verdict", "rules", "laws"], String.duplicate("l", gap - half))

    assert size.(exact) == 33_792
    v = view(exact)
    assert configured?(v)
    assert byte_size(JSON.encode!(v)) == 33_792

    assert view(set(exact, ["verdict", "line"], String.duplicate("l", half + 1))) ==
             unavailable("too-large")
  end

  test "a time may be at most 5 s ahead; the times meant for the future are not held to it" do
    d = doc()
    assert configured?(view(set(d, ["finished_at"], iso(now() + 4_000))))
    assert view(set(d, ["finished_at"], iso(now() + 6_000))) == unavailable("future")
    assert view(set(d, ["verdict", "observed_at"], iso(now() + 6_000))) == unavailable("future")

    assert view(set(d, ["jobs", "items", 0, "runs", 1, "end_at"], iso(now() + 6_000))) ==
             unavailable("future")

    day = iso(now() + 86_400_000)

    for path <- [
          ["jobs", "items", 0, "next_at"],
          ["sign_in", "expires_at"],
          ["sign_in", "long_term_ends_at"]
        ] do
      assert configured?(view(set(d, path, day))), inspect(path)
    end

    # A broken rule is named before a time ahead of the clock.
    bad = d |> set(["finished_at"], iso(now() + 6_000)) |> set(["how"], "cron")
    assert view(bad) == unavailable("malformed")
  end

  test "L4: the five-second rule is measured in microseconds" do
    d = doc()
    edge = now() * 1_000 + 5_000_000
    assert configured?(view(set(d, ["finished_at"], iso_us(edge))))
    assert view(set(d, ["finished_at"], iso_us(edge + 1))) == unavailable("future")

    assert view(set(d, ["verdict", "observed_at"], iso_us(edge + 1))) ==
             unavailable("future")
  end

  test "L4: a future refusal is read again every tick, and accepted on the first tick the clock allows" do
    path = Path.join(tmp(), "lab-status.json")
    File.write!(path, JSON.encode!(doc()))
    # A wall clock at which the stamp is trusted, so only the refusal re-reads.
    wall = settled(path)
    t = now()

    assert {:read, s} = Lab.tick(fresh(path), t - 10_000, wall)
    assert s.view == unavailable("future")
    refute s.racy

    s =
      Enum.reduce([t - 9_000, t - 8_000, t - 5_001], s, fn clock, prev ->
        assert {:read, next} = Lab.tick(prev, clock, wall)
        assert next.view == unavailable("future")
        next
      end)

    assert {:read, s} = Lab.tick(s, t - 5_000, wall)
    assert configured?(s.view)
    assert {:reage, s2} = Lab.tick(s, t - 4_000, wall)
    assert s2.view == s.view
    assert {:reage, _} = Lab.tick(s2, t, wall)
  end

  test "L4: a change of type, size, either time, inode or device forces a re-read; nothing else does" do
    base = %{type: :regular, size: 10, mtime: 100, ctime: 100, inode: 7, device: 3}
    ok = view(doc())
    refute Lab.reread?(base, base, ok, false)
    refute Lab.reread?(base, base, unavailable("malformed"), false)
    assert Lab.reread?(base, base, unavailable("future"), false)
    assert Lab.reread?(base, base, ok, true)
    assert Lab.reread?(:none, base, nil, false)

    for {key, value} <- [
          type: :directory,
          size: 11,
          mtime: 101,
          ctime: 101,
          inode: 8,
          device: 4
        ] do
      assert Lab.reread?(base, Map.put(base, key, value), ok, false), inspect(key)
    end

    path = Path.join(tmp(), "lab-status.json")
    File.write!(path, JSON.encode!(doc()))
    st = File.stat!(path, time: :posix)

    assert Lab.stamp(path) == %{
             type: :regular,
             size: st.size,
             mtime: st.mtime,
             ctime: st.ctime,
             inode: st.inode,
             device: st.major_device
           }

    assert {:error, :enoent} = Lab.stamp(Path.join(Path.dirname(path), "absent.json"))
    refute Lab.racy?({:error, :enoent}, 0)

    assert {:read, s} = Lab.tick(fresh(path), now(), settled(path))
    assert {:reage, s} = Lab.tick(s, now(), settled(path))
    File.write!(path, "{\"schema\":\"lab-status/2\"}")
    assert {:read, s} = Lab.tick(s, now(), settled(path))
    assert s.view == unavailable("unknown-schema")
  end

  test "L12: a stamp too close to its reading is not trusted, so a same-second rewrite is seen" do
    path = Path.join(tmp(), "lab-status.json")
    one = JSON.encode!(doc())
    two = String.replace(one, ~s("lab-status/1"), ~s("lab-status/2"))
    assert byte_size(two) == byte_size(one) and two != one

    File.write!(path, one)
    assert {:read, s} = Lab.tick(fresh(path), now(), settled(path) - 1_500)
    assert configured?(s.view)
    assert s.racy
    assert Lab.racy?(s.stamp, settled(path) - 1)
    refute Lab.racy?(s.stamp, settled(path))

    # Rewritten in place, same size. Within the second of the last reading the
    # stamp's whole-second fields would all be unchanged, so the reader is
    # given exactly that stamp: nothing but the racy flag can send it back.
    File.write!(path, two)
    s = %{s | stamp: Lab.stamp(path)}
    assert {:read, s} = Lab.tick(s, now(), settled(path) - 1_000)
    assert s.view == unavailable("unknown-schema")
    assert s.racy

    # Re-read while racy; the first reading that finds both times settled
    # trusts the stamp, and unchanged ticks after it only re-age.
    assert {:read, s} = Lab.tick(s, now(), settled(path))
    refute s.racy
    assert s.view == unavailable("unknown-schema")
    assert {:reage, s} = Lab.tick(s, now(), settled(path) + 1_000)
    assert {:reage, s} = Lab.tick(s, now(), settled(path) + 5_000)
    assert s.view == unavailable("unknown-schema")
  end

  test "the first view is announced exactly once after start, and a changed view once more" do
    path = Path.join(tmp(), "lab-status.json")
    File.write!(path, JSON.encode!(doc()))
    pid = start_supervised!({Lab, name: nil, path: path, notify: self(), tick_ms: 20})
    assert_receive {Lab, :touched}, 1_000
    # The fresh file's stamp is racy, so these ticks re-read; the view is the
    # same, so they announce nothing.
    refute_receive {Lab, :touched}, 200
    assert %{"status" => "configured"} = :sys.get_state(pid).view

    File.write!(path, "{\"schema\":\"lab-status/2\"}")
    assert_receive {Lab, :touched}, 1_000
    refute_receive {Lab, :touched}, 200
    assert :sys.get_state(pid).view == unavailable("unknown-schema")
  end

  test "an unconfigured reader announces its first view once too" do
    pid = start_supervised!({Lab, name: nil, path: nil, notify: self()})
    assert_receive {Lab, :touched}, 1_000
    refute_receive {Lab, :touched}, 100
    assert :sys.get_state(pid).view == %{"schema" => "lab-view@1", "status" => "unconfigured"}
  end

  test "expiry is finished_at plus valid_for_hours, re-aged with no new reading" do
    v = view(doc())
    expires = ms("2026-10-18T02:56:24Z")
    assert Lab.reage(v, expires)["confirmation"]["expired"] == false
    later = Lab.reage(v, expires + 1)
    assert later["confirmation"]["expired"] == true
    assert Map.delete(later, "confirmation") == Map.delete(v, "confirmation")
    assert view_at(doc(), expires + 1)["confirmation"]["expired"] == true

    assert view(set(doc(), ["valid_for_hours"], 1.5))["confirmation"]["expires_at"] ==
             "2026-10-17T02:26:24Z"

    none = view(Map.delete(doc(), "valid_for_hours"))

    assert none["confirmation"] == %{
             "finished_at" => "2026-10-16T19:56:24-05:00",
             "valid_for_hours" => nil,
             "expires_at" => nil,
             "expired" => false
           }

    assert Lab.reage(none, expires * 2)["confirmation"]["expired"] == false
    assert Lab.reage(unavailable("missing"), expires) == unavailable("missing")
    assert Lab.reage(%{"schema" => "lab-view@1", "status" => "unconfigured"}, 0)["status"] ==
             "unconfigured"
  end

  # The bound law, over any module with `decode/2`.
  defp bound_law?(mod) do
    d = doc()
    year = mod.decode(JSON.encode!(set(d, ["valid_for_hours"], 8_760)), now())

    over =
      for h <- [8_761, 1.0e308],
          do: mod.decode(JSON.encode!(set(d, ["valid_for_hours"], h)), now())

    year["status"] == "configured" and Enum.all?(over, &(&1 == unavailable("out-of-range")))
  end

  test "bound: valid_for_hours is at most a year; above it is out-of-range, after malformed and before future" do
    d = doc()
    year = view(set(d, ["valid_for_hours"], 8_760))
    assert configured?(year)
    assert year["confirmation"]["expires_at"] == "2027-10-17T00:56:24Z"

    for h <- [8_761, 8_760.5, 1.0e308] do
      assert view(set(d, ["valid_for_hours"], h)) == unavailable("out-of-range"), inspect(h)
    end

    future = d |> set(["valid_for_hours"], 8_761) |> set(["finished_at"], iso(now() + 6_000))
    assert view(future) == unavailable("out-of-range")

    broken = d |> set(["valid_for_hours"], 1.0e308) |> set(["how"], "cron")
    assert view(broken) == unavailable("malformed")

    assert bound_law?(Lab)
  end

  test "plant P12: with the upper bound removed, the bound law fails" do
    source = File.read!(Path.expand("../lib/ampd/lab.ex", __DIR__))
    line = ~s|defp in_range?(rec), do: Map.get(rec, "valid_for_hours", 0) <= @max_valid_hours|
    assert length(String.split(source, line)) == 2

    planted =
      source
      |> String.replace(line, "defp in_range?(_rec), do: @max_valid_hours > 0")
      |> String.replace("defmodule Ampd.Lab do", "defmodule Ampd.LabPlantP12 do")

    {mod, _bin} = planted |> Code.compile_string() |> List.keyfind(Ampd.LabPlantP12, 0)

    on_exit(fn ->
      :code.purge(mod)
      :code.delete(mod)
    end)

    assert bound_law?(Lab)
    refute bound_law?(mod)
  end

  test "declared fields only: unknown keys at every level change nothing" do
    assert view(salt(doc())) == view(doc())
    refute JSON.encode!(view(salt(doc()))) =~ "x_unknown"
  end

  test "the lab's lists pass through: runs, counts and omissions as recorded, in order" do
    v = view(doc())
    [gitec, mac, daily] = v["record"]["jobs"]["items"]
    [src_gitec, src_mac, src_daily] = doc()["jobs"]["items"]
    assert gitec["runs"] == src_gitec["runs"]
    assert Enum.map(gitec["runs"], & &1["result"]) == ["failed", "ok"]
    assert gitec["run_counts"] == %{"ok" => 11, "failed" => 1}
    assert gitec["runs_omitted"] == %{"ok" => 10}
    assert mac == src_mac
    assert mac["why"] == "not read from the PX13 (the Mac is not reached by the check)"
    assert daily["runs"] == src_daily["runs"]

    runs =
      for {r, h} <- [{"failed", "09"}, {"ok", "10"}, {"ok", "11"}] do
        %{
          "start_at" => "2026-10-16T#{h}:10:00-05:00",
          "end_at" => nil,
          "result" => r,
          "exit_code" => nil,
          "trigger" => "scheduled"
        }
      end

    job =
      Map.merge(src_gitec, %{
        "run_counts" => %{"ok" => 11, "failed" => 1},
        "runs" => runs,
        "runs_omitted" => %{"ok" => 9}
      })

    out = hd(view(set(doc(), ["jobs", "items", 0], job))["record"]["jobs"]["items"])
    assert out["runs"] == runs
    assert out["run_counts"] == %{"ok" => 11, "failed" => 1}
    assert out["runs_omitted"] == %{"ok" => 9}
  end

  test "read/2 names why, and leaves the folder and the record as they were" do
    dir = tmp()
    path = Path.join(dir, "lab-status.json")
    assert Lab.read(path, now()) == unavailable("missing")
    assert Lab.read(dir, now()) == unavailable("unreadable")
    File.write!(path, "")
    assert Lab.read(path, now()) == unavailable("malformed")
    assert Lab.read(Path.join(path, "inner.json"), now()) == unavailable("missing")
    File.write!(path, "{\"schema\":\"lab-status/2\"}")
    assert Lab.read(path, now()) == unavailable("unknown-schema")
    File.write!(path, JSON.encode!(doc()))

    seen = fn ->
      {File.ls!(dir), File.read!(path),
       Map.take(File.stat!(path, time: :posix), [:size, :mtime, :ctime, :inode, :mode])}
    end

    before = seen.()
    for _ <- 1..3, do: assert(Lab.read(path, now()) == view(doc()))
    assert seen.() == before
  end

  test "the reader's source holds no write, process or network call and no bare call" do
    source = File.read!(Path.expand("../lib/ampd/lab.ex", __DIR__))

    for word <- [
          "File.write",
          "File.rename",
          "File.rm",
          "File.mkdir",
          "File.cp",
          "File.touch",
          "File.ln",
          ":gen_tcp",
          ":gen_udp",
          ":httpc",
          ":ssh",
          "System.cmd",
          ":os.cmd",
          "Port."
        ] do
      refute String.contains?(source, word), word
    end

    refute String.contains?(source, "GenServer" <> ".call(")
    assert String.contains?(source, "@participant_mutations ~w()a")
  end

  test "the running reader answers through the ordered boundary, quietly" do
    assert Lab.class(:projection) == :read
    before = Ampd.RefusalLog.recent()
    for _ <- 1..20, do: assert(%{"schema" => "lab-view@1"} = Lab.projection())
    assert Ampd.RefusalLog.recent() == before
  end
end
