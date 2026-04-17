defmodule WebRAG.Network.HealthCheck do
  @moduledoc """
  Helper functions for network health checks and operations.

  Provides utilities for:
  - Checking connectivity to specific URLs
  - Waiting for network recovery
  - Executing operations with automatic retry on network failures

  ## Usage

      # Simple connectivity check
      HealthCheck.check()
      #=> {:ok, true} or {:error, :offline}

      # Check a specific URL
      HealthCheck.check("https://example.com")

      # Wait for network to come back
      HealthCheck.wait_until_online()

      # Execute with automatic retry
      HealthCheck.with_retry max_attempts: 3, base_delay: 1000 do
        HTTPoison.get("https://api.example.com/data")
      end
  """

  require Logger

  @default_probe_url "https://2e.aonprd.com/"
  @default_timeout :timer.seconds(10)
  @default_max_attempts 3
  @default_base_delay :timer.seconds(1)
  @default_max_delay :timer.minutes(1)

  @doc """
  Checks if the given URL is reachable.

  ## Options

    - `:timeout` - Request timeout in milliseconds (default: 10000)
    - `:method` - HTTP method to use (default: :head)

  ## Examples

      iex> HealthCheck.check()
      {:ok, true}

      iex> HealthCheck.check("https://example.com")
      {:ok, true}

      iex> HealthCheck.check("https://invalid.example.com", timeout: 5000)
      {:error, :connection_failed}
  """
  @spec check(String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def check(url \\ @default_probe_url, opts \\ []) when is_binary(url) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    method = Keyword.get(opts, :method, :get)

    start_time = System.monotonic_time(:millisecond)

    result =
      Req.request(
        method: method,
        url: url,
        connect_options: [timeout: timeout]
      )

    elapsed = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{status: status}} when status in 200..399 ->
        Logger.debug("HealthCheck succeeded", url: url, status: status, elapsed_ms: elapsed)
        {:ok, true}

      {:ok, %{status: status}} ->
        Logger.debug("HealthCheck returned status", url: url, status: status, elapsed_ms: elapsed)
        {:ok, status < 500}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %{reason: :connect_timeout}} ->
        {:error, :connect_timeout}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:unknown, reason}}
    end
  rescue
    e in ArgumentError ->
      {:error, {:invalid_url, Exception.message(e)}}

    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Checks if the network is currently online using the ConnectivityMonitor.

  This is a quick check that doesn't make a new HTTP request - it just
  returns the current known status.
  """
  @spec online?() :: boolean()
  def online? do
    case WebRAG.Network.ConnectivityMonitor.status() do
      %{state: :online} -> true
      _ -> false
    end
  end

  @doc """
  Waits until the network is back online.

  ## Options

    - `:timeout` - Maximum time to wait (default: 5 minutes)
    - `:check_interval` - How often to check connectivity (default: 5 seconds)

  ## Returns

    - `:ok` - Network is back online
    - `{:error, :timeout}` - Network did not come back within the timeout

  ## Examples

      iex> HealthCheck.wait_until_online()
      :ok

      iex> HealthCheck.wait_until_online(timeout: :timer.minutes(1))
      {:error, :timeout}
  """
  @spec wait_until_online(keyword()) :: :ok | {:error, :timeout}
  def wait_until_online(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(5))
    check_interval = Keyword.get(opts, :check_interval, :timer.seconds(5))
    start_time = System.monotonic_time(:millisecond)

    if online?() do
      :ok
    else
      wait_loop(start_time, timeout, check_interval)
    end
  end

  defp wait_loop(start_time, timeout, check_interval) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed >= timeout do
      Logger.warning("Wait for network timed out")
      {:error, :timeout}
    else
      Process.sleep(min(check_interval, timeout - elapsed))

      if online?() do
        Logger.info("Network is back online")
        :ok
      else
        wait_loop(start_time, timeout, check_interval)
      end
    end
  end

  @doc """
  Executes a function with automatic retry on network failures.

  ## Options

    - `:max_attempts` - Maximum number of attempts (default: 3)
    - `:base_delay` - Initial delay between retries in ms (default: 1000)
    - `:max_delay` - Maximum delay between retries in ms (default: 60000)
    - `:retry_on` - List of errors to retry on (default: network-related)
    - `:on_retry` - Callback function called before each retry

  ## Examples

      {:ok, result} = HealthCheck.with_retry do
        Req.get("https://api.example.com/data")
      end

      HealthCheck.with_retry max_attempts: 5, base_delay: 2000 do
        Req.get(url)
      end
  """
  @spec with_retry(keyword(), (-> result)) :: result when result: var
  def with_retry(opts \\ [], fun) when is_function(fun, 0) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    base_delay = Keyword.get(opts, :base_delay, @default_base_delay)
    max_delay = Keyword.get(opts, :max_delay, @default_max_delay)
    retry_on = Keyword.get(opts, :retry_on, default_retry_errors())
    on_retry = Keyword.get(opts, :on_retry, &default_on_retry/2)

    execute_with_retry(fun, max_attempts, 1, base_delay, max_delay, retry_on, on_retry)
  end

  defp default_retry_errors do
    [
      :timeout,
      :connect_timeout,
      :econnrefused,
      :enetunreach,
      :ehostunreach,
      :network_error,
      :offline,
      :host_unreachable,
      {:failed_to_connect_host, :_},
      {:error, :timeout},
      {:error, :connect_timeout},
      {:error, :econnrefused},
      {:error, :network_error},
      {:error, {:network_error, :timeout}},
      {:error, {:network_error, :econnrefused}}
    ]
  end

  defp default_on_retry(attempt, error) do
    Logger.warning("Retrying after network error",
      attempt: attempt,
      error: inspect(error)
    )
  end

  defp execute_with_retry(fun, max_attempts, attempt, base_delay, max_delay, retry_on, on_retry) do
    fun.()
    |> handle_result(fun, max_attempts, attempt, base_delay, max_delay, retry_on, on_retry)
  end

  defp handle_result(
         {:ok, _} = result,
         _fun,
         _max_attempts,
         _attempt,
         _base_delay,
         _max_delay,
         _retry_on,
         _on_retry
       ) do
    result
  end

  defp handle_result(
         {:error, reason} = error,
         fun,
         max_attempts,
         attempt,
         base_delay,
         max_delay,
         retry_on,
         on_retry
       ) do
    if should_retry?(reason, retry_on) and attempt < max_attempts do
      delay = calculate_delay(attempt, base_delay, max_delay)

      on_retry.(attempt, reason)

      Process.sleep(delay)

      execute_with_retry(
        fun,
        max_attempts,
        attempt + 1,
        base_delay,
        max_delay,
        retry_on,
        on_retry
      )
    else
      error
    end
  end

  defp handle_result(
         other,
         _fun,
         _max_attempts,
         _attempt,
         _base_delay,
         _max_delay,
         _retry_on,
         _on_retry
       ) do
    other
  end

  defp should_retry?(reason, retry_on) do
    Enum.any?(retry_on, fn pattern ->
      matches_pattern?(reason, pattern)
    end)
  end

  defp matches_pattern?(reason, pattern) when is_atom(pattern) do
    reason == pattern
  end

  defp matches_pattern?(reason, {pattern, :_}) when is_atom(pattern) do
    case reason do
      {^pattern, _} -> true
      _ -> false
    end
  end

  defp matches_pattern?(reason, {:error, pattern}) do
    matches_pattern?(reason, pattern)
  end

  defp matches_pattern?(reason, pattern) do
    reason == pattern
  end

  defp calculate_delay(attempt, base_delay, max_delay) do
    delay = base_delay * :math.pow(2, attempt - 1)
    min(delay, max_delay) |> round()
  end
end
