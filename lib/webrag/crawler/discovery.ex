defmodule WebRAG.Crawler.Discovery do
  @moduledoc """
  Discovers URLs from configured sources.

  Supports multiple sources and enforces scope boundaries to prevent
  crawling outside allowed domains. Uses ETS for parallel discovery deduplication.
  """

  alias WebRAG.Crawler.{Source, RateLimiter}
  alias WebRAG.Storage

  @ets_table :webrag_discovered_urls

  @default_max_urls 100_000
  @default_max_depth :unlimited

  @doc """
  Initializes the ETS table for discovered URL deduplication.
  """
  def init_ets do
    case :ets.info(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [
          :set,
          :public,
          :named_table,
          write_concurrency: true,
          read_concurrency: true
        ])

      _ ->
        :ets.delete_all_objects(@ets_table)
    end
  end

  @doc """
  Discovers URLs from a single source using recursive BFS.

  Uses ETS for O(1) deduplication across parallel workers.
  """
  @spec discover_urls_parallel(Source.t(), non_neg_integer(), keyword()) :: {:ok, [String.t()]}
  def discover_urls_parallel(source, max_concurrent \\ System.schedulers_online(), opts \\ []) do
    init_ets()

    max_urls = Keyword.get(opts, :max_urls, @default_max_urls)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)

    depth_str = if max_depth == :unlimited, do: "∞", else: "#{max_depth}"

    IO.puts(
      "  Starting from #{length(source.seed_urls)} seed URLs (max: #{max_urls}, depth: #{depth_str})"
    )

    IO.puts("")

    _discovered =
      discover_recursive(source.seed_urls, source, max_concurrent, max_urls, max_depth, 0)

    final_count = :ets.info(@ets_table, :size)
    IO.puts("")
    IO.puts("  ✓ Found #{final_count} unique URLs")

    urls = :ets.tab2list(@ets_table) |> Enum.map(fn {url, _} -> url end)
    {:ok, urls}
  end

  defp discover_recursive([], _source, _max_concurrent, _max_urls, _max_depth, _depth) do
    []
  end

  defp discover_recursive(urls, source, max_concurrent, max_urls, max_depth, depth) do
    cond do
      max_depth != :unlimited and depth >= max_depth ->
        IO.puts("  ◦ Max depth reached")
        []

      true ->
        current_count = :ets.info(@ets_table, :size)

        if current_count >= max_urls do
          IO.puts("  ◦ Max URLs limit reached")
          []
        else
          remaining = max_urls - current_count

          IO.write(
            "\r  ◦ Depth #{depth}: scanning #{length(urls)} URLs... (#{current_count} found)     "
          )

          new_urls =
            urls
            |> Enum.take(remaining)
            |> Task.async_stream(
              fn url ->
                case already_discovered?(url) do
                  true ->
                    []

                  false ->
                    mark_discovered(url)
                    links = fetch_and_extract_links_parallel(url, source)
                    Enum.filter(links, &Source.valid_url?(&1, source))
                end
              end,
              max_concurrency: max_concurrent,
              timeout: 60_000
            )
            |> Enum.flat_map(fn
              {:ok, urls} -> urls
              {:error, _} -> []
            end)
            |> Enum.reject(&already_discovered?/1)
            |> Enum.uniq()

          IO.write("\r")

          if Enum.empty?(new_urls) do
            IO.puts("  ✓ No more links to follow - discovery complete")
            []
          else
            discover_recursive(new_urls, source, max_concurrent, max_urls, max_depth, depth + 1)
          end
        end
    end
  end

  @doc """
  Checks if a URL is already discovered (in ETS).
  """
  def already_discovered?(url) do
    :ets.member(@ets_table, url)
  end

  @doc """
  Marks a URL as discovered in ETS.
  """
  def mark_discovered(url) do
    :ets.insert(@ets_table, {url, DateTime.utc_now()})
  end

  @doc """
  Loads previously discovered URLs from storage into ETS.
  """
  @spec load_into_ets(atom()) :: [String.t()]
  def load_into_ets(source_id) do
    init_ets()

    case Storage.load_discovered_urls(source_id) do
      urls when is_list(urls) and length(urls) > 0 ->
        entries = Enum.map(urls, &{&1, DateTime.utc_now()})
        :ets.insert(@ets_table, entries)
        IO.puts("Loaded #{length(urls)} previously discovered URLs")
        urls

      _ ->
        []
    end
  end

  @doc """
  Discovers URLs from the specified sources.

  ## Arguments

    - `sources` - A source struct, atom (source ID), list of source IDs, or `:all`

  ## Examples

      Discovery.discover_urls(:archives_of_nethys)
      Discovery.discover_urls([:archives_of_nethys, :yahoo_finance])
      Discovery.discover_urls(:all)
  """
  @spec discover_urls(atom() | [atom()] | :all, keyword()) :: {:ok, %{atom() => [String.t()]}}
  def discover_urls(sources \\ :all, opts \\ [])

  def discover_urls(:all, opts) do
    source_ids = Source.source_ids()
    discover_urls(source_ids, opts)
  end

  def discover_urls(source_id, opts) when is_atom(source_id) do
    discover_urls([source_id], opts)
  end

  def discover_urls(source_ids, opts) when is_list(source_ids) do
    IO.puts("==================")
    IO.puts("Discovery Phase: Finding URLs from #{length(source_ids)} source(s)...")
    IO.puts("==================")
    IO.puts("")

    Process.sleep(500)

    results =
      Enum.reduce(source_ids, %{}, fn source_id, acc ->
        case Source.get_source(source_id) do
          nil ->
            IO.puts(:stderr, "Unknown source: #{source_id}")
            acc

          source ->
            IO.puts("")
            IO.puts("Discovering from: #{source.name}")
            IO.puts("Base URL: #{source.base_url}")

            case discover_source_urls(source, opts) do
              {:ok, urls} ->
                IO.puts("  Found #{length(urls)} valid URLs")
                Map.put(acc, source_id, urls)
            end
        end
      end)

    total_urls = results |> Map.values() |> Enum.flat_map(& &1) |> Enum.uniq() |> length()

    IO.puts("")
    IO.puts("==================")
    IO.puts("Discovery complete!")
    IO.puts("Total unique URLs: #{total_urls}")
    IO.puts("==================")
    IO.puts("")

    {:ok, results}
  end

  @doc """
  Discovers URLs from a single source.
  """
  @spec discover_source_urls(Source.t(), keyword()) :: {:ok, [String.t()]}
  def discover_source_urls(source, opts \\ []) do
    Source.ensure_data_dir(source)

    all_urls =
      Enum.reduce(source.seed_urls, [], fn seed_url, acc ->
        IO.puts("  Scanning: #{seed_url}")

        case fetch_and_extract_links(seed_url, source, opts) do
          {:ok, urls} ->
            acc ++ urls

          {:error, reason} ->
            IO.puts(:stderr, "    Error: #{inspect(reason)}")
            acc
        end
      end)

    total_found = length(all_urls)

    unique_urls =
      all_urls
      |> Enum.uniq()
      |> Enum.filter(&Source.valid_url?(&1, source))

    in_scope_count = length(unique_urls)
    out_of_scope_count = total_found - in_scope_count

    IO.puts(
      "  Scope control: #{in_scope_count} in-scope, #{out_of_scope_count} out-of-scope (filtered)"
    )

    save_discovered_urls(source, unique_urls)

    {:ok, unique_urls}
  end

  @doc """
  Loads previously discovered URLs for a source.
  """
  @spec load_discovered_urls(atom()) :: [String.t()]
  def load_discovered_urls(source_id) do
    Storage.load_discovered_urls(source_id)
  end

  @doc """
  Saves discovered URLs to storage for a source.
  """
  @spec save_discovered_urls(Source.t(), [String.t()]) :: :ok
  def save_discovered_urls(source, urls) do
    Storage.append_discovered_urls(source.id, urls)
  end

  @doc """
  Loads all discovered URLs from all sources.
  """
  @spec load_all_discovered_urls() :: %{atom() => [String.t()]}
  def load_all_discovered_urls do
    Source.source_ids()
    |> Enum.reduce(%{}, fn source_id, acc ->
      urls = Storage.load_discovered_urls(source_id)
      Map.put(acc, source_id, urls || [])
    end)
  end

  defp fetch_and_extract_links(url, source, _opts) do
    case RateLimiter.wait_for_token() do
      :ok ->
        result =
          Req.get(url,
            redirect: true,
            headers: [{"User-Agent", source.user_agent}]
          )

        RateLimiter.consume()

        case result do
          {:ok, %{status: 200, body: body}} ->
            urls = extract_links_from_html(body, url, source)
            {:ok, urls}

          {:ok, %{status: status}} ->
            {:error, "HTTP #{status}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp extract_links_from_html(html, base_url, source) do
    html
    |> Floki.parse_document()
    |> case do
      {:ok, tree} ->
        Floki.find(tree, "a[href]")
        |> Enum.map(fn {_tag, attrs, _content} ->
          case List.keyfind(attrs, "href", 0) do
            {"href", href} -> Source.resolve_url(href, base_url)
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&Source.within_scope?(&1, source))

      _ ->
        []
    end
  end

  defp fetch_and_extract_links_parallel(url, source) do
    case RateLimiter.wait_for_token() do
      :ok ->
        result =
          Req.get(url,
            redirect: true,
            headers: [{"User-Agent", source.user_agent}]
          )

        RateLimiter.consume()

        case result do
          {:ok, %{status: 200, body: body}} ->
            urls = extract_links_from_html(body, url, source)
            urls

          {:ok, %{status: _status}} ->
            []

          {:error, _reason} ->
            []
        end
    end
  end
end
