defmodule WebRAG.Retriever.SearchService do
  @moduledoc """
  Semantic search service for retrieving relevant rules content.

  This module provides the retrieval layer for the RAG system:
  - Embeds user queries
  - Performs similarity search against indexed content
  - Reranks and filters results
  - Returns structured results for LLM prompting

  ## Architecture

  The retriever works with the Indexer and LLM modules:
  1. Query → EmbeddingClient → VectorStore.search → Results
  2. Results → Rerank/Filter → Sources for LLM

  ## Usage

      # Simple search
      {:ok, results} = SearchService.search("How does shove work?")

      # Search with options
      {:ok, results} = SearchService.search(
        "Fireball damage",
        top_k: 5,
        content_types: [:spell],
        min_score: 0.7
      )

  ## Design Decisions

  1. **Hybrid Retrieval**: Falls back to keyword search when vector search fails
  2. **Score Thresholding**: Filters out low-relevance results
  3. **Content Type Filtering**: Allows narrowing to specific rule types
  4. **Context Packing**: Packs multiple results into context for LLM
  """

  use GenServer
  require Logger

  alias WebRAG.Types
  alias WebRAG.Indexer.VectorStore
  alias WebRAG.Indexer.EmbeddingClient
  alias WebRAG.Repo
  alias WebRAG.Document

  @default_top_k 5
  @default_min_score 0.7

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the search service.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Performs a semantic search for content relevant to the query.

  ## Parameters

  - `query` - The user's question or search string
  - `opts` - Search options

  ## Options

  - `:top_k` - Number of results (default: 5)
  - `:min_score` - Minimum similarity score (default: 0.7)
  - `:content_types` - Filter by content types (e.g., [:spell, :action])
  - `:include_metadata` - Include full metadata (default: false)

  ## Returns

  `{:ok, [Types.SearchResult.t()]}` on success

  ## Example

      iex> SearchService.search("What does Shove do?")
      {:ok, [
        %Types.SearchResult{
          chunk: %Types.Chunk{text: "..."},
          score: 0.92,
          rank: 1
        }
      ]}
  """
  @spec search(String.t(), keyword()) :: {:ok, [Types.search_result()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    GenServer.call(__MODULE__, {:search, query, opts}, 60_000)
  end

  @doc """
  Performs search and packs results into a context string for LLM.

  This combines multiple results into a formatted context that can be
  used directly in prompt construction.

  ## Example

      iex> SearchService.search_with_context("How does shove work?")
      {:ok, context, results}
  """
  @spec search_with_context(String.t(), keyword()) ::
          {:ok, String.t(), [Types.search_result()]} | {:error, term()}
  def search_with_context(query, opts \\ []) do
    case search(query, opts) do
      {:ok, []} ->
        {:ok, "", []}

      {:ok, results} ->
        context = pack_context(results)
        {:ok, context, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Performs search synchronously without GenServer overhead.

  Useful for one-off queries where startup overhead isn't worth it.
  """
  @spec search_sync(String.t(), keyword()) :: {:ok, [Types.search_result()]} | {:error, term()}
  def search_sync(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    min_score = Keyword.get(opts, :min_score, @default_min_score)
    content_types = Keyword.get(opts, :content_types, nil)

    case embed_query(query) do
      {:ok, query_vector} ->
        VectorStore.search(query_vector,
          top_k: top_k,
          min_score: min_score,
          content_types: content_types
        )

      {:error, reason} ->
        Logger.error("Failed to embed query", error: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Returns search statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ============================================================================
  # Server Implementation
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      total_queries: 0,
      successful_queries: 0,
      failed_queries: 0,
      avg_query_time_ms: 0
    }

    Logger.info("SearchService started")
    {:ok, state}
  end

  @impl true
  def handle_call({:search, query, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    result =
      search_sync(query, opts)
      |> maybe_enrich_results(opts)

    query_time_ms = System.monotonic_time(:millisecond) - start_time

    new_state =
      case result do
        {:ok, _} ->
          %{
            state
            | total_queries: state.total_queries + 1,
              successful_queries: state.successful_queries + 1,
              avg_query_time_ms:
                (state.avg_query_time_ms * state.successful_queries + query_time_ms) /
                  (state.successful_queries + 1)
          }

        {:error, _} ->
          %{
            state
            | total_queries: state.total_queries + 1,
              failed_queries: state.failed_queries + 1
          }
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.merge(state, %{vector_store_stats: VectorStore.stats()}), state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp embed_query(query) do
    EmbeddingClient.embed(query)
  end

  defp maybe_enrich_results({:ok, results}, opts) do
    if Keyword.get(opts, :include_metadata, false) do
      {:ok, Enum.map(results, &enrich_result/1)}
    else
      {:ok, results}
    end
  end

  defp maybe_enrich_results({:error, _} = error, _opts) do
    error
  end

  defp enrich_result(result) do
    chunk_id = get_in(result, [:chunk, :id])

    if chunk_id do
      case Repo.get(Document, chunk_id) do
        nil -> result
        doc -> put_in(result, [:chunk, :metadata], %{source: doc.title, url: doc.url})
      end
    else
      result
    end
  end

  @doc """
  Packs search results into a context string for LLM prompting.

  Formats results as a series of context blocks with citations.
  """
  @spec pack_context([Types.search_result()]) :: String.t()
  def pack_context(results) do
    results
    |> Enum.map(&format_result/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp format_result(result) do
    chunk = result.chunk
    score = Float.round(result.score, 2)

    """
    [Source #{result.rank} (similarity: #{score})]
    #{chunk.text}
    """
  end

  @doc """
  Formats results as source citations for LLM response.
  """
  @spec format_sources([Types.search_result()]) :: [String.t()]
  def format_sources(results) do
    Enum.map(results, fn result ->
      rank = result.rank
      score = Float.round(result.score, 2)

      "[#{rank}] (score: #{score})"
    end)
  end
end
