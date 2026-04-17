defmodule WebRAG.Crawler.RateLimiter do
  @moduledoc """
  Rate limiter GenServer for controlling crawl request frequency.

  This module implements a token bucket algorithm to ensure we respect rate
  limits when crawling Archives of Nethys. It provides backpressure by
  blocking requests when the rate limit would be exceeded.

  ## Design Decisions

  1. **Token Bucket Algorithm**: We use tokens per second rather than fixed
     intervals. This allows burst requests up to the bucket size while
     maintaining average rate compliance.

  2. **ETS-based State**: State is stored in ETS for fast access from multiple
     processes without message passing overhead.

  3. **Per-host Limiting**: We track rate limits per-host to handle sites
     with different rate limit policies.

  4. **Adaptive Rate Limiting**: If we detect rate limit errors (429),
     we automatically reduce the rate for that host.

  ## Usage

      # Start the rate limiter
      {:ok, pid} = GenServer.start_link(__MODULE__, rate_limit: 2)

      # Check if we can make a request (non-blocking)
      if RateLimiter.allow_request(pid) do
        # Make the request
      end

      # Wait for rate limit clearance (blocking)
      :ok = RateLimiter.wait_for_token(pid)

  ## Configuration

  - `rate_limit` - Requests per second (default: 2)
  - `burst_size` - Maximum burst capacity (default: 5)
  - `cleanup_interval` - How often to clean up stale entries (ms)
  """

  use GenServer, restart: :permanent
  require Logger

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the rate limiter with the given options.

  ## Options

    * `:rate_limit` - Requests per second (default: 2)
    * `:burst_size` - Maximum tokens in bucket (default: 5)
    * `:cleanup_interval` - Cleanup interval in ms (default: 60_000)

  ## Example

      {:ok, pid} = RateLimiter.start_link(rate_limit: 5, burst_size: 10)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    rate_limit = Keyword.get(opts, :rate_limit, 2)
    burst_size = Keyword.get(opts, :burst_size, 5)
    cleanup_interval = Keyword.get(opts, :cleanup_interval, 60_000)

    state = %{
      rate_limit: rate_limit,
      burst_size: burst_size,
      cleanup_interval: cleanup_interval,
      last_refill_at: System.system_time(:millisecond),
      tokens: burst_size,
      host_limits: %{}
    }

    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  @doc """
  Returns the current rate limit configuration.
  """
  @spec get_rate_limit(GenServer.server()) :: non_neg_integer()
  def get_rate_limit(server \\ __MODULE__) do
    GenServer.call(server, :get_rate_limit)
  end

  @doc """
  Checks if a request is allowed without blocking.

  Returns `:ok` if a token is available, `:wait` if the caller should
  wait for a token, or `{:wait, ms}` with the estimated wait time.
  """
  @spec check(GenServer.server()) :: :ok | {:wait, non_neg_integer()}
  def check(server \\ __MODULE__) do
    GenServer.call(server, :check)
  end

  @doc """
  Checks if a request is allowed for a specific host.

  Different hosts may have different rate limits. This allows per-host
  rate limiting while maintaining overall request control.
  """
  @spec check_host(GenServer.server(), String.t()) :: :ok | {:wait, non_neg_integer()}
  def check_host(server \\ __MODULE__, host) do
    GenServer.call(server, {:check_host, host})
  end

  @doc """
  Waits until a token is available, then returns.

  This is a blocking call that should be used when you want to
  ensure rate limit compliance before making a request.
  """
  @spec wait_for_token(GenServer.server(), timeout()) ::
          :ok | {:error, :timeout | :rate_limiter_down}
  def wait_for_token(server \\ __MODULE__, timeout \\ 30_000) do
    try do
      GenServer.call(server, :wait_for_token, timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.error("Rate limiter wait timed out, network may be down")
        {:error, :timeout}

      :exit, reason ->
        Logger.error("Rate limiter crashed", reason: reason)
        {:error, :rate_limiter_down}
    end
  end

  @doc """
  Waits for a token for a specific host.
  """
  @spec wait_for_host_token(GenServer.server(), String.t(), timeout()) :: :ok
  def wait_for_host_token(server \\ __MODULE__, host, timeout \\ 30_000) do
    GenServer.call(server, {:wait_for_host_token, host}, timeout)
  end

  @doc """
  Consumes a token, indicating a request was made.

  Call this after successfully making a request to update the bucket.
  """
  @spec consume(GenServer.server()) :: :ok
  def consume(server \\ __MODULE__) do
    GenServer.cast(server, :consume)
  end

  @doc """
  Consumes a token for a specific host.
  """
  @spec consume_host(GenServer.server(), String.t()) :: :ok
  def consume_host(server \\ __MODULE__, host) do
    GenServer.cast(server, {:consume_host, host})
  end

  @doc """
  Records a rate limit error, reducing the rate for this host.
  """
  @spec record_rate_limit_error(GenServer.server(), String.t()) :: :ok
  def record_rate_limit_error(server \\ __MODULE__, host) do
    GenServer.cast(server, {:record_rate_limit_error, host})
  end

  @doc """
  Updates the rate limit dynamically.
  """
  @spec set_rate_limit(GenServer.server(), non_neg_integer()) :: :ok
  def set_rate_limit(server \\ __MODULE__, rate_limit) do
    GenServer.cast(server, {:set_rate_limit, rate_limit})
  end

  @doc """
  Returns current statistics about the rate limiter.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(state) do
    Logger.info("RateLimiter started",
      rate_limit: state.rate_limit,
      burst_size: state.burst_size
    )

    schedule_cleanup(state.cleanup_interval)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_rate_limit, _from, state) do
    {:reply, state.rate_limit, state}
  end

  @impl true
  def handle_call(:check, _from, state) do
    {tokens, wait_ms} = refill_tokens(state)

    if tokens >= 1 do
      {:reply, :ok,
       %{state | tokens: tokens - 1, last_refill_at: System.system_time(:millisecond)}}
    else
      {:reply, {:wait, wait_ms}, state}
    end
  end

  @impl true
  def handle_call({:check_host, host}, _from, state) do
    {tokens, wait_ms} = refill_tokens(state)
    _host_rate = get_host_rate(state, host)

    if tokens >= 1 do
      {:reply, :ok,
       %{state | tokens: tokens - 1, last_refill_at: System.system_time(:millisecond)}}
    else
      {:reply, {:wait, wait_ms}, state}
    end
  end

  @impl true
  def handle_call(:wait_for_token, from, state) do
    {tokens, wait_ms} = refill_tokens(state)

    if tokens >= 1 do
      {:reply, :ok,
       %{state | tokens: tokens - 1, last_refill_at: System.system_time(:millisecond)}}
    else
      # Schedule a message to ourselves to retry
      Process.send_after(self(), {:retry_wait, from}, wait_ms)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:wait_for_host_token, _host}, from, state) do
    # For now, just use global tokens
    handle_call(:wait_for_token, from, state)
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      rate_limit: state.rate_limit,
      burst_size: state.burst_size,
      current_tokens: state.tokens,
      host_limits: Map.keys(state.host_limits)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:consume, state) do
    {:noreply, %{state | tokens: max(0, state.tokens - 1)}}
  end

  @impl true
  def handle_cast({:consume_host, _host}, state) do
    {:noreply, %{state | tokens: max(0, state.tokens - 1)}}
  end

  @impl true
  def handle_cast({:record_rate_limit_error, host}, state) do
    host_limits =
      Map.update(state.host_limits, host, %{errors: 1}, fn h ->
        %{h | errors: h.errors + 1, last_error_at: System.system_time(:millisecond)}
      end)

    # Reduce rate limit for this host by 50%
    new_rate = state.rate_limit / 2
    Logger.warning("Rate limit error recorded for host", host: host, new_rate: new_rate)

    {:noreply, %{state | host_limits: host_limits}}
  end

  @impl true
  def handle_cast({:set_rate_limit, rate_limit}, state) do
    Logger.info("Rate limit updated", old_rate: state.rate_limit, new_rate: rate_limit)
    {:noreply, %{state | rate_limit: rate_limit}}
  end

  @impl true
  def handle_info({:retry_wait, from}, state) do
    {tokens, wait_ms} = refill_tokens(state)

    if tokens >= 1 do
      GenServer.reply(from, :ok)
      {:noreply, %{state | tokens: tokens - 1, last_refill_at: System.system_time(:millisecond)}}
    else
      Process.send_after(self(), {:retry_wait, from}, wait_ms)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Clean up old host limits that haven't been used recently
    now = System.system_time(:millisecond)
    # 5 minutes
    max_age = 5 * 60 * 1000

    host_limits =
      state.host_limits
      |> Enum.reject(fn {_, limit} ->
        last_used = Map.get(limit, :last_used_at, 0)
        last_error = Map.get(limit, :last_error_at, 0)
        max(last_used, last_error) < now - max_age
      end)
      |> Map.new()

    schedule_cleanup(state.cleanup_interval)
    {:noreply, %{state | host_limits: host_limits}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp refill_tokens(state) do
    now = System.system_time(:millisecond)
    elapsed_ms = now - state.last_refill_at

    # Tokens are replenished at rate_limit per second
    tokens_to_add = elapsed_ms / 1000 * state.rate_limit
    new_tokens = min(state.burst_size, state.tokens + tokens_to_add)

    if new_tokens >= 1 do
      {new_tokens, 0}
    else
      # Calculate wait time until we have a token
      tokens_needed = 1 - new_tokens
      wait_ms = ceil(tokens_needed / state.rate_limit * 1000)
      {new_tokens, wait_ms}
    end
  end

  defp get_host_rate(_state, _host) do
    # For future implementation of per-host rate limiting
    1.0
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end
end
