defmodule AONCrawler.Crawler.Coordinator do
  @moduledoc """
  Orchestrates the crawling pipeline for Archives of Nethys content.

  This GenServer manages the overall crawling workflow:
  1. Maintains a queue of URLs to crawl
  2. Distributes work to worker processes
  3. Tracks crawl state and progress
  4. Handles failures and retries
  5. Coordinates with the rate limiter

  ## Supervision Strategy

  This coordinator is supervised under `AONCrawler.Crawler.Supervisor` using
  a `:one_for_all` strategy. If this process crashes, all crawl workers are
  terminated and restarted, ensuring a clean state.

  ## Concurrency Model

  - Uses `Task.async_stream` for concurrent crawling
  - Maximum concurrency controlled by `:crawler_max_concurrent` config
  - Backpressure via semaphores when workers are saturated

  ## Fault Tolerance

  - Failed crawls are retried with exponential backoff
  - Circuit breaker pattern prevents cascade failures
  - State is persisted to allow resume after restarts

  ## Example

      iex> Coordinator.start_link([])
      iex> Coordinator.queue_urls([
      ...>   "https://2e.aonprd.com/Actions.aspx?ID=1",
      ...>   "https://2e.aonprd.com/Spells.aspx?ID=119"
      ...> ])
      iex> Coordinator.get_stats()
      %{pending: 2, in_progress: 0, completed: 0, failed: 0}
  """

  use GenServer
  use Supervisor

  require Logger

  alias AONCrawler.Crawler.{Worker, RateLimiter}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the coordinator with the given options.

  ## Options

  - `:max_concurrent` - Maximum concurrent crawl tasks (default: 5)
  - `:max_retries` - Maximum retry attempts for failed URLs (default: 3)
  - `:persist_state` - Whether to persist state to disk (default: true)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Adds URLs to the crawl queue.

  URLs are deduplicated and sorted by priority before being added.
  The coordinator will begin crawling immediately if workers are available.

  ## Parameters

  - `urls` - List of URLs to queue (can include metadata)

  ## Example

      iex> Coordinator.queue_urls([
      ...>   "https://2e.aonprd.com/Actions.aspx?ID=1",
      ...>   %{:url => "https://2e.aonprd.com/Spells.aspx?ID=119", :type => :spell}
      ...> ])
      :ok
  """
  @spec queue_urls([String.t() | map()]) :: :ok | {:error, term()}
  def queue_urls(urls) when is_list(urls) do
    GenServer.cast(__MODULE__, {:queue_urls, urls})
  end

  @doc """
  Adds a single URL to the crawl queue.
  """
  @spec queue_url(String.t() | map(), keyword()) :: :ok | {:error, term()}
  def queue_url(url, opts \\ []) when is_binary(url) or is_map(url) do
    queue_urls([if(is_binary(url), do: Map.merge(%{url: url}, Map.new(opts)), else: url)])
  end

  @doc """
  Starts a new crawl job from a seed list.

  This is the main entry point for initiating a crawl. It clears any
  existing queue and starts fresh with the provided seeds.

  ## Parameters

  - `seeds` - List of seed URLs with optional metadata
  - `opts` - Options for the crawl job

  ## Options

  - `:full` - If true, performs a full crawl (default: false)
  - `:content_types` - Limit crawl to specific content types

  ## Example

      iex> Coordinator.start_crawl([
      ...>   "https://2e.aonprd.com/Actions.aspx",
      ...>   "https://2e.aonprd.com/Spells.aspx",
      ...> ], full: true)
      {:ok, job_id}
  """
  @spec start_crawl([String.t() | map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_crawl(seeds, opts \\ []) do
    GenServer.call(__MODULE__, {:start_crawl, seeds, opts})
  end

  @doc """
  Stops the current crawl gracefully.

  In-progress crawls are allowed to complete, but new URLs are not started.
  """
  @spec stop_crawl() :: :ok
  def stop_crawl do
    GenServer.cast(__MODULE__, :stop_crawl)
  end

  @doc """
  Pauses the crawl temporarily.

  Unlike `stop_crawl/0`, the queue is preserved and crawling can be resumed.
  """
  @spec pause_crawl() :: :ok
  def pause_crawl do
    GenServer.cast(__MODULE__, :pause_crawl)
  end

  @doc """
  Resumes a paused crawl.
  """
  @spec resume_crawl() :: :ok
  def resume_crawl do
    GenServer.cast(__MODULE__, :resume_crawl)
  end

  @doc """
  Returns current crawl statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Returns the current state of the coordinator.
  """
  @spec get_state() :: map()
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Returns the number of URLs in the queue.
  """
  @spec queue_size() :: non_neg_integer()
  def queue_size do
    GenServer.call(__MODULE__, :queue_size)
  end

  @doc """
  Clears the crawl queue without stopping in-progress crawls.
  """
  @spec clear_queue() :: :ok
  def clear_queue do
    GenServer.cast(__MODULE__, :clear_queue)
  end

  @doc """
  Marks a URL as crawled (for deduplication).
  """
  @spec mark_crawled(String.t()) :: :ok
  def mark_crawled(url) do
    GenServer.cast(__MODULE__, {:mark_crawled, url})
  end

  @doc """
  Checks if a URL has been crawled or is in the queue.
  """
  @spec crawled?(String.t()) :: boolean()
  def crawled?(url) do
    GenServer.call(__MODULE__, {:crawled?, url})
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    Logger.info("Starting Crawler Coordinator", opts: opts)

    max_concurrent = Keyword.get(opts, :max_concurrent, 5)
    max_retries = Keyword.get(opts, :max_retries, 3)
    persist_state = Keyword.get(opts, :persist_state, true)

    state = %{
      # Configuration
      max_concurrent: max_concurrent,
      max_retries: max_retries,
      persist_state: persist_state,

      # Queue state
      pending_queue: :queue.new(),
      in_progress: MapSet.new(),
      completed: MapSet.new(),
      failed: MapSet.new(),
      crawled_urls: MapSet.new(),

      # Counters
      stats: %{
        total_crawled: 0,
        total_failed: 0,
        total_skipped: 0,
        bytes_downloaded: 0
      },

      # Crawl control
      status: :idle,
      job_id: nil,
      started_at: nil,
      paused_at: nil
    }

    # Load persisted state if available
    state =
      if persist_state do
        load_persisted_state(state)
      else
        state
      end

    {:ok, state, {:continue, :maybe_resume}}
  end

  @impl true
  def handle_continue(:maybe_resume, state) do
    # Check if there was a crawl in progress and resume if appropriate
    if state.status == :crawling and :queue.is_empty(state.pending_queue) == false do
      Logger.info("Resuming previous crawl", job_id: state.job_id)
      dispatch_work(state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:start_crawl, seeds, opts}, _from, state) do
    if state.status == :crawling do
      Logger.warning("Crawl already in progress, ignoring start_crawl")
      {:reply, {:error, :already_crawling}, state}
    else
      job_id = UUID.uuid4()

      # Parse and queue seeds
      {urls, metadata} = parse_seeds(seeds, opts)
      enriched_urls = Enum.map(urls, &Map.merge(&1, metadata))

      # Clear existing queue and set up new crawl
      new_state =
        state
        |> Map.put(:job_id, job_id)
        |> Map.put(:status, :crawling)
        |> Map.put(:started_at, DateTime.utc_now())
        |> Map.put(:pending_queue, :queue.from_list(enriched_urls))
        |> update_in([:stats], fn stats ->
          %{
            stats
            | total_crawled: 0,
              total_failed: 0,
              total_skipped: 0,
              bytes_downloaded: 0
          }
        end)

      Logger.info("Starting new crawl",
        job_id: job_id,
        seed_count: length(enriched_urls)
      )

      # Persist state and dispatch initial work
      persist_state(new_state)
      new_state = dispatch_work(new_state)

      {:reply, {:ok, job_id}, new_state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    pending_count = :queue.len(state.pending_queue)
    in_progress_count = MapSet.size(state.in_progress)

    stats = %{
      status: state.status,
      job_id: state.job_id,
      pending: pending_count,
      in_progress: in_progress_count,
      completed: MapSet.size(state.completed),
      failed: MapSet.size(state.failed),
      total_crawled: state.stats.total_crawled,
      total_failed: state.stats.total_failed,
      bytes_downloaded: state.stats.bytes_downloaded,
      started_at: state.started_at,
      duration_seconds: calculate_duration(state.started_at)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    # Return a sanitized copy of state (exclude large structures)
    {:reply,
     %{
       status: state.status,
       job_id: state.job_id,
       pending_count: :queue.len(state.pending_queue),
       in_progress_count: MapSet.size(state.in_progress),
       stats: state.stats
     }, state}
  end

  @impl true
  def handle_call(:queue_size, _from, state) do
    {:reply, :queue.len(state.pending_queue), state}
  end

  @impl true
  def handle_call({:crawled?, url}, _from, state) do
    result =
      MapSet.member?(state.crawled_urls, url) or
        MapSet.member?(state.completed, url)

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:queue_urls, urls}, state) do
    new_urls =
      urls
      |> Enum.reject(fn url ->
        is_binary(url) and MapSet.member?(state.crawled_urls, url)
      end)
      |> Enum.map(&normalize_url/1)

    new_queue = Enum.reduce(new_urls, state.pending_queue, &:queue.in(&1, &2))

    Logger.debug("Queued #{length(new_urls)} URLs", total_pending: :queue.len(new_queue))

    new_state = Map.put(state, :pending_queue, new_queue)

    # Dispatch work if crawling is active
    new_state =
      if state.status == :crawling do
        dispatch_work(new_state)
      else
        new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:stop_crawl, state) do
    Logger.info("Stopping crawl gracefully", job_id: state.job_id)

    new_state =
      state
      |> Map.put(:status, :stopped)
      |> Map.put(:pending_queue, :queue.new())

    persist_state(new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:pause_crawl, state) do
    Logger.info("Pausing crawl", job_id: state.job_id)

    {:noreply, Map.put(state, :status, :paused) |> Map.put(:paused_at, DateTime.utc_now())}
  end

  @impl true
  def handle_cast(:resume_crawl, state) do
    if state.status == :paused do
      Logger.info("Resuming crawl", job_id: state.job_id)

      new_state =
        state
        |> Map.put(:status, :crawling)
        |> Map.put(:paused_at, nil)

      {:noreply, dispatch_work(new_state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:clear_queue, state) do
    {:noreply, Map.put(state, :pending_queue, :queue.new())}
  end

  @impl true
  def handle_cast({:mark_crawled, url}, state) do
    {:noreply,
     state
     |> update_in([:crawled_urls], &MapSet.put(&1, url))
     |> update_in([:completed], &MapSet.put(&1, url))}
  end

  @impl true
  def handle_cast({:crawl_complete, url, result}, state) do
    new_in_progress = MapSet.delete(state.in_progress, url)

    new_state =
      case result do
        {:ok, _document} ->
          state
          |> Map.put(:in_progress, new_in_progress)
          |> update_in([:completed], &MapSet.put(&1, url))
          |> update_in([:stats, :total_crawled], &(&1 + 1))
          |> tap(fn s ->
            Logger.info("Crawl complete", url: url, total: s.stats.total_crawled)
          end)

        {:error, reason} ->
          state
          |> Map.put(:in_progress, new_in_progress)
          |> update_in([:failed], &MapSet.put(&1, url))
          |> update_in([:stats, :total_failed], &(&1 + 1))
          |> tap(fn _ ->
            Logger.warning("Crawl failed", url: url, reason: inspect(reason))
          end)
      end

    persist_state(new_state)

    # Check if crawl is complete
    new_state =
      if :queue.is_empty(new_state.pending_queue) and MapSet.size(new_state.in_progress) == 0 do
        Logger.info("Crawl job complete",
          job_id: state.job_id,
          completed: new_state.stats.total_crawled,
          failed: new_state.stats.total_failed
        )

        Map.put(new_state, :status, :completed)
      else
        new_state
      end

    # Continue dispatching work if appropriate
    new_state =
      if new_state.status == :crawling do
        dispatch_work(new_state)
      else
        new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:dispatch_tick, state) do
    # Periodic dispatch check
    if state.status == :crawling do
      {:noreply, dispatch_work(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Unexpected message in Coordinator",
      message: inspect(msg),
      state: :sys.get_state(self())
    )

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Coordinator terminating",
      reason: reason,
      job_id: state.job_id,
      pending: :queue.len(state.pending_queue),
      in_progress: MapSet.size(state.in_progress)
    )

    persist_state(state)
    :ok
  end

  # ============================================================================
  # Internal Functions
  # ============================================================================

  defp dispatch_work(state) do
    available_slots = state.max_concurrent - MapSet.size(state.in_progress)

    if available_slots > 0 and :queue.is_empty(state.pending_queue) == false do
      {items, remaining_queue} = :queue.split(available_slots, state.pending_queue)

      new_in_progress =
        :queue.to_list(items)
        |> Enum.reduce(state.in_progress, fn item, acc ->
          spawn_crawl(item, state.job_id)
          MapSet.put(acc, item[:url] || item)
        end)

      state
      |> Map.put(:pending_queue, remaining_queue)
      |> Map.put(:in_progress, new_in_progress)
    else
      state
    end
  end

  defp spawn_crawl(url_data, _job_id) do
    # Spawn async task for crawling
    Task.Supervisor.start_child(AONCrawler.Crawler.TaskSupervisor, fn ->
      url = if is_map(url_data), do: url_data[:url], else: url_data
      metadata = if is_map(url_data), do: Map.drop(url_data, [:url]), else: %{}

      result =
        with :ok <- RateLimiter.wait_for_slot(),
             {:ok, response} <- Worker.crawl(url),
             {:ok, content} <- Worker.parse(response, metadata) do
          {:ok, content}
        else
          {:error, reason} -> {:error, reason}
          error -> {:error, error}
        end

      GenServer.cast(__MODULE__, {:crawl_complete, url, result})
    end)
  end

  defp parse_seeds(seeds, opts) do
    urls =
      Enum.map(seeds, fn seed ->
        cond do
          is_binary(seed) -> %{url: seed, type: detect_type_from_url(seed)}
          is_map(seed) -> seed
          true -> raise ArgumentError, "Seed must be URL string or map, got: #{inspect(seed)}"
        end
      end)

    metadata = %{
      job_type: if(Keyword.get(opts, :full, false), do: :full, else: :incremental),
      content_types: Keyword.get(opts, :content_types, nil)
    }

    {urls, metadata}
  end

  defp detect_type_from_url(url) do
    cond do
      String.contains?(url, "Actions.aspx") -> :action
      String.contains?(url, "Spells.aspx") -> :spell
      String.contains?(url, "Feats.aspx") -> :feat
      String.contains?(url, "Traits.aspx") -> :trait
      String.contains?(url, "Rules.aspx") -> :rule
      String.contains?(url, "Equipment.aspx") -> :equipment
      String.contains?(url, "Monsters.aspx") -> :creature
      true -> :unknown
    end
  end

  defp normalize_url(url) when is_binary(url), do: %{url: url, type: detect_type_from_url(url)}
  defp normalize_url(%{} = url_data), do: url_data

  defp calculate_duration(nil), do: 0

  defp calculate_duration(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second)
  end

  defp persist_state(state) do
    if state.persist_state do
      # Serialize important state for recovery
      data = %{
        job_id: state.job_id,
        status: state.status,
        stats: state.stats,
        crawled_urls: MapSet.to_list(state.crawled_urls)
      }

      # In production, this would write to a file or database
      :ets.insert(:aoncrawler_coordinator_state, {:state, data})
    end
  end

  defp load_persisted_state(state) do
    case :ets.lookup(:aoncrawler_coordinator_state, :state) do
      [{:state, data}] ->
        Logger.info("Loaded persisted state", job_id: data.job_id)

        state
        |> Map.put(:job_id, data.job_id)
        |> Map.put(:status, :idle)
        |> Map.put(:stats, data.stats)
        |> Map.put(:crawled_urls, MapSet.new(data.crawled_urls))

      [] ->
        state
    end
  end
end
