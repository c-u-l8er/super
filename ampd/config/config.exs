import Config

if config_env() == :test do
  # **Per run, because this box runs many sessions over one checkout.**
  #
  # This was the fixed path `/tmp/ampd-test-data`, and two suites running at
  # once shared it. The symptom is not a clean collision — it is
  #
  #     (File.Error) could not remove files and directories recursively
  #     from "/tmp/ampd-test-data": file already exists
  #
  # raised inside `Bootstrap.do_reset_world!/0` under the authority
  # coordinator, plus timeouts, in tests that have nothing to do with each
  # other and all pass in isolation. Measured: 11 failures across four files
  # against the shared path, **0 failures against a private one, same
  # commit, same seed**. It cost this session a wrong diagnosis first — the
  # spread looked exactly like a regression in the change under test.
  #
  # The directory is `rm_rf`'d and recreated here on every run, so it is
  # pure per-run scratch and there is no version of sharing it that is
  # correct. `AMPD_TEST_DATA_DIR` overrides it for a caller that wants a
  # known location; otherwise the OS pid makes concurrent runs disjoint, and
  # a run that crashed without cleaning up is cleaned by the next run that
  # draws its pid.
  dir = System.get_env("AMPD_TEST_DATA_DIR") || "/tmp/ampd-test-data-#{System.pid()}"
  File.rm_rf!(dir)
  File.mkdir_p!(dir)
  config :ampd, data_dir: dir

  # **The reference effector, selected explicitly, for the tests written
  # against it.** The compiled default is now the possession-addressed
  # channel (see `Ampd.Worktree.Effector.current/0`), and a test run has no
  # host serving one — so D.1.1's and D.1.2's falsifiers would all fail for
  # a reason that has nothing to do with what they falsify.
  #
  # This is an explicit reference/parity selection, not a fallback. The
  # distinction is the whole of D.1.3a's item E: production must have no
  # configuration in which a missing channel becomes a pathname exec, and
  # `test/effect_channel_test.exs` asserts the *unconfigured* default is
  # the channel precisely so that this line cannot quietly become the rule.
  config :ampd, worktree_effector: Ampd.Worktree.Effector.Host

  # **The suite's restart intensity, not production's** (T73). The suite
  # kills supervised children on purpose (67 sites, and four files that
  # reboot all four registries at once), and under production's 100 restarts
  # in 5 s those kills alone spent the budget: a collapse recorded with
  # supervisor reports held 101 restarts in 1.8 s, and `Ampd.Supervisor`
  # took the application, and every test after it, down with it. Production
  # sets nothing and keeps `{100, 5}` (`Ampd.Application.supervisor_options/0`),
  # pinned by `test/supervision_budget_test.exs`. A test about recovery must
  # assert bounded restarts and a serving registry itself; the application
  # surviving no longer proves either.
  config :ampd, restart_intensity: {1_000, 5}
else
  config :ampd, data_dir: "priv/data"
end
