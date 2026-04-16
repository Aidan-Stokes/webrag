defmodule Mix.Tasks.Embed do
  @moduledoc """
  Generates vector embeddings for indexed chunks.

  ## Usage

      mix embed

  ## Options

      - `--batch-size <n>` - Number of embeddings per batch. Default: 100.

  ## Examples

      mix embed
      mix embed --batch-size 256
  """
  use Mix.Task

  @shortdoc "Generate vector embeddings"

  @default_batch_size 100

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:aoncrawler)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          batch_size: :integer
        ],
        aliases: [b: :batch_size]
      )

    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    IO.puts("==================")
    IO.puts("Embed Phase - Generating Embeddings")
    IO.puts("==================")
    IO.puts("Batch size: #{batch_size}")
    IO.puts("")

    :ok = AONCrawler.Storage.ensure_directories()

    chunks = AONCrawler.Storage.load_chunks()

    if Enum.empty?(chunks) do
      IO.puts(:stderr, "No chunks found. Run: mix index")
      exit({:shutdown, 1})
    end

    IO.puts("Loaded #{length(chunks)} chunks")

    max_concurrent =
      Application.get_env(:aoncrawler, :indexer)[:max_concurrent_batches] ||
        System.schedulers_online()

    IO.puts("Processing with #{max_concurrent} concurrent batches...")
    IO.puts("")

    embeddings =
      chunks
      |> Stream.chunk_every(batch_size)
      |> Task.async_stream(&generate_batch_embeddings/1,
        max_concurrent: max_concurrent,
        timeout: :infinity
      )
      |> Stream.map(fn
        {:ok, results} ->
          results

        {:error, reason} ->
          IO.puts(:stderr, "Batch failed: #{inspect(reason)}")
          []
      end)
      |> Enum.flat_map(& &1)

    IO.puts("Generated #{length(embeddings)} embeddings")

    Enum.each(embeddings, &AONCrawler.Storage.append_embedding/1)

    IO.puts("")
    IO.puts("Embedding complete!")
    IO.puts("Run: mix query \"your question\"")
  end

  defp generate_batch_embeddings(chunks) do
    texts = Enum.map(chunks, & &1.text)

    case AONCrawler.Indexer.EmbeddingClient.embed_batch(texts) do
      {:ok, embeddings} ->
        Enum.zip(chunks, embeddings)
        |> Enum.map(fn {chunk, embedding} ->
          %{
            id: UUID.uuid4(),
            chunk_id: chunk.id,
            vector: embedding,
            model:
              Application.get_env(
                :aoncrawler,
                [:indexer, :embedding_model],
                "text-embedding-3-small"
              ),
            token_count: estimate_tokens(chunk.text)
          }
        end)

      {:error, reason} ->
        IO.puts(:stderr, "Embedding failed: #{inspect(reason)}")
        []
    end
  end

  defp estimate_tokens(text) do
    ceil(String.length(text) / 4)
  end
end
