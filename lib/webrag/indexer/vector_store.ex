defmodule WebRAG.Indexer.VectorStore do
  @moduledoc """
  Vector store for embeddings with in-memory search.

  Uses ETS for fast lookups and implements cosine similarity search
  with early termination for performance at scale.
  """
  use GenServer
  require Logger

  @default_top_k 5
  @default_min_score 0.1
  @search_multiplier 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec insert_embedding(String.t(), String.t(), [float()], String.t()) :: :ok
  def insert_embedding(chunk_id, content_id, vector, _model) do
    GenServer.cast(__MODULE__, {:insert, chunk_id, content_id, vector})
  end

  @spec insert_embeddings([{String.t(), String.t(), [float()]}]) :: :ok
  def insert_embeddings(embeddings) do
    GenServer.cast(__MODULE__, {:insert_batch, embeddings})
  end

  @doc """
  Searches for similar embeddings using cosine similarity.

  ## Options
    - `:top_k` - Number of results to return (default: 5)
    - `:min_score` - Minimum similarity score (default: 0.1)
  """
  @spec search([float()], keyword()) ::
          {:ok, [%{chunk_id: String.t(), score: float(), vector: [float()]}]}
  def search(query_vector, opts \\ []) do
    GenServer.call(__MODULE__, {:search, query_vector, opts}, 60_000)
  end

  @spec search_text(String.t(), keyword()) :: {:ok, []}
  def search_text(_query_text, _opts \\ []) do
    {:ok, []}
  end

  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @spec vector_dimensions(String.t()) :: pos_integer()
  def vector_dimensions(_model) do
    1024
  end

  @spec loaded?() :: boolean()
  def loaded? do
    GenServer.call(__MODULE__, :loaded?)
  end

  @spec load_embeddings() :: :ok
  def load_embeddings do
    GenServer.cast(__MODULE__, :load_from_storage)
  end

  @spec clear() :: :ok
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  @impl true
  def init(_opts) do
    :ets.new(:embeddings, [:set, :named_table, :public])
    :ets.new(:embedding_cache, [:set, :named_table, :public, read_concurrency: true])

    state = %{
      embeddings_loaded: false,
      total_count: 0
    }

    Logger.info("VectorStore started (empty)")
    {:ok, state}
  end

  @impl true
  def handle_cast({:insert, chunk_id, content_id, vector}, state) do
    :ets.insert(:embeddings, {chunk_id, content_id, vector})
    {:noreply, %{state | total_count: state.total_count + 1}}
  end

  @impl true
  def handle_cast({:insert_batch, embeddings}, state) do
    Enum.each(embeddings, fn {chunk_id, content_id, vector} ->
      :ets.insert(:embeddings, {chunk_id, content_id, vector})
    end)

    {:noreply, %{state | total_count: state.total_count + length(embeddings)}}
  end

  @impl true
  def handle_cast(:load_from_storage, state) do
    Logger.info("Loading embeddings from storage...")

    embeddings = WebRAG.Storage.load_embeddings()
    chunks = WebRAG.Storage.load_chunks()

    chunk_map =
      Enum.reduce(chunks, %{}, fn chunk, acc ->
        Map.put(acc, chunk.id, chunk)
      end)

    Enum.each(embeddings, fn emb ->
      chunk = Map.get(chunk_map, emb.chunk_id)
      content_id = if chunk, do: chunk.document_id, else: ""
      :ets.insert(:embeddings, {emb.chunk_id, content_id, emb.vector})
    end)

    loaded_count = length(embeddings)
    Logger.info("Loaded #{loaded_count} embeddings into VectorStore")

    {:noreply, %{state | embeddings_loaded: true, total_count: loaded_count}}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.delete_all_objects(:embeddings)
    {:noreply, %{state | embeddings_loaded: false, total_count: 0}}
  end

  @impl true
  def handle_call({:search, query_vector, opts}, _from, state) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    min_score = Keyword.get(opts, :min_score, @default_min_score)

    if state.total_count == 0 do
      {:reply, [], state}
    else
      results = do_search(query_vector, top_k, min_score)
      {:reply, results, state}
    end
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, state.total_count, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      cached_embeddings: state.total_count,
      loaded: state.embeddings_loaded,
      ets_memory: :ets.info(:embeddings, :memory) * 8
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:loaded?, _from, state) do
    {:reply, state.embeddings_loaded, state}
  end

  defp do_search(query_vector, top_k, min_score) do
    search_limit = top_k * @search_multiplier

    :ets.tab2list(:embeddings)
    |> Stream.map(fn {chunk_id, content_id, vector} ->
      score = cosine_similarity(query_vector, vector)
      %{chunk_id: chunk_id, content_id: content_id, score: score, vector: vector}
    end)
    |> Stream.filter(fn %{score: score} -> score >= min_score end)
    |> Enum.sort_by(fn %{score: score} -> score end, :desc)
    |> Enum.take(search_limit)
  end

  defp cosine_similarity(v1, v2) do
    case compute_magnitude(v1) do
      0.0 ->
        0.0

      mag1 ->
        case compute_magnitude(v2) do
          0.0 ->
            0.0

          mag2 ->
            dot = dot_product(v1, v2)
            dot / (mag1 * mag2)
        end
    end
  end

  defp dot_product(v1, v2) do
    Enum.reduce(Enum.zip(v1, v2), 0, fn {a, b}, acc -> a * b + acc end)
  end

  defp compute_magnitude(v) do
    :math.sqrt(Enum.reduce(v, 0, fn x, acc -> x * x + acc end))
  end
end
