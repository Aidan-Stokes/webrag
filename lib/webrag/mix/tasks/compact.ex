defmodule Mix.Tasks.Compact do
  @moduledoc """
  Compacts Protocol Buffer files by removing duplicates and exporting to JSON.

  ## Usage

      mix compact

  Deduplicates and exports all .pb files to human-readable .json.
  See `mix help transform` for full options.

  ## Options

      --no-dedup         Skip deduplication step
      --dedup-only       Only deduplicate, skip JSON export
      --type <type>      Deduplicate only specific type: documents, chunks, embeddings, or all

  ## Examples

      mix compact
      mix compact --dedup-only
      mix compact --type chunks
  """
  use Mix.Task

  @shortdoc "Compact .pb files"

  @impl true
  def run(args) do
    Mix.Tasks.Transform.run(args)
  end
end
