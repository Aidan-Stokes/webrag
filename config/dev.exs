import Config

config :aoncrawler, AONCrawler.Repo,
  database: Path.expand("../aoncrawler.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :aoncrawler,
  ollama_url: "http://localhost:11434",
  embedding_model: "mxbai-embed-large",
  chat_model: "llama3",
  embedding_dimensions: 768

config :logger, :console, level: :debug

config :aoncrawler, AONCrawler.Crawler,
  max_concurrent: 3,
  rate_limit: 5,
  request_timeout: 30_000,
  user_agent: "AONCrawler/1.0 (Pathfinder 2e Rules RAG)"

config :aoncrawler, AONCrawler.Indexer,
  embedding_model: "mxbai-embed-large",
  embedding_dimensions: 768,
  batch_size: 50

config :aoncrawler, AONCrawler.LLM,
  model: "llama3",
  temperature: 0.3,
  max_tokens: 1500

config :aoncrawler, AONCrawler.API.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  debug_errors: true,
  code_reloader: true,
  check_origin: false

config :aoncrawler,
  start_database: true,
  start_crawler: false,
  start_indexer: true,
  start_llm: true,
  start_api: false
