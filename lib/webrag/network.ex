defmodule WebRAG.Network do
  @moduledoc """
  Network resilience utilities for the WebRAG pipeline.

  Provides shared infrastructure for handling network failures across all
  pipeline phases (discovery, crawl, embed, query):

    - `WebRAG.Network.ConnectivityMonitor` - GenServer that monitors internet connectivity
    - `WebRAG.Network.HealthCheck` - Helper functions for network operations
    - `WebRAG.Network.DLQ` - Phase-tagged dead-letter queue for failed operations

  ## Usage

      # Start the connectivity monitor
      WebRAG.Network.ConnectivityMonitor.start_link([])

      # Check connectivity status
      WebRAG.Network.ConnectivityMonitor.status()

      # Subscribe to connectivity events
      WebRAG.Network.ConnectivityMonitor.subscribe(self())

      # Save a failure to the DLQ
      WebRAG.Network.DLQ.save(:crawl, "https://example.com", :timeout)

      # Load failed operations for retry
      WebRAG.Network.DLQ.load(:crawl)

  ## Configuration

      config :webrag, WebRAG.Network.ConnectivityMonitor,
        check_interval: :timer.seconds(30),
        failure_threshold: 3,
        probe_url: "https://2e.aonprd.com/",
        recovery_interval: :timer.seconds(10)

      config :webrag, WebRAG.Network.DLQ,
        enabled: true,
        data_dir: "data/network"
  """

  alias WebRAG.Network.{ConnectivityMonitor, HealthCheck, DLQ}

  @doc """
  Returns the connectivity monitor status.
  """
  defdelegate status(), to: ConnectivityMonitor

  @doc """
  Subscribes the current process to connectivity events.
  """
  defdelegate subscribe(pid \\ self()), to: ConnectivityMonitor

  @doc """
  Performs a connectivity check and returns the result.
  """
  defdelegate check(url \\ default_probe_url()), to: HealthCheck

  @doc """
  Waits until connectivity is restored, optionally with a timeout.
  """
  defdelegate wait_until_online(timeout \\ :timer.minutes(5)), to: HealthCheck

  @doc """
  Executes a function with automatic retry on network failure.
  """
  defmacro with_retry(opts \\ [], do: block) do
    quote do
      HealthCheck.with_retry(unquote(opts), fn -> unquote(block) end)
    end
  end

  @doc """
  Saves a failed operation to the dead-letter queue.
  """
  defdelegate save_failed(phase, operation_id, reason, metadata \\ %{}),
    to: DLQ,
    as: :save

  @doc """
  Loads failed operations for a specific phase.
  """
  defdelegate load_failed(phase), to: DLQ, as: :load

  @doc """
  Returns statistics about the DLQ.
  """
  defdelegate dlq_stats(), to: DLQ, as: :stats

  @doc """
  Clears failed operations for a phase.
  """
  defdelegate clear_failed(phase), to: DLQ, as: :clear

  defp default_probe_url do
    Application.get_env(:webrag, :network_probe_url, "https://2e.aonprd.com/")
  end
end
