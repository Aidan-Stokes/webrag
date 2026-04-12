defmodule AONCrawler.Indexer.VectorStore do
  @moduledoc """
  Vector store for embeddings - simplified in-memory implementation.
  """
  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec insert_embedding(String.t(), String.t(), [float()], String.t()) :: :ok
  def insert_embedding(chunk_id, content_id, vector, _model) do
    GenServer.cast(__MODULE__, {:insert, chunk_id, content_id, vector})
  end

  @spec search([float()], keyword()) :: {:ok, []}
  def search(_query_vector, _opts \\ []) do
    {:ok, []}
  end

  @spec search_text(String.t(), keyword()) :: {:ok, []}
  def search_text(_query_text, _opts \\ []) do
    {:ok, []}
  end

  @spec count() :: non_neg_integer()
  def count do
    0
  end

  @spec stats() :: map()
  def stats do
    %{cached_embeddings: 0}
  end

  @spec vector_dimensions(String.t()) :: pos_integer()
  def vector_dimensions(_model) do
    1536
  end

  @impl true
  def init(_opts) do
    :ets.new(:embeddings, [:set, :named_table, :public])
    Logger.info("VectorStore started")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:insert, chunk_id, content_id, vector}, state) do
    :ets.insert(:embeddings, {chunk_id, content_id, vector})
    {:noreply, state}
  end

  @impl true
  def handle_call({:search, _query_vector, _top_k, _min_score, _content_types}, _from, state) do
    {:reply, {:ok, []}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{cached_embeddings: :ets.info(:embeddings, :size)}, state}
  end
end
