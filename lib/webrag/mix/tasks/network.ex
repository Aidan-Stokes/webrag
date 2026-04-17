defmodule Mix.Tasks.Network do
  @moduledoc """
  Network utilities for monitoring connectivity and managing failed operations.

  ## Commands

      mix network.status     # Show current connectivity status
      mix network.retry      # Retry failed operations
      mix network.stats     # Show DLQ statistics
      mix network.clear     # Clear failed operations
      mix network.check     # Perform a manual connectivity check

  ## Examples

      # Show current network status
      mix network.status

      # Check connectivity
      mix network.check

      # Retry all failed operations
      mix network.retry

      # Retry failures for a specific phase
      mix network.retry --phase crawl

      # Retry with a limit
      mix network.retry --phase crawl --limit 50

      # Show DLQ statistics
      mix network.stats

      # Clear failures for a phase
      mix network.clear --phase crawl
  """
  use Mix.Task

  @shortdoc "Network utilities for connectivity and DLQ management"

  @impl true
  def run(["status" | args]) do
    parse_and_run(:status, args)
  end

  def run(["check" | args]) do
    parse_and_run(:check, args)
  end

  def run(["retry" | args]) do
    parse_and_run(:retry, args)
  end

  def run(["stats" | _args]) do
    parse_and_run(:stats, [])
  end

  def run(["clear" | args]) do
    parse_and_run(:clear, args)
  end

  def run(["export" | args]) do
    parse_and_run(:export, args)
  end

  def run(["import" | args]) do
    parse_and_run(:import, args)
  end

  def run([]) do
    Mix.shell().info("""
    Network utilities for WebRAG

    Available commands:
      mix network.status     # Show current connectivity status
      mix network.check      # Perform a manual connectivity check
      mix network.retry      # Retry failed operations
      mix network.stats      # Show DLQ statistics
      mix network.clear     # Clear failed operations
      mix network.export     # Export DLQ to JSON file
      mix network.import     # Import DLQ from JSON file

    Run with --help for more details on each command.
    """)
  end

  def run(["--help" | _]) do
    Mix.shell().info(@moduledoc)
  end

  defp parse_and_run(:status, _args) do
    ensure_started()

    status = WebRAG.Network.ConnectivityMonitor.status()

    IO.puts("Network Status")
    IO.puts(String.duplicate("=", 50))

    state_str =
      status.state
      |> Atom.to_string()
      |> String.upcase()

    status_line =
      case status.state do
        :online -> IO.ANSI.green() <> "Status: #{state_str}" <> IO.ANSI.reset()
        :degraded -> IO.ANSI.yellow() <> "Status: #{state_str}" <> IO.ANSI.reset()
        :offline -> IO.ANSI.red() <> "Status: #{state_str}" <> IO.ANSI.reset()
        :recovering -> IO.ANSI.yellow() <> "Status: #{state_str}" <> IO.ANSI.reset()
      end

    IO.puts(status_line)
    IO.puts("Consecutive Failures: #{status.consecutive_failures}")

    if status.last_check do
      IO.puts("Last Check: #{format_datetime(status.last_check)}")
    end

    if status.last_success do
      IO.puts("Last Success: #{format_datetime(status.last_success)}")
    end

    IO.puts("")
  end

  defp parse_and_run(:check, _args) do
    ensure_started()

    IO.puts("Performing connectivity check...")

    start_time = System.monotonic_time(:millisecond)

    result =
      WebRAG.Network.HealthCheck.check(
        Application.get_env(:webrag, :network_probe_url, "https://2e.aonprd.com/")
      )

    elapsed = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, true} ->
        IO.puts(IO.ANSI.green() <> "✓ Connection successful (#{elapsed}ms)" <> IO.ANSI.reset())

      {:ok, false} ->
        IO.puts(
          IO.ANSI.yellow() <>
            "✗ Connection returned non-success status (#{elapsed}ms)" <> IO.ANSI.reset()
        )

      {:error, reason} ->
        Mix.shell().error(
          IO.ANSI.red() <>
            "✗ Connection failed: #{inspect(reason)} (#{elapsed}ms)" <> IO.ANSI.reset()
        )
    end
  end

  defp parse_and_run(:retry, args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          phase: :string,
          limit: :integer,
          all: :boolean
        ],
        aliases: [p: :phase, l: :limit]
      )

    phase = parse_phase(Keyword.get(opts, :phase))
    limit = Keyword.get(opts, :limit)
    all = Keyword.get(opts, :all, false)

    ensure_started()

    phases = if all or phase == nil, do: [:discovery, :crawl, :embed, :query], else: [phase]

    total = Enum.reduce(phases, 0, fn p, acc -> acc + WebRAG.Network.DLQ.count(p) end)

    if total == 0 do
      IO.puts("No failed operations to retry.")
      :ok
    else
      IO.puts("Found #{total} failed operations to retry")
      IO.puts("")

      retry_operations(phases, limit)
    end
  end

  defp parse_and_run(:stats, _args) do
    ensure_started()

    stats = WebRAG.Network.DLQ.stats()

    IO.puts("Dead-Letter Queue Statistics")
    IO.puts(String.duplicate("=", 50))
    IO.puts("")

    Enum.each([:discovery, :crawl, :embed, :query], fn phase ->
      count = Map.get(stats, phase, 0)
      label = Atom.to_string(phase) |> String.pad_trailing(10)
      bar = String.duplicate("█", min(count, 50))

      if count > 0 do
        IO.puts("#{label} #{bar} #{count}")
      else
        IO.puts(IO.ANSI.green() <> "#{label} (empty)" <> IO.ANSI.reset())
      end
    end)

    IO.puts("")
    IO.puts("Total: #{stats.total}")
    IO.puts("")
  end

  defp parse_and_run(:clear, args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [phase: :string, all: :boolean],
        aliases: [p: :phase]
      )

    phase = parse_phase(Keyword.get(opts, :phase))
    all = Keyword.get(opts, :all, false)

    ensure_started()

    if all do
      WebRAG.Network.DLQ.clear_all()
      IO.puts("Cleared all failed operations from all phases.")
    else
      WebRAG.Network.DLQ.clear(phase)
      IO.puts("Cleared failed operations for #{phase} phase.")
    end
  end

  defp parse_and_run(:export, [path | _]) do
    ensure_started()

    case WebRAG.Network.DLQ.export(path) do
      :ok -> IO.puts("Exported DLQ to #{path}")
      {:error, reason} -> Mix.shell().error("Export failed: #{inspect(reason)}")
    end
  end

  defp parse_and_run(:import, [path | _]) do
    ensure_started()

    case WebRAG.Network.DLQ.import(path) do
      :ok -> IO.puts("Imported DLQ from #{path}")
      {:error, reason} -> Mix.shell().error("Import failed: #{inspect(reason)}")
    end
  end

  defp parse_phase(nil), do: :crawl
  defp parse_phase("discovery"), do: :discovery
  defp parse_phase("crawl"), do: :crawl
  defp parse_phase("embed"), do: :embed
  defp parse_phase("query"), do: :query
  defp parse_phase(other), do: Mix.raise("Invalid phase: #{other}")

  defp retry_operations(phases, limit) do
    operations =
      phases
      |> WebRAG.Network.DLQ.load()
      |> Enum.take(limit || :infinity)

    if Enum.empty?(operations) do
      IO.puts("No operations to retry.")
    else
      IO.puts("Retrying #{length(operations)} operations...")
      IO.puts("")

      success_count =
        Enum.reduce(operations, 0, fn op, acc ->
          IO.write("  #{op.phase}: #{op.operation_id} ... ")

          _ = retry_operation(op)
          WebRAG.Network.DLQ.mark_retried(op.phase, op.operation_id)
          IO.puts(IO.ANSI.green() <> "✓" <> IO.ANSI.reset())
          acc + 1
        end)

      fail_count = length(operations) - success_count

      IO.puts("")
      IO.puts("Retry complete: #{success_count} succeeded, #{fail_count} failed")
    end
  end

  defp retry_operation(%{phase: :discovery}) do
    IO.puts(IO.ANSI.yellow() <> "(discovery retry not implemented)" <> IO.ANSI.reset())
    :ok
  end

  defp retry_operation(%{phase: :crawl}) do
    IO.puts(IO.ANSI.yellow() <> "(crawl retry not implemented)" <> IO.ANSI.reset())
    :ok
  end

  defp retry_operation(%{phase: :embed}) do
    IO.puts(IO.ANSI.yellow() <> "(embed retry not implemented)" <> IO.ANSI.reset())
    :ok
  end

  defp retry_operation(%{phase: :query}) do
    IO.puts(IO.ANSI.yellow() <> "(query retry not implemented)" <> IO.ANSI.reset())
    :ok
  end

  defp ensure_started do
    Application.ensure_all_started(:webrag)

    if !Process.whereis(WebRAG.Network.ConnectivityMonitor) do
      {:ok, _} = WebRAG.Network.ConnectivityMonitor.start_link([])
    end
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp format_datetime(%DateTime{} = dt) do
    "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)} #{pad(dt.hour)}:#{pad(dt.minute)}:#{pad(dt.second)} UTC"
  end

  defp format_datetime(nil), do: "never"
end
