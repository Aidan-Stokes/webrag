defmodule Mix.Tasks.Crawl do
  @moduledoc """
  Crawls Archives of Nethys to build a complete rule dataset.

  ## Usage

      mix crawl

  ## Options

      - `--seed` - Starting URL (default: https://2e.aonprd.com/)
      - `--max` - Maximum pages to crawl (default: unlimited)

  ## Examples

      mix crawl
      mix crawl --seed https://2e.aonprd.com/Spells.aspx
      mix crawl --max 10000
  """
  use Mix.Task

  @shortdoc "Crawl AoN for Pathfinder 2e rules"
  @default_seed "https://2e.aonprd.com/"

  @impl true
  def run(args) do
    # Parse options first
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          seed: :string,
          max: :integer
        ],
        aliases: [s: :seed, m: :max]
      )

    seed = Keyword.get(opts, :seed, @default_seed)
    max_pages = Keyword.get(opts, :max, nil)

    # Ensure the application and all dependencies are started
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, _} = Application.ensure_all_started(:aoncrawler)

    # Give processes time to start
    Process.sleep(1000)

    # Initialize ETS table if not exists
    if :ets.info(:aoncrawler_coordinator_state) == :undefined do
      :ets.new(:aoncrawler_coordinator_state, [:set, :named_table, :public])
    else
      # Clear any stale state from previous runs
      :ets.delete_all_objects(:aoncrawler_coordinator_state)
    end

    IO.puts("==================")
    IO.puts("Crawling Archives of Nethys...")
    IO.puts("==================")

    IO.puts("Seed URL: #{seed}")
    IO.puts("Max pages: #{max_pages || "unlimited"}")
    IO.puts("")

    # Start the crawl with persist_state: false for fresh start
    case AONCrawler.Crawler.Coordinator.start_crawl([seed],
           max_concurrent: 20,
           persist_state: false
         ) do
      {:ok, job_id} ->
        IO.puts("Crawl started! Job ID: #{job_id}")
        IO.puts("")
        IO.puts("Monitoring progress (Ctrl+C to stop):")
        IO.puts("")

        # Keep running and display progress
        loop_stats()

      {:error, reason} ->
        IO.puts(:stderr, "Error starting crawl: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp loop_stats do
    Process.sleep(5000)

    stats = AONCrawler.Crawler.Coordinator.get_stats()

    IO.puts(
      "Stats: crawled=#{stats.total_crawled}, failed=#{stats.total_failed}, pending=#{stats.pending}, in_progress=#{stats.in_progress}"
    )

    if stats.status == :completed || stats.status == :stopped do
      IO.puts("")
      IO.puts("Crawl complete! Total: #{stats.total_crawled}, Failed: #{stats.total_failed}")
    else
      loop_stats()
    end
  end
end
