defmodule AONCrawler.DB do
  @moduledoc """
  Simple JSON file-based database for local storage.

  Stores data in JSON files for simplicity and portability.
  """

  @data_dir Path.expand("../data", __DIR__)

  @doc """
  Initializes the database directory.
  """
  @spec init() :: :ok
  def init do
    File.mkdir_p!(@data_dir)
    File.mkdir_p!(Path.join(@data_dir, "chunks"))
    :ok
  end

  # ============================================================================
  # Documents
  # ============================================================================

  @doc """
  Saves a document.
  """
  @spec save_document(map()) :: :ok
  def save_document(doc) do
    path = Path.join(@data_dir, "documents.json")
    docs = load_documents()

    updated = Enum.reject(docs, fn d -> d["url"] == doc["url"] end) ++ [doc]

    File.write!(path, Jason.encode!(updated, pretty: true))
  end

  @doc """
  Gets a document by URL.
  """
  @spec get_document(String.t()) :: map() | nil
  def get_document(url) do
    docs = load_documents()
    Enum.find(docs, fn d -> d["url"] == url end)
  end

  @doc """
  Lists all documents.
  """
  @spec list_documents() :: [map()]
  def list_documents do
    load_documents()
  end

  @doc """
  Returns document count.
  """
  @spec document_count() :: non_neg_integer()
  def document_count do
    length(load_documents())
  end

  defp load_documents do
    path = Path.join(@data_dir, "documents.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, docs} -> docs
          _ -> []
        end

      _ ->
        []
    end
  end

  # ============================================================================
  # Chunks
  # ============================================================================

  @doc """
  Saves a chunk.
  """
  @spec save_chunk(map()) :: :ok
  def save_chunk(chunk) do
    chunks = load_chunks()
    updated = Enum.reject(chunks, fn c -> c["id"] == chunk["id"] end) ++ [chunk]
    save_chunks(updated)
  end

  @doc """
  Saves multiple chunks at once.
  """
  @spec save_chunks_list([map()]) :: :ok
  def save_chunks_list(new_chunks) do
    chunks = load_chunks()

    existing_ids = MapSet.new(Enum.map(chunks, & &1["id"]))
    filtered_new = Enum.reject(new_chunks, fn c -> MapSet.member?(existing_ids, c["id"]) end)

    updated = chunks ++ filtered_new
    save_chunks(updated)
  end

  @doc """
  Gets all embeddings with their chunks (for search).
  """
  @spec get_embeddings_with_chunks() :: [map()]
  def get_embeddings_with_chunks do
    chunks_list = load_chunks()
    chunks = Enum.into(chunks_list, %{}, fn c -> {c["id"], c} end)
    embeddings = load_embeddings()

    Enum.map(embeddings, fn e ->
      chunk_id = e["chunk_id"]
      chunk = Map.get(chunks, chunk_id, %{})

      Map.put(e, "content", chunk["content"])
      |> Map.put("document_id", chunk["document_id"])
    end)
  end

  @doc """
  Gets a chunk by ID.
  """
  @spec get_chunk(String.t()) :: map() | nil
  def get_chunk(id) do
    chunks = load_chunks()
    Enum.find(chunks, fn c -> c["id"] == id end)
  end

  @doc """
  Gets chunks for a document.
  """
  @spec get_chunks_for_document(String.t()) :: [map()]
  def get_chunks_for_document(document_id) do
    chunks = load_chunks()
    Enum.filter(chunks, fn c -> c["document_id"] == document_id end)
  end

  @doc """
  Returns chunk count.
  """
  @spec chunk_count() :: non_neg_integer()
  def chunk_count do
    length(load_chunks())
  end

  @doc """
  Gets chunks without embeddings.
  """
  @spec get_unembedded_chunks() :: [map()]
  def get_unembedded_chunks do
    chunks = load_chunks()
    embeddings = MapSet.new(Enum.map(load_embeddings(), & &1["chunk_id"]))

    Enum.filter(chunks, fn c ->
      !MapSet.member?(embeddings, c["id"])
    end)
  end

  defp load_chunks do
    path = Path.join(@data_dir, "chunks.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, chunks} -> chunks
          _ -> []
        end

      _ ->
        []
    end
  end

  defp save_chunks(chunks) do
    path = Path.join(@data_dir, "chunks.json")
    File.write!(path, Jason.encode!(chunks, pretty: true))
  end

  # ============================================================================
  # Embeddings
  # ============================================================================

  @doc """
  Saves an embedding.
  """
  @spec save_embedding(map()) :: :ok
  def save_embedding(embedding) do
    embeddings = load_embeddings()

    updated =
      Enum.reject(embeddings, fn e -> e["chunk_id"] == embedding["chunk_id"] end) ++ [embedding]

    save_embeddings(updated)
  end

  @doc """
  Saves multiple embeddings at once.
  """
  @spec save_embeddings_list([map()]) :: :ok
  def save_embeddings_list(new_embeddings) do
    embeddings = load_embeddings()

    existing_ids = MapSet.new(Enum.map(embeddings, & &1["chunk_id"]))

    filtered_new =
      Enum.reject(new_embeddings, fn e -> MapSet.member?(existing_ids, e["chunk_id"]) end)

    updated = embeddings ++ filtered_new
    save_embeddings(updated)
  end

  @doc """
  Lists all embeddings.
  """
  @spec list_embeddings() :: [map()]
  def list_embeddings do
    load_embeddings()
  end

  @doc """
  Gets an embedding by chunk ID.
  """
  @spec get_embedding(String.t()) :: map() | nil
  def get_embedding(chunk_id) do
    embeddings = load_embeddings()
    Enum.find(embeddings, fn e -> e["chunk_id"] == chunk_id end)
  end

  @doc """
  Returns embedding count.
  """
  @spec embedding_count() :: non_neg_integer()
  def embedding_count do
    length(load_embeddings())
  end

  defp load_embeddings do
    path = Path.join(@data_dir, "embeddings.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, embeddings} -> embeddings
          _ -> []
        end

      _ ->
        []
    end
  end

  defp save_embeddings(embeddings) do
    path = Path.join(@data_dir, "embeddings.json")
    File.write!(path, Jason.encode!(embeddings, pretty: true))
  end

  # ============================================================================
  # Stats
  # ============================================================================

  @doc """
  Returns database statistics.
  """
  @spec stats() :: map()
  def stats do
    %{
      documents: document_count(),
      chunks: chunk_count(),
      embeddings: embedding_count()
    }
  end
end
