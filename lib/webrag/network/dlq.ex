defmodule WebRAG.Network.DLQ do
  @moduledoc """
  Dead-letter queue for failed pipeline operations across all phases.

  Stores failed operations with phase tagging so they can be retried later.
  Operations are stored in a simple JSON format for easy inspection.

  ## Supported Phases

    - `:discovery` - Failed URL discovery operations
    - `:crawl` - Failed page crawl operations
    - `:embed` - Failed embedding generation operations
    - `:query` - Failed query operations

  ## Data Structure

  Each failed operation contains:

    - `:phase` - The pipeline phase where failure occurred
    - `:operation_id` - URL or operation identifier
    - `:reason` - Error reason (atom or string)
    - `:timestamp` - When the failure occurred (Unix timestamp)
    - `:metadata` - Additional context (map)

  ## File Location

  Failed operations are stored in:
    `data/network/failed_operations.json`

  ## Usage

      # Save a failure
      DLQ.save(:crawl, "https://2e.aonprd.com/Spells.aspx?ID=1", :timeout)

      # Load failures for a phase (oldest first)
      failures = DLQ.load(:crawl)

      # Get statistics
      DLQ.stats()
      #=> %{discovery: 0, crawl: 5, embed: 2, query: 0, total: 7}

      # Clear failures for a phase
      DLQ.clear(:crawl)

  """

  alias __MODULE__.FailedOperation

  @phases [:discovery, :crawl, :embed, :query]
  @default_data_dir "data/network"
  @default_filename "failed_operations.json"

  @type phase :: :discovery | :crawl | :embed | :query
  @type operation_id :: String.t()
  @type reason :: atom() | String.t()
  @type metadata :: map()
  @type t :: %__MODULE__.FailedOperation{
          phase: phase(),
          operation_id: operation_id(),
          reason: reason(),
          timestamp: integer(),
          metadata: metadata()
        }

  defmodule FailedOperation do
    @moduledoc false
    defstruct [:phase, :operation_id, :reason, :timestamp, :metadata]

    @type t :: %__MODULE__{
            phase: WebRAG.Network.DLQ.phase(),
            operation_id: WebRAG.Network.DLQ.operation_id(),
            reason: WebRAG.Network.DLQ.reason(),
            timestamp: integer(),
            metadata: WebRAG.Network.DLQ.metadata()
          }
  end

  @doc """
  Saves a failed operation to the dead-letter queue.

  ## Parameters

    - `phase` - The pipeline phase (`:discovery`, `:crawl`, `:embed`, `:query`)
    - `operation_id` - URL or operation identifier
    - `reason` - Error reason (atom or string)
    - `metadata` - Additional context (optional)

  ## Examples

      DLQ.save(:crawl, "https://example.com/page", :timeout, %{attempt: 3})
      :ok
  """
  @spec save(phase(), operation_id(), reason(), metadata()) :: :ok | {:error, term()}
  def save(phase, operation_id, reason, metadata \\ %{}) do
    unless phase in @phases do
      raise ArgumentError, "Invalid phase: #{inspect(phase)}. Must be one of: #{inspect(@phases)}"
    end

    operation = %FailedOperation{
      phase: phase,
      operation_id: operation_id,
      reason: normalize_reason(reason),
      timestamp: DateTime.utc_now() |> DateTime.to_unix(),
      metadata: metadata
    }

    :telemetry.execute(
      [:webrag, :dlq, :saved],
      %{count: 1},
      %{phase: phase, reason: operation.reason}
    )

    append_to_file(operation)
  end

  @doc """
  Loads failed operations for a phase or multiple phases, sorted oldest first.

  ## Examples

      iex> DLQ.load(:crawl)
      [%FailedOperation{...}, ...]

      iex> DLQ.load([:crawl, :discovery])
      [%FailedOperation{...}, ...]
  """
  @spec load(phase() | [phase()]) :: [t()]
  def load(phase) when is_atom(phase) do
    load([phase])
  end

  def load(phases) when is_list(phases) do
    case read_all() do
      {:ok, operations} ->
        operations
        |> Enum.filter(fn op -> op.phase in phases end)
        |> Enum.sort_by(fn op -> op.timestamp end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Loads all failed operations from all phases.

  ## Examples

      iex> DLQ.load_all()
      [%FailedOperation{...}, ...]
  """
  @spec load_all() :: [t()]
  def load_all do
    case read_all() do
      {:ok, operations} -> Enum.sort_by(operations, fn op -> op.timestamp end)
      {:error, _} -> []
    end
  end

  @doc """
  Returns statistics about the dead-letter queue.

  ## Examples

      iex> DLQ.stats()
      %{discovery: 2, crawl: 10, embed: 1, query: 0, total: 13}
  """
  @spec stats() :: %{phase() => non_neg_integer(), total: non_neg_integer()}
  def stats do
    all = load_all()

    stats =
      Enum.reduce(@phases, %{}, fn phase, acc ->
        Map.put(acc, phase, Enum.count(all, fn op -> op.phase == phase end))
      end)

    Map.put(stats, :total, length(all))
  end

  @doc """
  Clears (removes) all failed operations for a specific phase.

  ## Examples

      iex> DLQ.clear(:crawl)
      :ok
  """
  @spec clear(phase()) :: :ok
  def clear(phase) do
    case read_all() do
      {:ok, operations} ->
        remaining = Enum.reject(operations, fn op -> op.phase == phase end)
        write_all(remaining)

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Clears all failed operations from all phases.
  """
  @spec clear_all() :: :ok
  def clear_all do
    case read_all() do
      {:ok, _} ->
        write_all([])

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Marks an operation as successfully retried (removes from DLQ).

  ## Examples

      iex> DLQ.mark_retried(:crawl, "https://example.com")
      :ok
  """
  @spec mark_retried(phase(), operation_id()) :: :ok
  def mark_retried(phase, operation_id) do
    case read_all() do
      {:ok, operations} ->
        remaining =
          Enum.reject(operations, fn op ->
            op.phase == phase and op.operation_id == operation_id
          end)

        write_all(remaining)

        :telemetry.execute(
          [:webrag, :dlq, :retried],
          %{count: 1},
          %{phase: phase}
        )

        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Returns the count of failed operations for a phase.
  """
  @spec count(phase()) :: non_neg_integer()
  def count(phase) do
    length(load(phase))
  end

  @doc """
  Checks if there are any failed operations for a phase.
  """
  @spec any?(phase()) :: boolean()
  def any?(phase) do
    count(phase) > 0
  end

  @doc """
  Returns the oldest failed operation for a phase, if any.
  """
  @spec oldest(phase()) :: t() | nil
  def oldest(phase) do
    case load(phase) do
      [] -> nil
      [oldest | _] -> oldest
    end
  end

  @doc """
  Returns the most recent failed operation for a phase, if any.
  """
  @spec newest(phase()) :: t() | nil
  def newest(phase) do
    case load(phase) do
      [] -> nil
      operations -> List.last(operations)
    end
  end

  @doc """
  Exports failed operations to a specific file.
  """
  @spec export(String.t()) :: :ok | {:error, term()}
  def export(path) do
    case read_all() do
      {:ok, operations} ->
        operations
        |> Enum.map(&to_map/1)
        |> Jason.encode!(pretty: true)
        |> then(fn content -> File.write(path, content) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Imports failed operations from a file.
  """
  @spec import(String.t()) :: :ok | {:error, term()}
  def import(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_list(data) ->
            operations = Enum.map(data, &from_map/1)
            append_many(operations)
            :ok

          {:ok, _} ->
            {:error, :invalid_format}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_data_dir do
    Application.get_env(:webrag, WebRAG.Network.DLQ, [])
    |> Keyword.get(:data_dir, @default_data_dir)
  end

  defp get_filename do
    Application.get_env(:webrag, WebRAG.Network.DLQ, [])
    |> Keyword.get(:filename, @default_filename)
  end

  defp get_filepath do
    Path.join(get_data_dir(), get_filename())
  end

  defp ensure_directory do
    dir = get_data_dir()
    File.mkdir_p!(dir)
    dir
  end

  defp read_all do
    filepath = get_filepath()

    case File.read(filepath) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_list(data) ->
            operations = Enum.map(data, &from_map/1)
            {:ok, operations}

          {:ok, _} ->
            {:ok, []}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_all(operations) do
    ensure_directory()

    filepath = get_filepath()

    operations
    |> Enum.map(&to_map/1)
    |> Jason.encode!()
    |> then(fn content -> File.write(filepath, content) end)
  end

  defp append_to_file(operation) do
    ensure_directory()

    case read_all() do
      {:ok, operations} ->
        existing_ids = MapSet.new(operations, fn op -> {op.phase, op.operation_id} end)

        if MapSet.member?(existing_ids, {operation.phase, operation.operation_id}) do
          :ok
        else
          write_all(operations ++ [operation])
        end

      {:error, _} ->
        write_all([operation])
    end
  end

  defp append_many(new_operations) do
    ensure_directory()

    case read_all() do
      {:ok, existing} ->
        existing_ids = MapSet.new(existing, fn op -> {op.phase, op.operation_id} end)

        unique_new =
          Enum.reject(new_operations, fn op ->
            MapSet.member?(existing_ids, {op.phase, op.operation_id})
          end)

        write_all(existing ++ unique_new)

      {:error, _} ->
        write_all(new_operations)
    end
  end

  defp to_map(%FailedOperation{} = op) do
    %{
      "phase" => Atom.to_string(op.phase),
      "operation_id" => op.operation_id,
      "reason" => op.reason,
      "timestamp" => op.timestamp,
      "metadata" => op.metadata
    }
  end

  defp from_map(map) when is_map(map) do
    %FailedOperation{
      phase: String.to_atom(map["phase"]),
      operation_id: map["operation_id"],
      reason: map["reason"],
      timestamp: map["timestamp"],
      metadata: map["metadata"] || %{}
    }
  end

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)
end
