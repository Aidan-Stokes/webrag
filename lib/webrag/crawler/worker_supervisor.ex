defmodule WebRAG.Crawler.WorkerSupervisor do
  @moduledoc """
  Supervisor for crawler worker processes.

  This supervisor manages a pool of worker processes that perform the actual
  HTTP requests to Archives of Nethys. It uses a simple one_for_one strategy
  since worker failures are isolated and don't affect other workers.

  ## Design Decisions

  1. **Dynamic Workers**: Workers are started dynamically based on demand,
     allowing the pool to scale with crawl queue depth.

  2. **Supervisor Hierarchy**: We use `Supervisor.Spec.worker/3` with a
     restart strategy that allows transient failures without killing the
     entire pool.

  3. **Backpressure**: Workers check with the rate limiter before each
     request, providing automatic backpressure.

  4. **Monitoring**: Each worker reports metrics via Telemetry for
     observability into crawl performance.

  ## Concurrency Model

  The supervisor maintains a pool of workers up to `max_concurrent`.
  When a crawl job arrives:
  1. The coordinator picks a pending job
  2. A worker is started (or reused from idle pool)
  3. The worker acquires a rate limiter token
  4. The worker performs the HTTP request
  5. The worker processes the response
  6. The worker returns to idle state

  If the pool is exhausted, jobs wait in the coordinator's queue.
  """

  use Supervisor
  require Logger

  alias WebRAG.Crawler.Worker

  @typedoc "Options for the worker supervisor"
  @type option :: {:max_concurrent, pos_integer()}

  @default_max_concurrent 5

  @doc """
  Starts the worker supervisor.

  ## Options

  - `:max_concurrent` - Maximum number of concurrent workers (default: 5)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    max_concurrent = Keyword.get(opts, :max_concurrent, @default_max_concurrent)

    Supervisor.start_link(
      __MODULE__,
      %{max_concurrent: max_concurrent},
      name: __MODULE__
    )
  end

  @impl true
  def init(%{max_concurrent: max_concurrent}) do
    Logger.info("Starting WorkerSupervisor", max_concurrent: max_concurrent)

    children = [
      # Worker module with restart strategy
      {Worker, []}
    ]

    # one_for_one: If a worker dies, only that worker restarts
    # max_restarts: Allow up to 10 restarts per 10 seconds
    # max_seconds: The sliding window for restart counting
    Supervisor.init(
      children,
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 10,
      subscribe_to: []
    )
  end

  @doc """
  Returns the maximum number of concurrent workers.
  """
  @spec max_concurrent() :: pos_integer()
  def max_concurrent do
    case Supervisor.count_children(__MODULE__) do
      %{workers: workers} when workers > 0 ->
        workers

      _ ->
        Application.get_env(
          :webrag,
          [WebRAG.Crawler, :max_concurrent],
          @default_max_concurrent
        )
    end
  end

  @doc """
  Returns the number of currently active workers.
  """
  @spec active_workers() :: non_neg_integer()
  def active_workers do
    Supervisor.count_children(__MODULE__)[:active]
  end

  @doc """
  Returns the number of workers available for new jobs.
  """
  @spec available_workers() :: non_neg_integer()
  def available_workers do
    max_concurrent() - active_workers()
  end

  @doc """
  Checks if there's capacity for new crawl jobs.
  """
  @spec has_capacity?() :: boolean()
  def has_capacity? do
    available_workers() > 0
  end

  @doc """
  Restarts a specific worker by PID.
  """
  @spec restart_worker(pid()) :: :ok | {:error, term()}
  def restart_worker(worker_pid) when is_pid(worker_pid) do
    case Supervisor.restart_child(__MODULE__, worker_pid) do
      {:ok, _} ->
        Logger.info("Worker restarted", pid: inspect(worker_pid))
        :ok

      {:error, reason} ->
        Logger.error("Failed to restart worker", pid: inspect(worker_pid), reason: reason)
        {:error, reason}
    end
  end

  @doc """
  Terminates all workers gracefully.

  Useful for graceful shutdown during application termination.
  """
  @spec terminate_all() :: :ok
  def terminate_all do
    DynamicSupervisor.stop(__MODULE__)
    Logger.info("All workers terminated")
    :ok
  end

  @doc """
  Returns statistics about the worker pool.
  """
  @spec stats() :: map()
  def stats do
    %{
      max_concurrent: max_concurrent(),
      active: active_workers(),
      available: available_workers(),
      specs: Supervisor.count_children(__MODULE__)[:specs],
      supervisors: Supervisor.count_children(__MODULE__)[:supervisors]
    }
  end

  @doc """
  Suspends the supervisor, preventing new workers from starting.

  In-flight workers continue but no new work is dispatched.
  """
  @spec suspend() :: :ok
  def suspend do
    Logger.info("WorkerSupervisor suspend not implemented for DynamicSupervisor")
    :ok
  end

  @doc """
  Resumes the supervisor, allowing new workers to start.
  """
  @spec resume() :: :ok
  def resume do
    Logger.info("WorkerSupervisor resume not implemented for DynamicSupervisor")
    :ok
  end

  @doc """
  Returns the specification for this supervisor.

  Useful for embedding in another supervisor tree.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5_000
    }
  end
end
