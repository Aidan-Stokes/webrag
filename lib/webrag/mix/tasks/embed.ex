defmodule Mix.Tasks.Embed do
  @moduledoc """
  Generates vector embeddings for indexed chunks.

  ## Usage

      mix embed

  ## Options

      - `--batch-size <n>` - Number of embeddings per batch. Default: 100.
      - `--only-missing` - Only embed chunks that don't have embeddings yet.

  ## Examples

      mix embed
      mix embed --batch-size 256
      mix embed --only-missing
  """
  use Mix.Task
  require Logger

  alias WebRAG.Network.DLQ

  @shortdoc "Generate vector embeddings"

  @default_batch_size 20

  @progress_ets :webrag_embed_progress

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:webrag)

    {opts, _query_args, _} =
      OptionParser.parse(args,
        switches: [
          batch_size: :integer,
          only_missing: :boolean
        ],
        aliases: [b: :batch_size]
      )

    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    only_missing = Keyword.get(opts, :only_missing, false)

    Logger.info("Embedding batch size: #{batch_size}")

    chunks =
      if only_missing do
        Logger.info("Processing only missing embeddings...")
        WebRAG.Storage.chunks_without_embeddings()
      else
        Logger.info("Processing all chunks...")
        WebRAG.Storage.load_chunks()
      end

    if length(chunks) == 0 do
      Logger.info("No chunks to embed.")
      exit({:shutdown, 0})
    end

    Logger.info("Embedding #{length(chunks)} chunks...")
    Logger.info("This may take a while...")

    :ets.new(@progress_ets, [:set, :named_table, :public])

    # Convert chunks to text list for embedding
    texts = Enum.map(chunks, fn c -> c.text end)

    result =
      case WebRAG.Indexer.EmbeddingClient.embed_batch(texts, batch_size: batch_size) do
        {:ok, embeddings} when is_list(embeddings) and length(embeddings) > 0 ->
          # Save embeddings with their chunk IDs
          Logger.info("Saving #{length(embeddings)} embeddings...")

          model =
            Application.get_env(:webrag, :indexer, [])[:embedding_model] || "mxbai-embed-large"

          # Zip texts and embeddings (not chunks and embeddings since texts failed may be filtered out)
          Enum.each(Enum.zip(chunks, embeddings), fn {chunk, embedding} ->
            WebRAG.Storage.append_embedding(%{
              id: UUID.uuid4(),
              chunk_id: chunk.id,
              vector: embedding,
              model: model,
              token_count: ceil(String.length(chunk.text) / 4)
            })
          end)

          Logger.info("Embedded #{length(embeddings)} chunks")

          # Build IDF index after embedding
          Logger.info("Building IDF index...")
          build_idf_index()

          {:ok, length(embeddings)}

        {:ok, []} ->
          Logger.warn("All embeddings failed")
          {:error, :all_batches_failed}

        {:error, reason} ->
          Logger.error("Embedding failed: #{inspect(reason)}")
          DLQ.save(:embed, "batch", reason, %{})
          {:error, reason}
      end

    :ets.delete(@progress_ets)
    result
  end

  defp build_idf_index do
    alias WebRAG.Search.IDFScorer

    chunks = WebRAG.Storage.load_chunks()
    total_docs = length(chunks)

    Logger.info("Computing IDF for #{total_docs} chunks...")

    freq_map =
      Enum.reduce(chunks, %{}, fn chunk, acc ->
        terms =
          chunk.text
          |> String.downcase()
          |> String.replace(~r/[^\w\s]/, "")
          |> String.split()
          |> Enum.filter(fn w -> String.length(w) > 2 end)
          |> Enum.map(fn w -> stem_word(w) end)
          |> Enum.uniq()

        Enum.reduce(terms, acc, fn term, inner_acc ->
          Map.update(inner_acc, term, 1, &(&1 + 1))
        end)
      end)

    Logger.info("Found #{map_size(freq_map)} unique terms")

    idf_map =
      freq_map
      |> Enum.map(fn {term, freq} ->
        safe_freq = max(freq, 1)
        idf = :math.log(total_docs / safe_freq)
        {term, %{frequency: freq, idf: idf}}
      end)
      |> Map.new()

    # Save IDF
    json_path = Path.join(["data", "idf_terms.json"])

    data =
      idf_map
      |> Map.to_list()
      |> Enum.map(fn {term, d} -> %{term: term, frequency: d[:frequency], idf: d[:idf]} end)

    File.write!(json_path, Jason.encode!(data, pretty: true))
    Logger.info("IDF index saved to data/idf_terms.json")
  end

  defp stem_word(word) do
    String.replace(word, ~r/(s|es|ed|ing|'s|'s)$/, "")
  end
end
