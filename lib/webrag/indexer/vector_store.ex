defmodule WebRAG.Indexer.VectorStore do
  @moduledoc """
  Vector store for embeddings with in-memory search.
  """
  use GenServer
  require Logger

  @default_top_k 5
  @default_min_score 0.1
  @search_multiplier 3

  # Client API
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def insert_embedding(c, ctd, v, _), do: GenServer.cast(__MODULE__, {:insert, c, ctd, v})
  def search(qv, opts \\ []), do: GenServer.call(__MODULE__, {:search, qv, opts}, 60_000)
  def count, do: GenServer.call(__MODULE__, :count)
  def stats, do: GenServer.call(__MODULE__, :stats)
  def loaded?, do: GenServer.call(__MODULE__, :loaded?)
  def load_embeddings, do: GenServer.cast(__MODULE__, :load_from_storage)
  def get_url(chunk_id), do: GenServer.call(__MODULE__, {:get_url, chunk_id})
  def clear, do: GenServer.cast(__MODULE__, :clear)

  # GenServer
  @impl true
  def init(_opts) do
    :ets.new(:embeddings, [:set, :named_table, :public])
    :ets.new(:chunk_urls, [:set, :named_table, :public])
    Logger.info("VectorStore started")
    {:ok, %{loaded: false, total_count: 0, chunk_count: 0}}
  end

  @impl true
  def handle_cast({:insert, chunk_id, content_id, vector}, state) do
    :ets.insert(:embeddings, {chunk_id, content_id, vector})
    {:noreply, %{state | total_count: state.total_count + 1}}
  end

  @impl true
  def handle_cast(:load_from_storage, state) do
    Logger.info("Loading embeddings...")
    embeddings = WebRAG.Storage.load_embeddings()
    chunks = WebRAG.Storage.load_chunks()

    Enum.each(chunks, fn chunk ->
      url = if chunk.metadata, do: chunk.metadata["url"] || "", else: ""
      :ets.insert(:chunk_urls, {chunk.id, url})
    end)

    Enum.each(embeddings, fn emb ->
      :ets.insert(:embeddings, {emb.chunk_id, emb.chunk_id, emb.vector})
    end)

    Logger.info("Loaded #{length(embeddings)} embeddings")
    {:noreply, %{loaded: true, total_count: length(embeddings), chunk_count: length(chunks)}}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.delete_all_objects(:embeddings)
    :ets.delete_all_objects(:chunk_urls)
    {:noreply, %{state | loaded: false, total_count: 0, chunk_count: 0}}
  end

  @impl true
  def handle_call({:search, qv, opts}, _from, state) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    min_score = Keyword.get(opts, :min_score, @default_min_score)
    source = Keyword.get(opts, :source, nil)

    if state.total_count == 0,
      do: {:reply, [], state},
      else: {:reply, do_search(qv, top_k, min_score, source), state}
  end

  @impl true
  def handle_call(:count, _from, state), do: {:reply, state.total_count, state}

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       cached_embeddings: state.total_count,
       loaded: state.loaded,
       ets_memory: :ets.info(:embeddings, :memory) * 8
     }, state}
  end

  @impl true
  def handle_call(:loaded?, _from, state), do: {:reply, state.loaded, state}

  @impl true
  def handle_call({:get_url, chunk_id}, _from, state) do
    case :ets.lookup(:chunk_urls, chunk_id) do
      [{_, url}] -> {:reply, url, state}
      _ -> {:reply, nil, state}
    end
  end

  defp do_search(qv, top_k, min_score, source) do
    limit = top_k * @search_multiplier

    :ets.tab2list(:embeddings)
    |> Stream.map(fn {cid, ctd, vec} ->
      url =
        if source,
          do:
            (case :ets.lookup(:chunk_urls, cid) do
               [{_, u}] -> u
               _ -> nil
             end),
          else: nil

      if source && url && !String.contains?(url, source),
        do: nil,
        else: %{
          chunk_id: cid,
          content_id: ctd,
          score: cosine(qv, vec),
          vector: vec
        }
    end)
    |> Stream.reject(&is_nil/1)
    |> Stream.filter(fn %{score: s} -> s >= min_score end)
    |> Enum.sort_by(fn %{score: s} -> s end, :desc)
    |> Enum.take(limit)
  end

  defp cosine(v1, v2) do
    mag = fn v -> :math.sqrt(Enum.reduce(v, 0, fn x, a -> x * x + a end)) end
    m1 = mag.(v1)
    m2 = mag.(v2)

    if m1 == 0 or m2 == 0,
      do: 0.0,
      else: Enum.reduce(Enum.zip(v1, v2), 0, fn {a, b}, c -> a * b + c end) / (m1 * m2)
  end
end
