defmodule Mix.Tasks.Discover do
  require Logger
  alias WebRAG.Storage
  alias WebRAG.UI
  alias WebRAG.Network

  @moduledoc """
  Discovers URLs from configured sources.

  ## Usage

      mix discover

  ## Options

      - `--source <name>` - Source ID from config. Use 'all' for all. Defaults to first.
      - `--base-url <url>` - Base URL for custom source. Use with --domains.
      - `--domains <domains>` - Comma-separated allowed domains (required for custom).
      - `--name <name>` - Human-readable name for custom source.
      - `--seed <url>` - Starting URL(s). Can be repeated.
      - `--depth <n>` - Maximum crawl depth (default: unlimited).
      - `--max-urls <n>` - Maximum URLs to discover (default: 50000).
      - `--resume` - Resume from saved state if available.

  ## Examples

      mix discover --source my_source
      mix discover --source all
      mix discover --base-url https://example.com --domains example.com,www.example.com
      mix discover --depth 15 --max-urls 100000
      mix discover --resume
  """
  use Mix.Task

  @shortdoc "Discover URLs from sources"

  @default_max_urls 50_000
  @default_max_depth :unlimited

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, _} = Application.ensure_all_started(:webrag)

    # Start connectivity monitor
    if !Process.whereis(WebRAG.Network.ConnectivityMonitor) do
      {:ok, _} = WebRAG.Network.ConnectivityMonitor.start_link([])
    end

    # Check connectivity before starting
    if !Network.HealthCheck.online?() do
      IO.puts(:stderr, "")
      IO.puts(:stderr, "⚠ Network appears to be offline")
      IO.puts(:stderr, "")
      IO.puts("Attempting to wait for connectivity...")

      case Network.HealthCheck.wait_until_online(timeout: :timer.minutes(2)) do
        :ok ->
          IO.puts("✓ Network connectivity restored")

        {:error, :timeout} ->
          IO.puts(:stderr, "")
          IO.puts(:stderr, "✗ Network did not come back online. Discovery may fail.")
          IO.puts("Run 'mix network.status' to check connectivity.")
          IO.puts("")
      end
    end

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          source: :string,
          base_url: :string,
          domains: :string,
          name: :string,
          seed: [:string, :keep],
          depth: :integer,
          max_urls: :integer,
          resume: :boolean
        ]
      )

    source =
      cond do
        opts[:base_url] && opts[:domains] ->
          WebRAG.Crawler.Source.from_cli(
            id: :custom,
            name: opts[:name] || "Custom Source",
            base_url: opts[:base_url],
            allowed_domains: WebRAG.Crawler.Source.parse_domains(opts[:domains]),
            seed_urls: Keyword.get_values(opts, :seed) ++ [opts[:base_url]]
          )

        opts[:source] == "all" ->
          nil

        opts[:source] ->
          source_id = String.to_existing_atom(opts[:source])

          case WebRAG.Crawler.Source.get_source(source_id) do
            nil ->
              IO.puts(:stderr, "Unknown source: #{source_id}")
              IO.puts("Available sources: #{inspect(WebRAG.Crawler.Source.source_ids())}")
              exit({:shutdown, 1})

            source ->
              source
          end

        true ->
          source_ids = WebRAG.Crawler.Source.source_ids()

          case source_ids do
            [] ->
              IO.puts(:stderr, "No sources configured. Add sources to config/sources.exs")
              exit({:shutdown, 1})

            [first | _] ->
              WebRAG.Crawler.Source.get_source(first)
          end
      end

    max_concurrent =
      Application.get_env(:webrag, :max_concurrent) ||
        System.schedulers_online()

    max_urls = opts[:max_urls] || @default_max_urls
    max_depth = if opts[:depth], do: opts[:depth], else: @default_max_depth

    depth_str = if max_depth == :unlimited, do: "unlimited", else: "#{max_depth}"

    UI.write_header("DISCOVERY PHASE", [
      {"Concurrent", max_concurrent},
      {"Max URLs", max_urls},
      {"Max Depth", depth_str}
    ])

    if source do
      source_id = source.id || :custom
      IO.puts("Source: #{source.name} (#{source.base_url})")
      IO.puts("Domains: #{Enum.join(source.allowed_domains, ", ")}")
      IO.puts("")

      urls =
        if opts[:resume] == true and WebRAG.Crawler.Discovery.has_saved_state?(source_id) do
          case WebRAG.Crawler.Discovery.resume_discovery(source, max_concurrent,
                 max_urls: max_urls,
                 max_depth: max_depth
               ) do
            {:ok, urls} ->
              urls

            {:error, :not_found} ->
              IO.puts("No saved state found, starting fresh...")

              {:ok, urls} =
                WebRAG.Crawler.Discovery.discover_urls_parallel(source, max_concurrent,
                  max_urls: max_urls,
                  max_depth: max_depth
                )

              urls
          end
        else
          {:ok, urls} =
            WebRAG.Crawler.Discovery.discover_urls_parallel(source, max_concurrent,
              max_urls: max_urls,
              max_depth: max_depth
            )

          urls
        end

      IO.puts("")
      UI.separator()
      IO.puts("")
      IO.puts("  ✓ Discovery complete: #{length(urls)} URLs found")

      Storage.append_discovered_urls(source_id, urls)
      IO.puts("  ✓ Saved to data/sources/#{source_id}/")
      IO.puts("")
    else
      discover_all_sources(max_concurrent, max_urls: max_urls, max_depth: max_depth)
    end
  end

  defp discover_all_sources(max_concurrent, opts) do
    source_ids = WebRAG.Crawler.Source.source_ids()

    results =
      Enum.reduce(source_ids, %{}, fn source_id, acc ->
        source = WebRAG.Crawler.Source.get_source(source_id)
        IO.puts("Source: #{source.name}")

        {:ok, urls} =
          WebRAG.Crawler.Discovery.discover_urls_parallel(source, max_concurrent, opts)

        Storage.append_discovered_urls(source_id, urls)
        Map.put(acc, source_id, urls)
      end)

    total = results |> Map.values() |> Enum.flat_map(& &1) |> Enum.uniq() |> length()

    IO.puts("")
    UI.separator()
    IO.puts("  Discovery complete! Total unique URLs: #{total}")
    IO.puts("")
  end
end
