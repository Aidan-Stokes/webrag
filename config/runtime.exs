import Config

if config_env() == :prod do
  config :aoncrawler,
    max_concurrent:
      System.get_env("MAX_CONCURRENT", "#{System.schedulers_online()}") |> String.to_integer()
end
