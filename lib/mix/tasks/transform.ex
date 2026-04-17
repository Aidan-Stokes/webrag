defmodule Mix.Tasks.Transform do
  @moduledoc """
  Transforms Protocol Buffer files to JSON for debugging.

  ## Usage

      mix transform

  Reads .pb files and exports to human-readable .json files.
  Deduplicates documents by URL.

  ## Options

      --no-dedup    Skip deduplication step

  ## Examples

      mix transform
      mix transform --no-dedup
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

    :ok = AONCrawler.Storage.ensure_directories()

    if opts[:dedup] do
      IO.puts("Deduplicating documents by URL...")
      AONCrawler.Storage.deduplicate_documents()
      IO.puts("Deduplication complete!")
      IO.puts("")
    end

    IO.puts("Exporting to JSON...")
    AONCrawler.Storage.export_to_json()
    IO.puts("")

    stats = AONCrawler.Storage.stats()
    IO.puts("Data Summary:")
    IO.puts("  Documents: #{stats.documents}")
    IO.puts("  Chunks: #{stats.chunks}")
    IO.puts("  Embeddings: #{stats.embeddings}")
    IO.puts("")
    IO.puts("Transform complete!")
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          dedup: :boolean
        ],
        aliases: [
          d: :dedup
        ]
      )

    Keyword.put_new(opts, :dedup, true)
  end
end
