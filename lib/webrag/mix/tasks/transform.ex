defmodule Mix.Tasks.Transform do
  @moduledoc """
  Transforms Protocol Buffer files to JSON for debugging.

  ## Usage

      mix transform

  Reads .pb files and exports to human-readable .json files.
  Deduplicates all data types (documents, chunks, embeddings).

  ## Options

      --no-dedup         Skip deduplication step
      --dedup-only       Only deduplicate, skip JSON export
      --type <type>      Deduplicate only specific type: documents, chunks, embeddings, or all

  ## Examples

      mix transform
      mix transform --no-dedup
      mix transform --dedup-only
      mix transform --type chunks
  """
  use Mix.Task

  @shortdoc "Transform .pb to JSON"

  @impl true
  def run(args) do
    opts = parse_args(args)

    IO.puts("==================")
    IO.puts("Transform Phase")
    IO.puts("==================")
    IO.puts("")

    :ok = WebRAG.Storage.ensure_directories()

    if opts[:dedup_only] do
      IO.puts("Running deduplication only...")
      run_deduplication(opts[:type])
    else
      if opts[:dedup] do
        IO.puts("Deduplicating data...")
        run_deduplication(opts[:type])
        IO.puts("")
      end

      IO.puts("Exporting to JSON...")
      WebRAG.Storage.export_to_json()
      IO.puts("")
    end

    stats = WebRAG.Storage.stats()
    IO.puts("Data Summary:")
    IO.puts("  Documents: #{stats.documents}")
    IO.puts("  Chunks: #{stats.chunks}")
    IO.puts("  Embeddings: #{stats.embeddings}")
    IO.puts("")
    IO.puts("Transform complete!")
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

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          dedup: :boolean,
          dedup_only: :boolean,
          type: :string
        ],
        aliases: [
          d: :dedup
        ]
      )

    opts
    |> Keyword.put_new(:dedup, true)
    |> Keyword.put_new(:type, "all")
  end
end
