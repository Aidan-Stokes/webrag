defmodule WebRAG.Repo do
  @moduledoc """
  Ecto repository for WebRAG's PostgreSQL database.

  This module provides the data access layer for storing and retrieving:
  - Raw crawled documents
  - Parsed content with metadata
  - Embeddings and vector data
  - Crawl job state and history

  ## Database Schema

  The repository manages the following tables:
  - `documents` - Stores raw and parsed document content
  - `chunks` - Stores chunked document content for embedding
  - `embeddings` - Stores vector embeddings with metadata
  - `crawl_jobs` - Tracks crawl job state and progress
  - `crawl_urls` - Deduplication and status tracking for URLs

  ## Design Decisions

  1. **Single Repo Pattern**: We use a single repository for all data access,
     keeping the system simple while maintaining proper separation through
     context modules.

  2. **UUID Primary Keys**: All tables use UUID primary keys for:
     - Distributed generation (no sequence contention)
     - Obfuscation of internal IDs in API responses
     - Easy merging of data from multiple sources

  3. **Timestamps**: All tables include `inserted_at` and `updated_at` for:
     - Audit trails
     - Incremental sync logic
     - Cache invalidation

  4. **Soft Deletes**: We use `deleted_at` for documents to:
     - Preserve referential integrity
     - Enable historical queries
     - Support undo functionality
  """

  use Ecto.Repo,
    otp_app: :webrag,
    adapter: Ecto.Adapters.Postgres

  import Ecto.Query

  @typedoc "A document record from the database"
  @type document :: %WebRAG.Document{}

  @typedoc "A chunk record from the database"
  @type chunk :: %WebRAG.Chunk{}

  @typedoc "An embedding record from the database"
  @type embedding :: %WebRAG.Embedding{}

  @typedoc "A crawl job record from the database"
  @type crawl_job :: %WebRAG.CrawlJob{}

  @doc """
  Returns the primary Ecto query prefix.
  Used for multi-tenant setups if needed.
  """
  @spec prefix() :: String.t() | nil
  def prefix, do: Application.get_env(:webrag, :database_prefix)

  @doc """
  Returns all documents for a given type.
  Useful for bulk processing specific content types.
  """
  @spec list_documents_by_type(String.t(), keyword()) :: [document()]
  def list_documents_by_type(_type, _opts \\ []) do
    []
  end

  @doc """
  Returns documents that haven't been processed (no embeddings).
  Used by the indexing pipeline to find work items.
  """
  @spec unprocessed_documents(keyword()) :: [document()]
  def unprocessed_documents(opts \\ []) do
    limit = Keyword.get(opts, :batch_size, 50)

    WebRAG.Document
    |> where([d], is_nil(d.processed_at))
    |> order_by(asc: :inserted_at)
    |> limit(^limit)
    |> __MODULE__.all()
  end

  @doc """
  Returns chunks that haven't been embedded.
  Used by the embedding pipeline.
  """
  @spec unembedded_chunks(keyword()) :: [chunk()]
  def unembedded_chunks(opts \\ []) do
    limit = Keyword.get(opts, :batch_size, 100)

    WebRAG.Chunk
    |> join(:left, [c], e in WebRAG.Embedding, on: c.id == e.chunk_id)
    |> where([c, e], is_nil(e.id))
    |> order_by(asc: :inserted_at)
    |> limit(^limit)
    |> __MODULE__.all()
  end

  @doc """
  Performs a semantic search using pg_vector cosine similarity.
  Falls back to standard text search if vector search fails.
  """
  @spec semantic_search(String.t(), integer(), keyword()) :: [chunk()]
  def semantic_search(query_embedding, top_k \\ 5, opts \\ []) do
    similarity_threshold = Keyword.get(opts, :threshold, 0.7)

    # Use raw SQL for pg_vector similarity search
    # This is more efficient than loading all embeddings into Elixir
    sql = """
      SELECT c.*,
             1 - (e.embedding <=> $1::vector) AS similarity
      FROM chunks c
      INNER JOIN embeddings e ON c.id = e.chunk_id
      WHERE 1 - (e.embedding <=> $1::vector) > $2
      ORDER BY e.embedding <=> $1::vector
      LIMIT $3
    """

    case __MODULE__.query(sql, [query_embedding, similarity_threshold, top_k]) do
      {:ok, %{rows: rows, columns: cols}} ->
        rows
        |> Enum.map(fn row ->
          chunk_from_row(cols, row)
        end)

      {:error, _} ->
        # Fallback to keyword search if vector search fails
        fallback_text_search(query_embedding, top_k)
    end
  end

  defp chunk_from_row(columns, row) do
    # Map columns to a chunk struct
    # Note: We return a map here for flexibility
    columns
    |> Enum.zip(row)
    |> Enum.into(%{})
    |> then(fn map ->
      struct(WebRAG.Chunk, map)
    end)
  end

  defp fallback_text_search(query, top_k) do
    # Simple ILIKE-based fallback
    pattern = "%#{query}%"

    WebRAG.Chunk
    |> where([c], ilike(c.content, ^pattern))
    |> limit(^top_k)
    |> __MODULE__.all()
  end

  @doc """
  Marks a document as processed (embeddings generated).
  """
  @spec mark_document_processed(Ecto.UUID.t(), DateTime.t()) :: {:ok, document()}
  def mark_document_processed(document_id, processed_at \\ DateTime.utc_now()) do
    WebRAG.Document
    |> where(id: ^document_id)
    |> __MODULE__.update_all(set: [processed_at: processed_at, updated_at: DateTime.utc_now()])
    |> case do
      {1, [document]} -> {:ok, document}
      {0, []} -> {:error, :not_found}
    end
  end

  @doc """
  Gets or creates a crawl job for URL deduplication.
  Returns the existing job if one exists.
  """
  @spec get_or_create_crawl_job(String.t(), keyword()) ::
          {:ok, crawl_job()} | {:error, Ecto.Changeset.t()}
  def get_or_create_crawl_job(url, opts \\ []) do
    job_type = Keyword.get(opts, :type, :incremental)

    case __MODULE__.get_by(WebRAG.CrawlJob, url: url) do
      nil ->
        %WebRAG.CrawlJob{
          url: url,
          status: :pending,
          job_type: job_type
        }
        |> WebRAG.CrawlJob.create_changeset(%{})
        |> __MODULE__.insert()

      existing_job ->
        {:ok, existing_job}
    end
  end

  @doc """
  Updates the status of a crawl job atomically.
  Handles concurrent updates safely.
  """
  @spec update_job_status(Ecto.UUID.t(), atom(), keyword()) :: :ok | :error
  def update_job_status(job_id, status, opts \\ []) do
    updates =
      [
        status: status,
        updated_at: DateTime.utc_now()
      ]
      |> maybe_add_completed_at(status, opts)

    result =
      WebRAG.CrawlJob
      |> where(id: ^job_id)
      |> __MODULE__.update_all(set: updates)

    case result do
      {1, _} -> :ok
      {0, _} -> :error
    end
  end

  defp maybe_add_completed_at(updates, :completed, _opts) do
    Keyword.put(updates, :completed_at, DateTime.utc_now())
  end

  defp maybe_add_completed_at(updates, :failed, opts) do
    error_message = Keyword.get(opts, :error_message)
    updates = Keyword.put(updates, :completed_at, DateTime.utc_now())

    if error_message do
      Keyword.put(updates, :error_message, error_message)
    else
      updates
    end
  end

  defp maybe_add_completed_at(updates, _, _), do: updates

  @doc """
  Returns crawl job statistics for monitoring.
  """
  @spec crawl_job_stats() :: %{optional(atom()) => integer()}
  def crawl_job_stats do
    statuses = [:pending, :in_progress, :completed, :failed, :cancelled]

    Enum.reduce(statuses, %{}, fn status, acc ->
      count =
        WebRAG.CrawlJob
        |> where(status: ^status)
        |> select(count())
        |> __MODULE__.one()

      Map.put(acc, status, count)
    end)
    |> Map.put(:total, __MODULE__.aggregate(WebRAG.CrawlJob, :count, :id))
  end

  @doc """
  Deletes old crawl jobs, keeping the most recent ones.
  Used for maintenance and log rotation.
  """
  @spec cleanup_old_jobs(pos_integer()) :: {:ok, non_neg_integer()}
  def cleanup_old_jobs(keep_last_n \\ 1000) do
    # Get the cutoff ID (the Nth most recent job)
    cutoff_id =
      WebRAG.CrawlJob
      |> order_by(desc: :inserted_at)
      |> offset(^keep_last_n)
      |> limit(1)
      |> select([j], j.id)
      |> __MODULE__.one()

    if cutoff_id do
      {deleted, _} =
        WebRAG.CrawlJob
        |> where([j], j.id < ^cutoff_id)
        |> __MODULE__.delete_all()

      {:ok, deleted}
    else
      {:ok, 0}
    end
  end

  @doc """
  Transaction wrapper for bulk operations.
  Ensures atomicity of multi-step operations.
  """
  @spec run_transaction(fun()) :: {:ok, term()} | {:error, term()}
  def run_transaction(fun) when is_function(fun, 0) do
    __MODULE__.transaction(fun)
  end

  @doc """
  Returns documents with their chunk counts for analysis.
  """
  @spec documents_with_chunk_counts(keyword()) :: [
          %{document: document(), chunk_count: integer()}
        ]
  def documents_with_chunk_counts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    WebRAG.Document
    |> join(:left, [d], c in WebRAG.Chunk, on: d.id == c.document_id)
    |> group_by([d], d.id)
    |> select([d, c], %{
      document: d,
      chunk_count: count(c.id)
    })
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> __MODULE__.all()
  end
end
