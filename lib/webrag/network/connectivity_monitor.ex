defmodule WebRAG.Network.ConnectivityMonitor do
  @moduledoc """
  GenServer that monitors internet connectivity and broadcasts status changes.

  This module provides a centralized way to detect network outages and notify
  other parts of the pipeline so they can react appropriately (pause, retry, etc.).

  ## Status States

    - `:online` - Network is available, checks are succeeding
    - `:degraded` - Some checks are failing, but not yet considered offline
    - `:offline` - Network is unavailable, consecutive failures exceeded threshold
    - `:recovering` - Was offline, now attempting to reconnect

  ## Events

  Subscribers receive messages:

    - `{:network_status, :online}`
    - `{:network_status, :offline}`
    - `{:network_status, :degraded, consecutive_failures}`
    - `{:network_status, :recovering}`

  ## Example

      # Start the monitor
      ConnectivityMonitor.start_link([])

      # Subscribe to events
      ConnectivityMonitor.subscribe(self())

      # Check current status
      ConnectivityMonitor.status()
      #=> %{state: :online, consecutive_failures: 0, last_check: ~U[...]}

  ## Supervision

  This GenServer should be added to your application supervision tree:

      children = [
        WebRAG.Network.ConnectivityMonitor
      ]
  """

  use GenServer
  require Logger

  @default_check_interval :timer.seconds(30)
  @default_failure_threshold 3
  @default_probe_url "https://2e.aonprd.com/"
  @default_recovery_interval :timer.seconds(10)
  @default_request_timeout :timer.seconds(10)

  @type status :: :online | :degraded | :offline | :recovering
  @type event :: {:network_status, status() | {status(), non_neg_integer()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current connectivity status.
  """
  @spec status() :: %{
          state: status(),
          consecutive_failures: non_neg_integer(),
          last_check: DateTime.t() | nil,
          last_success: DateTime.t() | nil
        }
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Subscribes the given process to connectivity events.

  The process will receive messages like `{:network_status, :offline}`.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()) do
    GenServer.cast(__MODULE__, {:subscribe, pid})
  end

  @doc """
  Unsubscribes a process from connectivity events.
  """
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()) do
    GenServer.cast(__MODULE__, {:unsubscribe, pid})
  end

  @doc """
  Manually triggers a connectivity check.
  """
  @spec check() :: {:ok, boolean()} | {:error, term()}
  def check() do
    GenServer.call(__MODULE__, :check_now)
  end

  @doc """
  Forces the monitor to online state (for testing).
  """
  @spec force_online() :: :ok
  def force_online() do
    GenServer.cast(__MODULE__, :force_online)
  end

  @doc """
  Forces the monitor to offline state (for testing).
  """
  @spec force_offline() :: :ok
  def force_offline() do
    GenServer.cast(__MODULE__, :force_offline)
  end

  @impl true
  def init(opts) do
    check_interval =
      Keyword.get(opts, :check_interval, @default_check_interval)
      |> parse_timeout()

    failure_threshold =
      Keyword.get(opts, :failure_threshold, @default_failure_threshold)

    probe_url =
      Keyword.get(opts, :probe_url, @default_probe_url)

    recovery_interval =
      Keyword.get(opts, :recovery_interval, @default_recovery_interval)
      |> parse_timeout()

    request_timeout =
      Keyword.get(opts, :request_timeout, @default_request_timeout)
      |> parse_timeout()

    state = %{
      check_interval: check_interval,
      failure_threshold: failure_threshold,
      probe_url: probe_url,
      recovery_interval: recovery_interval,
      request_timeout: request_timeout,
      state: :online,
      consecutive_failures: 0,
      consecutive_successes: 0,
      recovery_successes_needed: 2,
      last_check: nil,
      last_success: nil,
      subscribers: MapSet.new(),
      timer_ref: nil
    }

    Logger.info("ConnectivityMonitor started",
      check_interval_ms: check_interval,
      failure_threshold: failure_threshold,
      probe_url: probe_url
    )

    {:ok, schedule_next_check(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       state: state.state,
       consecutive_failures: state.consecutive_failures,
       last_check: state.last_check,
       last_success: state.last_success
     }, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    case perform_check(state) do
      {:ok, success} ->
        new_state = process_check_result(success, state)
        {:reply, {:ok, success}, new_state}

      {:error, reason} ->
        new_state = process_check_result(false, state)
        Logger.warning("Manual connectivity check failed", reason: reason)
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_cast(:force_online, state) do
    new_state = %{state | state: :online, consecutive_failures: 0, consecutive_successes: 0}
    broadcast(new_state.subscribers, {:network_status, :online})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:force_offline, state) do
    new_state = %{state | state: :offline, consecutive_failures: state.failure_threshold}
    broadcast(new_state.subscribers, {:network_status, :offline})
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check, state) do
    case perform_check(state) do
      {:ok, success} ->
        new_state = process_check_result(success, state)
        {:noreply, schedule_next_check(new_state)}

      {:error, reason} ->
        Logger.warning("Connectivity check error", reason: reason)
        new_state = process_check_result(false, state)
        {:noreply, schedule_next_check(new_state)}
    end
  end

  @impl true
  def handle_info(:recovery_check, state) do
    case perform_check(state) do
      {:ok, true} ->
        if state.consecutive_successes >= state.recovery_successes_needed do
          broadcast(state.subscribers, {:network_status, :online})
          new_state = %{state | state: :online, consecutive_failures: 0, consecutive_successes: 0}
          {:noreply, schedule_next_check(new_state)}
        else
          new_state = %{state | consecutive_successes: state.consecutive_successes + 1}
          {:noreply, schedule_recovery_check(new_state)}
        end

      _ ->
        new_state = %{state | consecutive_successes: 0}
        {:noreply, schedule_recovery_check(new_state)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp schedule_next_check(state) do
    %{state | timer_ref: schedule_check(state.check_interval)}
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check, interval)
  end

  defp schedule_recovery_check(state) do
    %{state | timer_ref: schedule_check(state.recovery_interval)}
  end

  defp perform_check(state) do
    WebRAG.Network.HealthCheck.check(state.probe_url, timeout: state.request_timeout)
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp process_check_result(true, state) do
    now = DateTime.utc_now()

    new_state =
      state
      |> Map.put(:consecutive_failures, 0)
      |> Map.put(:last_check, now)
      |> Map.put(:last_success, now)

    cond do
      state.state == :offline or state.state == :recovering ->
        new_state = %{new_state | consecutive_successes: state.consecutive_successes + 1}

        if new_state.consecutive_successes >= state.recovery_successes_needed do
          broadcast(state.subscribers, {:network_status, :online})
          %{new_state | state: :online, consecutive_successes: 0}
        else
          broadcast(state.subscribers, {:network_status, :recovering})
          new_state
        end

      state.state == :degraded ->
        broadcast(state.subscribers, {:network_status, :online})
        %{new_state | state: :online}

      true ->
        new_state
    end
  end

  defp process_check_result(false, state) do
    now = DateTime.utc_now()

    new_failures = state.consecutive_failures + 1

    new_state =
      state
      |> Map.put(:consecutive_failures, new_failures)
      |> Map.put(:last_check, now)
      |> Map.put(:consecutive_successes, 0)

    cond do
      state.state == :online and new_failures >= state.failure_threshold - 1 ->
        broadcast(state.subscribers, {:network_status, :degraded, new_failures})
        %{new_state | state: :degraded}

      state.state == :online and new_failures >= state.failure_threshold ->
        broadcast(state.subscribers, {:network_status, :offline})
        %{new_state | state: :offline}

      state.state == :degraded and new_failures >= state.failure_threshold ->
        broadcast(state.subscribers, {:network_status, :offline})
        %{new_state | state: :offline}

      state.state == :offline ->
        new_state

      true ->
        new_state
    end
  end

  defp broadcast(subscribers, event) do
    Enum.each(subscribers, fn pid ->
      send(pid, event)

      ref = Process.monitor(pid)
      send(self(), {:DOWN, ref, :process, pid, :normal})
    end)

    :telemetry.execute(
      [:webrag, :network, :status],
      %{},
      %{
        state:
          event
          |> elem(1)
          |> then(fn
            s when is_atom(s) -> s
            {s, _} -> s
          end)
      }
    )
  end

  defp parse_timeout(timeout) when is_integer(timeout), do: timeout

  defp parse_timeout(timeout) when is_atom(timeout),
    do: Application.get_env(:webrag, timeout, @default_check_interval)
end
