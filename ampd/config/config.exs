import Config

if config_env() == :test do
  dir = "/tmp/ampd-test-data"
  File.rm_rf!(dir)
  File.mkdir_p!(dir)
  config :ampd, data_dir: dir
else
  config :ampd, data_dir: "priv/data"
end
