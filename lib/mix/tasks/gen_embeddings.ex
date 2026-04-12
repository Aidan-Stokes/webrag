defmodule Mix.Tasks.GenEmbeddings do
  @moduledoc """
  Generates embeddings for chunked data using Ollama.

  ## Usage

      mix gen_embeddings

  ## Options

      - `--batch-size` - Chunks per batch (default: 10)
      - `--model` - Ollama embedding model (default: mxbai-embed-large)

  ## Example

      mix gen_embeddings
      mix gen_embeddings --batch-size 20
  """
  use Mix.Task

  @shortdoc "Generate embeddings with Ollama"

  @batch_size 10
  @default_model "mxbai-embed-large"

  @impl true
  def run(args) do
    IO.puts("==================")
    IO.puts("Generating embeddings with Ollama...")
    IO.puts("==================")

    # Parse options
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          batch_size: :integer,
          model: :string
        ],
        aliases: [b: :batch_size, m: :model]
      )

    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    model = Keyword.get(opts, :model, @default_model)

    # Initialize database
    AONCrawler.DB.init()

    # Check Ollama
    unless AONCrawler.LLM.Ollama.available?() do
      IO.puts(:stderr, "")
      IO.puts(:stderr, "ERROR: Ollama is not running!")
      IO.puts(:stderr, "")
      IO.puts(:stderr, "Please start Ollama first:")
      IO.puts(:stderr, "  ollama serve")
      IO.puts(:stderr, "")
      IO.puts(:stderr, "Then in another terminal, pull the model:")
      IO.puts(:stderr, "  ollama pull #{model}")
      exit({:shutdown, 1})
    end

    # Check models
    IO.puts("Checking Ollama models...")
    {:ok, models} = AONCrawler.LLM.Ollama.models()
    model_names = Enum.map(models, & &1["name"])

    # Handle both "mxbai-embed-large" and "mxbai-embed-large:latest"
    model_available =
      Enum.any?(model_names, fn name ->
        name == model || name == "#{model}:latest"
      end)

    if model_available do
      IO.puts("Model #{model} is available")
    else
      IO.puts(:stderr, "WARNING: Model #{model} not found locally")
      IO.puts(:stderr, "Available: #{Enum.join(model_names, ", ")}")
      IO.puts(:stderr, "")
      IO.puts(:stderr, "Pull the model with:")
      IO.puts(:stderr, "  ollama pull #{model}")
      exit({:shutdown, 1})
    end

    # Get unembedded chunks
    chunks = AONCrawler.DB.get_unembedded_chunks()
    total = length(chunks)

    if total == 0 do
      IO.puts("No chunks need embeddings!")
      stats = AONCrawler.DB.stats()
      IO.puts("Total chunks: #{stats.chunks}, embeddings: #{stats.embeddings}")
      :ok
    else
      IO.puts("Found #{total} chunks without embeddings")
      IO.puts("Processing in batches of #{batch_size}...")

      do_generate(chunks, model, batch_size)
    end
  end

  defp do_generate(chunks, model, batch_size) do
    total = length(chunks)
    total_batches = div(total, batch_size) + 1

    _processed =
      chunks
      |> Enum.chunk_every(batch_size)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {batch, batch_index}, acc ->
        IO.write("\rBatch #{batch_index + 1}/#{total_batches} (#{acc}/#{total} chunks)...")

        texts = Enum.map(batch, fn chunk -> chunk["content"] end)

        case AONCrawler.LLM.Ollama.embed_batch(texts, model: model) do
          {:ok, embeddings} ->
            Enum.zip(batch, embeddings)
            |> Enum.each(fn {chunk, embedding} ->
              AONCrawler.DB.save_embedding(%{
                "id" => UUID.uuid4(),
                "chunk_id" => chunk["id"],
                "vector" => embedding,
                "model" => model
              })
            end)

            acc + length(batch)

          {:error, reason} ->
            IO.puts(:stderr, "\nError: #{inspect(reason)}")
            acc
        end
      end)

    IO.puts("")
    IO.puts("")

    stats = AONCrawler.DB.stats()

    IO.puts("==================")
    IO.puts("Done! Database stats:")
    IO.puts("  Documents: #{stats.documents}")
    IO.puts("  Chunks: #{stats.chunks}")
    IO.puts("  Embeddings: #{stats.embeddings}")
    IO.puts("==================")
  end
end
