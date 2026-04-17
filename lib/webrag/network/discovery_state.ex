defmodule WebRAG.Network.DiscoveryState do
  @moduledoc """
  Manages discovery state persistence for resumable crawling.

  Saves and loads discovery progress so that interrupted discovery
  sessions can be resumed from where they left off.
  """

  @state_dir "data/network"

  defstruct [
    :source_id,
    :seed_urls,
    :discovered_urls,
    :frontier,
    :current_depth,
    :max_depth,
    :max_urls,
    :last_updated
  ]

  @type t :: %__MODULE__{
          source_id: atom(),
          seed_urls: [String.t()],
          discovered_urls: [String.t()],
          frontier: [String.t()],
          current_depth: non_neg_integer(),
          max_depth: :unlimited | non_neg_integer(),
          max_urls: non_neg_integer(),
          last_updated: DateTime.t()
        }

  @doc """
  Saves discovery state to disk.
  """
  @spec save(t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = state) do
    File.mkdir_p!(@state_dir)

    path = state_path(state.source_id)

    state_json = %{
      source_id: state.source_id,
      seed_urls: state.seed_urls,
      discovered_urls: state.discovered_urls,
      frontier: state.frontier,
      current_depth: state.current_depth,
      max_depth: state.max_depth,
      max_urls: state.max_urls,
      last_updated: state.last_updated |> DateTime.to_iso8601()
    }

    case Jason.encode(state_json, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Loads discovery state from disk.
  """
  @spec load(atom()) :: {:ok, t()} | {:error, :not_found}
  def load(source_id) do
    path = state_path(source_id)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} ->
            state = %{
              source_id: Map.fetch!(map, "source_id") |> String.to_atom(),
              seed_urls: Map.fetch!(map, "seed_urls"),
              discovered_urls: Map.fetch!(map, "discovered_urls"),
              frontier: Map.fetch!(map, "frontier"),
              current_depth: Map.fetch!(map, "current_depth"),
              max_depth: decode_max_depth(Map.fetch!(map, "max_depth")),
              max_urls: Map.fetch!(map, "max_urls"),
              last_updated: parse_datetime(Map.fetch!(map, "last_updated"))
            }

            {:ok, struct(__MODULE__, state)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if a saved state exists for the given source.
  """
  @spec exists?(atom()) :: boolean()
  def exists?(source_id) do
    File.exists?(state_path(source_id))
  end

  @doc """
  Deletes saved state for a source.
  """
  @spec delete(atom()) :: :ok
  def delete(source_id) do
    path = state_path(source_id)

    if File.exists?(path) do
      File.rm!(path)
    end

    :ok
  end

  @doc """
  Lists all saved discovery states.
  """
  @spec list_sources() :: [atom()]
  def list_sources do
    File.mkdir_p!(@state_dir)

    Path.wildcard(Path.join(@state_dir, "discovery_*.json"))
    |> Enum.map(fn path ->
      path
      |> Path.basename(".json")
      |> String.replace_prefix("discovery_", "")
      |> String.to_atom()
    end)
  end

  @doc """
  Creates a new discovery state.
  """
  @spec new(atom(), [String.t()], keyword()) :: t()
  def new(source_id, seed_urls, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, :unlimited)
    max_urls = Keyword.get(opts, :max_urls, 100_000)

    %__MODULE__{
      source_id: source_id,
      seed_urls: seed_urls,
      discovered_urls: [],
      frontier: seed_urls,
      current_depth: 0,
      max_depth: max_depth,
      max_urls: max_urls,
      last_updated: DateTime.utc_now()
    }
  end

  @doc """
  Updates the state with newly discovered URLs and frontier.
  """
  @spec update(t(), [String.t()], [String.t()], non_neg_integer()) :: t()
  def update(state, discovered, frontier, current_depth) do
    %{
      state
      | discovered_urls: discovered,
        frontier: frontier,
        current_depth: current_depth,
        last_updated: DateTime.utc_now()
    }
  end

  defp state_path(source_id) do
    Path.join(@state_dir, "discovery_#{source_id}.json")
  end

  defp decode_max_depth("unlimited"), do: :unlimited
  defp decode_max_depth(n) when is_integer(n), do: n

  defp parse_datetime(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, datetime, _} -> datetime
      _ -> DateTime.utc_now()
    end
  end
end
