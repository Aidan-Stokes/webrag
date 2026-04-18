import Config

import_config "sources.exs"

config :webrag,
  ecto_repos: [WebRAG.Repo],
  generators: [timestamp_type: :utc_datetime]

config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :webrag,
  max_concurrent: System.schedulers_online()

config :webrag, WebRAG.Crawler,
  rate_limit: 50,
  burst_size: 25,
  request_timeout: 30_000,
  user_agent: "WebRAG/1.0"

config :webrag, :crawler_rate_limit, 5
config :webrag, :crawler_burst_size, 3

config :webrag, WebRAG.Indexer,
  embedding_model: "mxbai-embed-large",
  embedding_dimensions: 768,
  batch_size: 100,
  max_concurrent_batches: System.schedulers_online()

config :webrag, WebRAG.LLM,
  model: "llama3",
  embedding_model: "mxbai-embed-large",
  temperature: 0.3,
  max_tokens: 1500

config :webrag, WebRAG.API.Endpoint,
  port: 4000,
  url: [host: "0.0.0.0"]

config :webrag,
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
