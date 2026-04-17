defmodule Mix.Tasks.Compact do
  @moduledoc """
  Compacts Protocol Buffer files by removing duplicates.

  ## Usage

      mix compact

  Deduplicates all .pb files (documents, chunks, embeddings).
  This reduces file size by removing duplicate entries.

  ## Options

      --type <type>      Deduplicate only specific type: documents, chunks, embeddings, or all

  ## Examples

      mix compact
      mix compact --type chunks
      mix compact --type embeddings
  """
  use Mix.Task

  @shortdoc "Compact .pb files by removing duplicates"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          type: :string
        ]
      )

    IO.puts("==================")
    IO.puts("Compact Phase - Deduplicating .pb files")
    IO.puts("==================")
    IO.puts("")

    :ok = WebRAG.Storage.ensure_directories()

    type = Keyword.get(opts, :type, "all")

    run_deduplication(type)

    stats = WebRAG.Storage.stats()
    IO.puts("")
    IO.puts("Data Summary:")
    IO.puts("  Documents: #{stats.documents}")
    IO.puts("  Chunks: #{stats.chunks}")
    IO.puts("  Embeddings: #{stats.embeddings}")
    IO.puts("")
    IO.puts("Compact complete!")
  end

  defp run_deduplication(type) do
    case type do
      "documents" ->
        WebRAG.Storage.deduplicate_documents()

      "chunks" ->
        WebRAG.Storage.deduplicate_chunks()

      "embeddings" ->
        WebRAG.Storage.deduplicate_embeddings()

      _ ->
        WebRAG.Storage.deduplicate_all()
    end
  end
end
