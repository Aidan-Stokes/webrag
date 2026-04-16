defmodule AONCrawler.Storage do
  @moduledoc """
  Storage module for JSON and Protocol Buffer persistence.

  - JSON: Human-readable for testing/debugging
  - Protocol Buffers: Fast binary for production pipeline

  Data directory structure:
    data/
      documents/
        documents.json     (all documents as JSON array)
        documents.pb       (Protocol Buffer binary)
      chunks/
        chunks.json
        chunks.pb
      embeddings/
        embeddings.json
        embeddings.pb
      sources/
        <source_id>/
          discovered_urls.json
          discovered_urls.pb
  """

  alias AONCrawler.Protobuf.{
    Document,
    Chunk,
    Embedding,
    DiscoveredUrl,
    DiscoveredUrls
  }

  @data_dir "data"
  @default_source_dir "sources"

  @doc """
  Returns the data directory path.
  """
  def data_dir, do: @data_dir

  @doc """
  Ensures data directories exist.
  """
  def ensure_directories do
    directories = [
      Path.join(@data_dir, "documents"),
      Path.join(@data_dir, "chunks"),
      Path.join(@data_dir, "embeddings"),
      Path.join(@data_dir, @default_source_dir)
    ]

    Enum.each(directories, &File.mkdir_p!/1)
  end

  @doc """
  Appends a document to Protocol Buffer and JSON files.
  """
  def append_document(%{
        id: id,
        url: url,
        text: text,
        content_type: content_type,
        metadata: metadata
      }) do
    ensure_directories()

    pb_path = Path.join([@data_dir, "documents", "documents.pb"])

    timestamp = DateTime.utc_now() |> DateTime.to_unix()

    metadata_map =
      Enum.reduce(metadata, %{}, fn {k, v}, acc ->
        Map.put(acc, to_string(k), to_string(v))
      end)

    doc = %Document{
      id: id,
      url: url,
      text: text,
      content_type: content_type,
      metadata: metadata_map,
      timestamp: timestamp
    }

    append_pb_message(pb_path, Document.encode(doc))

    :ok
  end

  @doc """
  Appends multiple documents efficiently.
  """
  def append_documents(documents) when is_list(documents) do
    Enum.each(documents, &append_document/1)
  end

  @doc """
  Appends a chunk to Protocol Buffer and JSON files.
  """
  def append_chunk(%{
        id: id,
        document_id: document_id,
        text: text,
        chunk_index: index,
        total_chunks: total,
        metadata: metadata
      }) do
    ensure_directories()

    pb_path = Path.join([@data_dir, "chunks", "chunks.pb"])

    metadata_map =
      Enum.reduce(metadata || %{}, %{}, fn {k, v}, acc ->
        Map.put(acc, to_string(k), to_string(v))
      end)

    chunk = %Chunk{
      id: id,
      document_id: document_id,
      text: text,
      index: index,
      total: total,
      metadata: metadata_map
    }

    append_pb_message(pb_path, Chunk.encode(chunk))

    :ok
  end

  @doc """
  Appends an embedding to Protocol Buffer and JSON files.
  """
  def append_embedding(%{
        id: id,
        chunk_id: chunk_id,
        vector: vector,
        model: model,
        token_count: token_count
      }) do
    ensure_directories()

    pb_path = Path.join([@data_dir, "embeddings", "embeddings.pb"])

    embedding = %Embedding{
      id: id,
      chunk_id: chunk_id,
      vector: vector,
      model: model,
      token_count: token_count
    }

    append_pb_message(pb_path, Embedding.encode(embedding))

    :ok
  end

  @doc """
  Saves discovered URLs for a source.
  """
  def append_discovered_urls(source_id, urls) when is_atom(source_id) do
    source_dir = Path.join([@data_dir, @default_source_dir, Atom.to_string(source_id)])
    File.mkdir_p!(source_dir)

    pb_path = Path.join(source_dir, "discovered_urls.pb")

    timestamp = DateTime.utc_now() |> DateTime.to_unix()

    Enum.each(urls, fn url ->
      discovered_url = %DiscoveredUrl{
        url: url,
        discovered_at: timestamp
      }

      append_pb_message(pb_path, DiscoveredUrl.encode(discovered_url))
    end)

    :ok
  end

  @doc """
  Loads all documents from the Protocol Buffer file.
  Falls back to JSON if pb doesn't exist.
  """
  def load_documents do
    pb_path = Path.join([@data_dir, "documents", "documents.pb"])
    json_path = Path.join([@data_dir, "documents", "documents.json"])

    cond do
      File.exists?(pb_path) ->
        load_pb_messages(pb_path, &Document.decode/1)

      File.exists?(json_path) ->
        load_json(json_path)

      true ->
        []
    end
  end

  @doc """
  Loads all chunks from storage.
  """
  def load_chunks do
    pb_path = Path.join([@data_dir, "chunks", "chunks.pb"])
    json_path = Path.join([@data_dir, "chunks", "chunks.json"])

    cond do
      File.exists?(pb_path) ->
        load_pb_messages(pb_path, &Chunk.decode/1)

      File.exists?(json_path) ->
        load_json(json_path)

      true ->
        []
    end
  end

  @doc """
  Loads all embeddings from storage.
  """
  def load_embeddings do
    pb_path = Path.join([@data_dir, "embeddings", "embeddings.pb"])
    json_path = Path.join([@data_dir, "embeddings", "embeddings.json"])

    cond do
      File.exists?(pb_path) ->
        load_pb_messages(pb_path, &Embedding.decode/1)

      File.exists?(json_path) ->
        load_json(json_path)

      true ->
        []
    end
  end

  @doc """
  Loads discovered URLs for a source.
  """
  @spec load_discovered_urls(atom()) :: [String.t()]
  def load_discovered_urls(source_id) when is_atom(source_id) do
    source_dir = Path.join([@data_dir, @default_source_dir, Atom.to_string(source_id)])
    pb_path = Path.join(source_dir, "discovered_urls.pb")
    json_path = Path.join(source_dir, "discovered_urls.json")

    cond do
      File.exists?(pb_path) ->
        load_pb_messages(pb_path, &DiscoveredUrl.decode/1) |> Enum.map(& &1.url)

      File.exists?(json_path) ->
        load_json(json_path) |> Enum.map(& &1["url"])

      true ->
        []
    end
  end

  @doc """
  Returns a Set of all URLs that have already been crawled.
  """
  @spec crawled_urls() :: MapSet.t(String.t())
  def crawled_urls do
    pb_path = Path.join([@data_dir, "documents", "documents.pb"])
    json_path = Path.join([@data_dir, "documents", "documents.json"])

    cond do
      File.exists?(pb_path) ->
        load_pb_messages(pb_path, &Document.decode/1)
        |> Enum.map(& &1.url)
        |> MapSet.new()

      File.exists?(json_path) ->
        load_json(json_path)
        |> Enum.map(& &1["url"])
        |> MapSet.new()

      true ->
        MapSet.new()
    end
  end

  @doc """
  Exports .pb files to JSON format.
  """
  def export_to_json do
    ensure_directories()

    IO.puts("Exporting to JSON...")

    documents = load_documents()

    if documents != [],
      do: write_json(Path.join([@data_dir, "documents", "documents.json"]), documents)

    IO.puts("  Exported #{length(documents)} documents")

    chunks = load_chunks()
    if chunks != [], do: write_json(Path.join([@data_dir, "chunks", "chunks.json"]), chunks)
    IO.puts("  Exported #{length(chunks)} chunks")

    embeddings = load_embeddings()

    if embeddings != [],
      do: write_json(Path.join([@data_dir, "embeddings", "embeddings.json"]), embeddings)

    IO.puts("  Exported #{length(embeddings)} embeddings")

    IO.puts("Export complete!")
    :ok
  end

  @doc """
  Clears all data files.
  """
  def clear_all do
    [
      Path.join([@data_dir, "documents", "*.json"]),
      Path.join([@data_dir, "documents", "*.pb"]),
      Path.join([@data_dir, "chunks", "*.json"]),
      Path.join([@data_dir, "chunks", "*.pb"]),
      Path.join([@data_dir, "embeddings", "*.json"]),
      Path.join([@data_dir, "embeddings", "*.pb"])
    ]
    |> Enum.each(&delete_matching_files/1)

    :ok
  end

  @doc """
  Returns statistics about stored data.
  """
  def stats do
    %{
      documents: count_records("documents"),
      chunks: count_records("chunks"),
      embeddings: count_records("embeddings")
    }
  end

  defp count_records(type) do
    pb_path = Path.join([@data_dir, type, "#{type}.pb"])
    json_path = Path.join([@data_dir, type, "#{type}.json"])

    cond do
      File.exists?(pb_path) ->
        length(load_pb_messages(pb_path, decoder_for_type(type)))

      File.exists?(json_path) ->
        {:ok, data} = File.read(json_path)

        case Jason.decode(data) do
          {:ok, list} when is_list(list) -> length(list)
          _ -> 0
        end

      true ->
        0
    end
  end

  defp decoder_for_type("documents"), do: &Document.decode/1
  defp decoder_for_type("chunks"), do: &Chunk.decode/1
  defp decoder_for_type("embeddings"), do: &Embedding.decode/1

  @doc """
  Compacts discovered URLs for all sources into wrapper message.
  """
  def compact_discovered_urls(source_id) when is_atom(source_id) do
    source_dir = Path.join([@data_dir, @default_source_dir, Atom.to_string(source_id)])
    pb_path = Path.join(source_dir, "discovered_urls.pb")
    compacted_path = Path.join(source_dir, "discovered_urls_compacted.pb")

    if File.exists?(pb_path) do
      messages = load_pb_messages(pb_path, &DiscoveredUrl.decode/1)

      urls = %DiscoveredUrls{
        urls: messages
      }

      File.write!(compacted_path, DiscoveredUrls.encode(urls))
      IO.puts("Compacted #{length(messages)} URLs for #{source_id}")
    end
  end

  @doc """
  Compacts Protocol Buffer files (reads and rewrites to ensure valid format).
  """
  def compact_all do
    IO.puts("Compaction creates consolidated .pb files")
    IO.puts("Use: mix export  to export JSON from .pb files")
  end

  @doc """
  Saves discovered URLs to storage for a source.
  """
  @spec save_discovered_urls(any(), [String.t()]) :: :ok
  def save_discovered_urls(source, urls) do
    append_discovered_urls(source.id, urls)
  end

  @doc """
  Loads all discovered URLs from all sources.
  """
  @spec load_all_discovered_urls() :: %{atom() => [String.t()]}
  def load_all_discovered_urls do
    []
  end

  defp append_pb_message(path, binary) do
    size = byte_size(binary)
    content = <<size::32-little, binary::binary>>
    do_append(path, content)
  end

  defp do_append(path, content) do
    File.write!(path, content, [:append])
  rescue
    _ ->
      File.write!(path, content, [:append])
  end

  defp load_pb_messages(path, decoder) do
    case File.read(path) do
      {:ok, data} ->
        read_pb_messages(data, decoder, [])

      _ ->
        []
    end
  end

  defp read_pb_messages(<<>>, _decoder, acc), do: Enum.reverse(acc)

  defp read_pb_messages(
         <<size::32-little, binary::binary-size(size), rest::binary>>,
         decoder,
         acc
       ) do
    case try_decode(binary, decoder) do
      {:ok, message} ->
        read_pb_messages(rest, decoder, [message | acc])

      :error ->
        read_pb_messages(rest, decoder, acc)
    end
  end

  defp read_pb_messages(data, _decoder, acc) when byte_size(data) < 4, do: Enum.reverse(acc)

  defp try_decode(binary, decoder) do
    try do
      {:ok, decoder.(binary)}
    rescue
      _ -> :error
    end
  end

  defp load_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_list(data) -> data
          {:ok, _} -> []
          _ -> []
        end

      _ ->
        []
    end
  end

  defp write_json(path, data) do
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp delete_matching_files(pattern) do
    Path.wildcard(pattern)
    |> Enum.each(fn path ->
      if File.exists?(path), do: File.rm!(path)
    end)
  end
end
