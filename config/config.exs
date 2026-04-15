import Config

config :aoncrawler,
  ecto_repos: [AONCrawler.Repo],
  generators: [timestamp_type: :utc_datetime]

config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :aoncrawler, AONCrawler.Crawler,
  max_concurrent: 20,
  rate_limit: 10,
  request_timeout: 30_000,
  user_agent: "AONCrawler/1.0 (Pathfinder 2e Rules RAG)"

config :aoncrawler, AONCrawler.Indexer,
  embedding_model: "text-embedding-3-small",
  embedding_dimensions: 1536,
  batch_size: 100

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
