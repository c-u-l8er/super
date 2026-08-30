import Config

if config_env() == :test do
  dir = "/tmp/ampd-test-data"
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
else
  config :ampd, data_dir: "priv/data"
end
