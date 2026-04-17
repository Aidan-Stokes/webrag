defmodule Mix.Tasks.Crawl do
  require Logger
  alias WebRAG.UI

  @moduledoc """
  Crawls discovered URLs and extracts content.

  ## Usage

      mix crawl

  ## Options

      - `--source <name>` - Source ID from config. Defaults to first source.
      - `--max <n>` - Maximum pages to crawl. Default: unlimited.
      - `--verbose` - Show all log messages (warnings, retries).

  ## Examples

      mix crawl --source my_source
      mix crawl --max 1000
      mix crawl --verbose
  """
  use Mix.Task

  @shortdoc "Crawl discovered URLs"

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, _} = Application.ensure_all_started(:webrag)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          source: :string,
          max: :integer,
          verbose: :boolean
        ],
        aliases: [m: :max, v: :verbose]
      )

    log_level = if opts[:verbose], do: :warning, else: :error
    Logger.configure(level: log_level)

    source_id =
      case opts[:source] do
        nil ->
          source_ids = WebRAG.Crawler.Source.source_ids()

          case source_ids do
            [] ->
              IO.puts(:stderr, "No sources configured. Run mix discover first.")
              exit({:shutdown, 1})

            [first | _] ->
              first
          end

        source_str ->
          String.to_existing_atom(source_str)
      end

    max_pages = opts[:max]

    if :ets.info(:webrag_coordinator_state) == :undefined do
      :ets.new(:webrag_coordinator_state, [:set, :named_table, :public])
    else
      :ets.delete_all_objects(:webrag_coordinator_state)
    end

    source = WebRAG.Crawler.Source.get_source(source_id)
    discovered_urls = WebRAG.Storage.load_discovered_urls(source_id)

    if Enum.empty?(discovered_urls) do
      IO.puts(:stderr, "No discovered URLs found for #{source.name}")
      IO.puts(:stderr, "Run: mix discover --source #{source_id}")
      exit({:shutdown, 1})
    end

    already_crawled = WebRAG.Storage.crawled_urls()

    urls_to_crawl =
      discovered_urls
      |> Enum.map(&WebRAG.Crawler.Source.normalize_url/1)
      |> Enum.reject(&MapSet.member?(already_crawled, &1))
      |> Enum.reject(&invalid_url?/1)
      |> Enum.reject(&WebRAG.Crawler.Source.blocklisted?/1)
      |> Enum.reject(&WebRAG.Crawler.Source.has_invalid_chars?/1)
      |> Enum.uniq()

    invalid_count =
      length(discovered_urls) - length(urls_to_crawl)

    IO.puts(
      "Found #{length(discovered_urls)} discovered URLs, #{length(urls_to_crawl)} new to crawl (#{invalid_count} invalid filtered)"
    )

    IO.puts("")

    urls_to_crawl =
      if max_pages do
        Enum.take(urls_to_crawl, max_pages)
      else
        urls_to_crawl
      end

    max_concurrent =
      Application.get_env(:webrag, :max_concurrent) ||
        System.schedulers_online()

    UI.write_header("CRAWL PHASE", [
      {"Source", source.name},
      {"Discovered URLs", length(discovered_urls)},
      {"Already Crawled", MapSet.size(already_crawled)},
      {"To Crawl", length(urls_to_crawl)},
      {"Max Concurrent", max_concurrent}
    ])

    IO.puts("")

    case WebRAG.Crawler.Coordinator.start_crawl(urls_to_crawl,
           max_concurrent: max_concurrent,
           persist_state: false
         ) do
      {:ok, _job_id} ->
        loop_stats()

      {:error, reason} ->
        IO.puts(:stderr, "Error starting crawl: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp loop_stats do
    Process.sleep(1000)

    stats = WebRAG.Crawler.Coordinator.get_stats()

    completed = stats.total_crawled
    pending = stats.pending
    total = completed + pending
    percent = if total > 0, do: completed / total, else: 0

    bar_width = 30
    filled = round(bar_width * percent)
    bar = String.duplicate("█", filled) <> String.duplicate("░", bar_width - filled)

    percent_str = :io_lib.format("~.1f", [percent * 100.0]) |> IO.chardata_to_string()

    IO.write(
      "\r[#{bar}] #{percent_str}% | Crawled: #{completed} | Failed: #{stats.total_failed} | Pending: #{pending}  "
    )

    if stats.status == :completed || stats.status == :stopped do
      IO.puts("")
      IO.puts("")
      UI.separator()
      IO.puts("  ✓ Crawl complete!")
      IO.puts("    Crawled: #{stats.total_crawled}")
      IO.puts("    Failed: #{stats.total_failed}")
      IO.puts("")
    else
      loop_stats()
    end
  end

  defp invalid_url?(url) do
    String.contains?(url, "__doPostBack") or
      String.contains?(url, "void(") or
      String.contains?(url, "(") or
      String.contains?(url, ";") or
      String.contains?(url, <<92>>) or
      (String.contains?(url, "@") and
         String.split(url, "@") |> Enum.at(1) |> String.contains?("."))
  end
end
