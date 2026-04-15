defmodule AONCrawler.Crawler.Worker do
  @moduledoc """
  Worker process for performing HTTP requests to Archives of Nethys.

  Each worker handles a single URL crawl request, including:
  - Fetching the HTML content
  - Extracting links for further crawling
  - Handling errors with appropriate retries
  - Respecting rate limits

  ## Design Decisions

  1. **Stateless Workers**: Workers don't maintain state between requests.
     This simplifies error handling and allows any worker to handle any URL.

  2. **Reuse HTTP Connections**: We use connection pooling through Req to
     reuse TCP connections, improving performance for bulk crawling.

  3. **Comprehensive Error Handling**: We catch and classify errors to enable
     appropriate retry strategies (network errors vs. HTTP errors).

  4. **Response Validation**: We validate responses before returning them,
     ensuring we don't pass malformed data to the parser.

  5. **Link Extraction**: Workers extract internal links from pages to
     enable automatic discovery of related content.

  ## Usage

  Workers are typically spawned by the Coordinator:

      request = %{id: UUID.uuid4(), url: "https://2e.aonprd.com/Actions.aspx?ID=1"}
      {:ok, result} = Worker.execute(request)

  The worker will:
  1. Wait for rate limiter clearance
  2. Fetch the URL
  3. Validate the response
  4. Extract links and content
  5. Return the result
  """

  use GenServer
  require Logger

  alias AONCrawler.Crawler.RateLimiter

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts a worker process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Executes a crawl request synchronously.

  This is the main entry point for performing a crawl. It handles the
  full lifecycle of a request including rate limiting, fetching, and parsing.

  ## Parameters

  - `request` - A map containing `:id` and `:url` keys

  ## Returns

  - `{:ok, result}` on successful crawl
  - `{:error, reason}` on failure
  - `{:retry, reason}` if the request should be retried

  ## Example

      iex> request = %{id: "123", url: "https://2e.aonprd.com/Actions.aspx?ID=1"}
      iex> {:ok, %{html: html, links: links}} = Worker.execute(request)
  """
  @spec execute(map()) :: {:ok, map()} | {:error, term()} | {:retry, term()}
  def execute(request) do
    url = request.url

    Logger.debug("Executing crawl request", url: url, request_id: request.id)

    with :ok <- wait_for_rate_limit(),
         {:ok, response} <- fetch_url(url, request),
         :ok <- validate_response(response),
         {:ok, parsed} <- parse_response(response) do
      {:ok, parsed}
    else
      {:error, :rate_limited} = error ->
        Logger.warning("Rate limited", url: url)
        RateLimiter.record_rate_limit_error(extract_host(url))
        error

      {:error, :http_error, status_code} = error ->
        Logger.warning("HTTP error", url: url, status: status_code)

        if status_code in [429, 500, 502, 503, 504] do
          {:retry, error}
        else
          error
        end

      {:error, _} = error ->
        Logger.error("Crawl failed", url: url, error: inspect(error))
        error

      {:retry, _} = retry ->
        retry
    end
  end

  @doc """
  Fetches a URL and returns the raw response.

  This is useful when you need the raw response for custom processing.
  """
  @spec fetch_url(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fetch_url(url, _request \\ %{}) do
    timeout = Application.get_env(:aoncrawler, [AONCrawler.Crawler, :request_timeout], 30_000)

    headers = [
      {"User-Agent",
       Application.get_env(:aoncrawler, [AONCrawler.Crawler, :user_agent], "AONCrawler/1.0")},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.5"},
      {"Accept-Encoding", "gzip, deflate"},
      {"Connection", "keep-alive"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, %{status: status, body: body, url: url}}

      {:ok, %{status: status}} ->
        {:error, :http_error, status}

      {:error, %{reason: reason}} when reason in [:timeout, :connect_timeout] ->
        {:error, :timeout}

      {:error, %{reason: :econnrefused}} ->
        {:error, :connection_refused}

      {:error, %{reason: reason}} ->
        {:error, {:network_error, reason}}
    end
  rescue
    e in MatchError ->
      {:error, {:request_error, e}}

    e ->
      {:error, {:unexpected_error, e}}
  end

  @doc """
  Parses a response to extract content and links.
  """
  @spec parse_response(map()) :: {:ok, map()} | {:error, term()}
  def parse_response(%{body: nil}) do
    {:error, :no_body}
  end

  def parse_response(response) do
    html = response.body

    with {:ok, document} <- Floki.parse_document(html),
         content <- extract_main_content(document),
         links <- extract_links(document, response.url),
         meta <- extract_metadata(document) do
      {:ok,
       %{
         html: html,
         content: content,
         links: links,
         metadata: meta,
         url: response.url,
         status: response.status
       }}
    else
      {:error, reason} ->
        {:error, {:parse_error, reason}}

      nil ->
        {:error, :no_content}

      _ ->
        {:error, :unknown_parse_error}
    end
  end

  # ============================================================================
  # GenServer Implementation (for stateful workers if needed)
  # ============================================================================

  @impl true
  def init(opts) do
    {:ok,
     %{
       request: nil,
       attempts: 0,
       max_attempts: Keyword.get(opts, :max_attempts, 3)
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:execute, request}, _from, state) do
    result = execute(request)
    {:reply, result, %{state | request: request, attempts: state.attempts + 1}}
  end

  # ============================================================================
  # Internal Functions
  # ============================================================================

  defp wait_for_rate_limit do
    RateLimiter.wait_for_token()
    :ok
  rescue
    e in GenServer.CallError ->
      {:error, :rate_limit_timeout}
  end

  defp validate_response(%{status: status}) when status in 200..299, do: :ok
  defp validate_response(%{status: 429}), do: {:error, :rate_limited}

  defp validate_response(%{status: status}) when status in 500..599,
    do: {:error, :http_error, status}

  defp validate_response(%{status: status}), do: {:error, :http_error, status}
  defp validate_response(_), do: {:error, :invalid_response}

  defp extract_main_content(document) do
    content_selectors = [
      "#main",
      "#ctl00_MainContent_DetailedOutput",
      ".main",
      ".main-content",
      "#content",
      "article.content",
      ".page",
      "main",
      "#page",
      ".mw-parser-output"
    ]

    content =
      Enum.find_value(content_selectors, fn selector ->
        Floki.find(document, selector) |> Floki.text()
      end) || Floki.text(document)

    # Clean up the content
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_links(document, base_url) do
    base_uri = URI.parse(base_url)
    base_host = "#{base_uri.scheme}://#{base_uri.host}"

    Floki.find(document, "a[href]")
    |> Enum.map(fn element ->
      case Floki.attribute(element, "href") do
        [href | _] ->
          case resolve_url(href, base_url) do
            nil ->
              nil

            full_url ->
              text = Floki.text(element) |> String.trim()

              if String.starts_with?(full_url, base_host) and valid_aon_path?(full_url) do
                %{url: full_url, text: text}
              else
                nil
              end
          end

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.url)
  end

  defp extract_metadata(document) do
    title =
      Floki.find(document, "title")
      |> Floki.text()
      |> String.trim()

    description =
      Floki.find(document, "meta[name=description]")
      |> Floki.attribute("content")
      |> List.first() || ""

    keywords =
      Floki.find(document, "meta[name=keywords]")
      |> Floki.attribute("content")
      |> List.first() || ""

    %{title: title, description: description, keywords: keywords}
  end

  defp resolve_url(href, base_url) do
    href = to_string(href) |> String.trim()

    cond do
      href == "" or href == "#" ->
        nil

      String.starts_with?(href, "javascript:") ->
        nil

      String.starts_with?(href, "mailto:") ->
        nil

      String.starts_with?(href, "http://") or String.starts_with?(href, "https://") ->
        href

      String.starts_with?(href, "//") ->
        "https:" <> href

      true ->
        base_uri = URI.parse(base_url)
        base_path = base_uri.path || "/"
        base_dir = Path.dirname(base_path)
        new_path = Path.join(base_dir, href)
        new_path = if String.ends_with?(href, "/"), do: new_path <> "/", else: new_path
        "https://#{base_uri.host}#{new_path}"
    end
    |> then(fn
      nil -> nil
      url -> String.trim_trailing(url, "/")
    end)
  rescue
    e ->
      Logger.error("resolve_url exception",
        href: inspect(href),
        base_url: base_url,
        error: Exception.message(e)
      )

      nil
  end

  defp valid_aon_path?(url) do
    exclude_pages = [
      "Licenses.aspx",
      "Support.aspx",
      "ContactUs.aspx",
      "Contributors.aspx"
    ]

    String.starts_with?(url, "https://2e.aonprd.com/") and
      not Enum.any?(exclude_pages, &String.contains?(url, &1))
  end

  defp extract_host(url) do
    case URI.parse(url) do
      %{host: host} -> host
      _ -> "unknown"
    end
  end
end
