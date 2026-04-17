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
  require Logger

  @shortdoc "Generate vector embeddings"

  @default_batch_size 20

  @progress_ets :webrag_embed_progress

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:webrag)

    # Check if Ollama is available
    unless WebRAG.LLM.Ollama.available?() do
      IO.puts(:stderr, "")
      IO.puts(:stderr, "✗ Ollama is not available at localhost:11434")
      IO.puts(:stderr, "")
      IO.puts("Please ensure Ollama is running:")
      IO.puts("  1. Install Ollama: https://ollama.ai")
      IO.puts("  2. Start Ollama: ollama serve")
      IO.puts("  3. Pull a model: ollama pull mxbai-embed-large")
      IO.puts("")
      exit({:shutdown, 1})
    end

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

    :ok = WebRAG.Storage.ensure_directories()

    chunks = WebRAG.Storage.load_chunks()

    if Enum.empty?(chunks) do
      IO.puts(:stderr, "No chunks found. Run: mix index")
      exit({:shutdown, 1})
    end

    IO.puts("Loaded #{length(chunks)} chunks")

    max_concurrent =
      Application.get_env(:webrag, :indexer)[:max_concurrent_batches] ||
        System.schedulers_online()

    batches = Enum.chunk_every(chunks, batch_size)
    total_batches = length(batches)

    if :ets.info(@progress_ets) == :undefined do
      :ets.new(@progress_ets, [:set, :named_table, :public])
    else
      :ets.delete_all_objects(@progress_ets)
    end

    :ets.insert(@progress_ets, {:stats, 0, 0})

    IO.puts("Processing with #{max_concurrent} concurrent batches...")
    IO.puts("")

    progress_task =
      spawn(fn ->
        loop_embed_progress(total_batches)
      end)

    embeddings =
      batches
      |> Task.async_stream(
        fn batch ->
          case generate_batch_embeddings(batch) do
            [] ->
              :ets.update_counter(@progress_ets, :stats, {3, 1})
              []

            results ->
              :ets.update_counter(@progress_ets, :stats, {2, 1})
              results
          end
        end,
        max_concurrent: max_concurrent,
        timeout: :infinity
      )
      |> Stream.map(fn
        {:ok, results} ->
          results

        {:error, reason} ->
          Logger.error("Batch embedding failed: #{inspect(reason)}")
          :ets.update_counter(@progress_ets, :stats, {3, 1})
          []
      end)
      |> Enum.flat_map(& &1)

    send(progress_task, :stop)

    IO.puts("Generated #{length(embeddings)} embeddings")

    Enum.each(embeddings, &WebRAG.Storage.append_embedding/1)

    IO.puts("")
    IO.puts("Embedding complete!")
    IO.puts("Run: mix query \"your question\"")
  end

  defp generate_batch_embeddings(chunks) do
    texts = Enum.map(chunks, & &1.text)

    case WebRAG.Indexer.EmbeddingClient.embed_batch(texts) do
      {:ok, embeddings} ->
        Enum.zip(chunks, embeddings)
        |> Enum.map(fn {chunk, embedding} ->
          %{
            id: UUID.uuid4(),
            chunk_id: chunk.id,
            vector: embedding,
            model:
              Application.get_env(
                :webrag,
                [:indexer, :embedding_model],
                "mxbai-embed-large"
              ),
            token_count: estimate_tokens(chunk.text)
          }
        end)

      {:error, reason} ->
        Logger.error("Embedding failed: #{inspect(reason)}")
        []

      other ->
        Logger.error("Unexpected response: #{inspect(other)}")
        []
    end
  end

  defp estimate_tokens(text) do
    ceil(String.length(text) / 4)
  end

  defp loop_embed_progress(total_batches) do
    receive do
      :stop -> :ok
    after
      500 ->
        [{:stats, completed, failed}] = :ets.lookup(@progress_ets, :stats)
        percent = completed / total_batches

        bar_width = 30
        filled = round(bar_width * percent)
        bar = String.duplicate("█", filled) <> String.duplicate("░", bar_width - filled)

        percent_str = :io_lib.format("~.1f", [percent * 100.0]) |> IO.chardata_to_string()

        IO.write(
          "\r[#{bar}] #{percent_str}% | Completed: #{completed}/#{total_batches} | Failed: #{failed}  "
        )

        loop_embed_progress(total_batches)
    end
  end
end
