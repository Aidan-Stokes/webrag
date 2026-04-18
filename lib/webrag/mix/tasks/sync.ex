defmodule Mix.Tasks.Sync do
  @moduledoc """
  Complete sync pipeline: discover + crawl + index + embed.

  Runs all phases sequentially to update the RAG system with new content.

  ## Usage

      mix sync

  ## Options

      - `--dry-run` - Only show what would be done without executing
      - `--incremental` - Only process new content (skips already-processed)

  ## Examples

      # Full sync
      mix sync

      # Dry run to see what would be updated
      mix sync --dry-run

      # Incremental: only new documents and embeddings
      mix sync --incremental
  """
  use Mix.Task
  require Logger

  @shortdoc "Complete sync: discover + crawl + index + embed"

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:webrag)

    {opts, _, _} = OptionParser.parse(args, switches: [dry_run: :boolean, incremental: :boolean])

    dry_run = Keyword.get(opts, :dry_run, false)
    incremental = Keyword.get(opts, :incremental, false)

    IO.puts("==================")
    IO.puts("WebRAG Sync Pipeline")
    IO.puts("==================")

    IO.puts(
      "Mode: #{if dry_run, do: "DRY RUN (no changes)", else: if(incremental, do: "INCREMENTAL", else: "FULL")}}"
    )

    IO.puts("")

    if dry_run do
      IO.puts("Dry run - showing what would be done:")
    end

    # Phase 1: Discover new URLs
    IO.puts("Phase 1: Discovering URLs...")

    if not dry_run do
      Mix.Tasks.Discover.run([])
    end

    # Phase 2: Crawl
    IO.puts("Phase 2: Crawling...")

    if not dry_run do
      Mix.Tasks.Crawl.run([])
    end

    # Phase 3: Index (chunk)
    IO.puts("Phase 3: Indexing...")
    index_args = if incremental, do: ["--only-new"], else: []

    if not dry_run do
      Mix.Tasks.Index.run(index_args)
    end

    # Phase 4: Embed
    IO.puts("Phase 4: Embedding...")
    embed_args = if incremental, do: ["--only-missing"], else: []

    if not dry_run do
      Mix.Tasks.Embed.run(embed_args)
    end

    IO.puts("")
    IO.puts("==================")
    IO.puts("Sync complete!")
    IO.puts("==================")
    IO.puts("")
    IO.puts("Run a query to test:")
    IO.puts("  mix query \"your question\"")
  end
end
