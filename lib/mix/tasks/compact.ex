defmodule Mix.Tasks.Compact do
  @moduledoc """
  Compacts Protocol Buffer files and exports to JSON.

  ## Usage

      mix compact

  Creates .pb files from append mode and exports to JSON for human readability.
  """
  use Mix.Task

  @shortdoc "Compact and export data"

  @impl true
  def run(_args) do
    IO.puts("==================")
    IO.puts("Compaction Phase")
    IO.puts("==================")
    IO.puts("")

    :ok = AONCrawler.Storage.ensure_directories()
    :ok = AONCrawler.Storage.export_to_json()

    source_ids = AONCrawler.Crawler.Source.source_ids()

    Enum.each(source_ids, fn source_id ->
      AONCrawler.Storage.compact_discovered_urls(source_id)
    end)

    stats = AONCrawler.Storage.stats()
    IO.puts("")
    IO.puts("Data Summary:")
    IO.puts("  Documents: #{stats.documents}")
    IO.puts("  Chunks: #{stats.chunks}")
    IO.puts("  Embeddings: #{stats.embeddings}")
    IO.puts("")
    IO.puts("Compaction complete!")
  end
end
