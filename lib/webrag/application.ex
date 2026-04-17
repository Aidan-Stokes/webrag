defmodule WebRAG.Application do
  @moduledoc """
  Main application module for WebRAG.

  This OTP application provides a complete RAG (Retrieval-Augmented Generation)
  pipeline for Pathfinder 2e rules from Archives of Nethys.

  ## Supervision Tree

  The application starts the following children under the main supervisor:

  - `WebRAG.Crawler.Supervisor` - Manages concurrent page crawling
  - `WebRAG.Indexer.VectorStore` - Handles embedding storage and retrieval
  - `WebRAG.Retriever.SearchService` - Provides semantic search capabilities
  - `WebRAG.LLM.Client` - Interfaces with LLM providers
  - `WebRAG.API.Endpoint` - Phoenix endpoint for HTTP API (if enabled)

  ## Configuration

  Configure via `config/runtime.exs` or environment variables:

  - `DATABASE_URL` - PostgreSQL connection string
  - `OPENAI_API_KEY` - OpenAI API key for embeddings
  - `CRAWLER_CONCURRENCY` - Max concurrent crawl requests (default: 5)
  - `CRAWLER_RATE_LIMIT` - Requests per second limit (default: 2)

  ## Design Decisions

  1. **Supervision Strategy**: We use `one_for_one` for most children since
     failures are isolated. The Crawler supervisor uses `one_for_all` to
     ensure crawl jobs are re-queued if the coordinator fails.

  2. **Start Order**: Database is started first (required by Indexer),
     then Indexer (required by Retriever), then services in dependency order.

  3. **Fault Tolerance**: Each GenServer implements proper error handling
     and state recovery. The crawler uses circuit breakers to prevent
     cascade failures from a misbehaving source.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting WebRAG application", application: :webrag)

    children = build_supervision_tree()

    opts = [
      strategy: :one_for_one,
      name: WebRAG.Supervisor,
      shutdown: 30_000
    ]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("WebRAG started successfully", pid: inspect(pid))
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start WebRAG", reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Builds the supervision tree based on environment configuration.

  This allows conditional inclusion of children based on runtime flags,
  useful for testing or selective feature activation.
  """
  @spec build_supervision_tree() :: [Supervisor.child()]
  def build_supervision_tree do
    base_children =
      [
        # Database is fundamental - everything else needs it
        database_child(),
        # Crawler infrastructure
        crawler_children(),
        # Indexing and retrieval
        indexer_children(),
        # LLM interface
        llm_child(),
        # API layer (optional, can be disabled)
        api_child()
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    Logger.debug("Supervision tree built", child_count: length(base_children))

    base_children
  end

  # Database child specification
  defp database_child do
    # Conditionally start Postgrex/Repo based on config
    if Application.get_env(:webrag, :start_database, true) do
      {WebRAG.Repo, []}
    end
  end

  # Crawler supervisor and worker pool
  defp crawler_children do
    if Application.get_env(:webrag, :start_crawler, true) do
      # Initialize ETS table for coordinator state persistence
      if :ets.info(:webrag_coordinator_state) == :undefined do
        :ets.new(:webrag_coordinator_state, [:set, :named_table, :public])
        Logger.info("Created ETS table for coordinator state")
      else
        # Clear stale state so fresh crawl uses new options
        :ets.delete_all_objects(:webrag_coordinator_state)
        Logger.info("Cleared stale ETS state")
      end

      max_concurrent =
        Application.get_env(:webrag, :crawler_max_concurrent, 20)

      rate_limit =
        Application.get_env(:webrag, :crawler_rate_limit, 10)

      burst_size =
        Application.get_env(:webrag, :crawler_burst_size, 25)

      [
        # Rate limiter to respect source server
        {WebRAG.Crawler.RateLimiter, rate_limit: rate_limit, burst_size: burst_size},
        # Worker pool supervisor
        {WebRAG.Crawler.WorkerSupervisor, max_concurrent: max_concurrent},
        # Main crawler coordinator
        {WebRAG.Crawler.Coordinator, [persist_state: false]}
      ]
    else
      []
    end
  end

  # Indexer children for vector storage
  defp indexer_children do
    if Application.get_env(:webrag, :start_indexer, true) do
      [
        # Vector store GenServer
        {WebRAG.Indexer.VectorStore, []},
        # Batch embedding processor
        {WebRAG.Indexer.BatchProcessor, []}
      ]
    else
      []
    end
  end

  # LLM client
  defp llm_child do
    if Application.get_env(:webrag, :start_llm, true) do
      {WebRAG.LLM.Client, []}
    end
  end

  # API endpoint
  defp api_child do
    if Application.get_env(:webrag, :start_api, true) do
      # Phoenix endpoint with cowboy adapter
      WebRAG.API.Endpoint
    end
  end

  @doc """
  Callback for application configuration changes.
  """
  @impl Application
  def config_change(changed, _new, removed) do
    Logger.info("Application config changed",
      changed: Map.keys(changed),
      removed: removed
    )

    # Notify relevant processes of config changes
    Enum.each(changed, fn {app, changes} ->
      Enum.each(changes, fn {key, value} ->
        :ets.insert({:app_config, app}, {key, value})
      end)
    end)

    :ok
  end

  @doc """
  Returns the supervisor specification for this application.
  Useful for umbrella projects or hot upgrades.
  """
  @spec supervisor_spec() :: Supervisor.Supervisor.child_spec()
  def supervisor_spec do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start, [[]]},
      type: :supervisor
    }
  end
end
