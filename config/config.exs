import Config

import_config "sources.exs"

config :aoncrawler,
  ecto_repos: [AONCrawler.Repo],
  generators: [timestamp_type: :utc_datetime]

config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :aoncrawler,
  max_concurrent: System.schedulers_online()

config :aoncrawler, AONCrawler.Crawler,
  rate_limit: 50,
  burst_size: 25,
  request_timeout: 30_000,
  user_agent: "AONCrawler/1.0"

config :aoncrawler, :crawler_rate_limit, 5
config :aoncrawler, :crawler_burst_size, 3

config :aoncrawler, AONCrawler.Indexer,
  embedding_model: "text-embedding-3-small",
  embedding_dimensions: 1536,
  batch_size: 100,
  max_concurrent_batches: System.schedulers_online()

config :aoncrawler, AONCrawler.LLM,
  model: "gpt-4-turbo",
  temperature: 0.3,
  max_tokens: 1500

config :aoncrawler, AONCrawler.API.Endpoint,
  port: 4000,
  url: [host: "0.0.0.0"]

config :aoncrawler,
  start_database: false,
  start_crawler: true,
  start_indexer: true,
  start_llm: true,
  start_api: false

if config_env() == :dev do
  config :logger, :console, level: :debug
end

if config_env() == :test do
  config :logger, level: :warning
end
