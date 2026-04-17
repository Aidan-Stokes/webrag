defmodule AONCrawler.Indexer.EmbeddingClient do
  @moduledoc """
  Client for generating text embeddings via OpenAI API.

  This module provides a simple interface for:
  - Generating embeddings for text chunks
  - Generating embeddings for queries
  - Batching embeddings for efficiency

  ## Supported Models

  - `text-embedding-3-small` (1536 dimensions, fastest, cheapest)
  - `text-embedding-3-large` (3072 dimensions, best quality)
  - `text-embedding-ada-002` (1536 dimensions, legacy)

  ## Usage

      # Single text embedding
      {:ok, vector} = EmbeddingClient.embed("Fireball deals fire damage")

      # Batch embeddings
      {:ok, vectors} = EmbeddingClient.embed_batch([
        "Fireball deals fire damage",
        "Lightning bolt strikes"
      ])

  ## Design Decisions

  1. **Batching**: Automatically batches multiple texts for efficiency
  2. **Error Handling**: Provides clear error messages for failures
  3. **Token Counting**: Estimates tokens for batch size limits
  """

  require Logger

  @default_model "text-embedding-3-small"
  @max_batch_size 100

  @doc """
  Generates an embedding for a single text.

  ## Parameters

  - `text` - The text to embed

  ## Options

  - `:model` - Embedding model (default: "text-embedding-3-small")

  ## Returns

  `{:ok, [float()]}` on success

  ## Example

      iex> EmbeddingClient.embed("Fireball")
      {:ok, [0.023, -0.012, ...]}
  """
  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    model = Keyword.get(opts, :model, @default_model)

    case embed_single(text, model) do
      {:ok, embedding} ->
        {:ok, embedding}

      {:error, reason} ->
        Logger.error("Embedding failed", error: inspect(reason), text: String.slice(text, 0, 50))
        {:error, reason}
    end
  end

  @doc """
  Generates embeddings for multiple texts in a batch.

  More efficient than calling embed/2 multiple times.

  ## Parameters

  - `texts` - List of texts to embed
  - `opts` - Options

  ## Options

  - `:model` - Embedding model (default: "text-embedding-3-small")
  - `:batch_size` - Max texts per request (default: 100)

  ## Returns

  `{:ok, [[float()]]}` on success

  ## Example

      iex> EmbeddingClient.embed_batch(["Fireball", "Lightning bolt"])
      {:ok, [[0.023, ...], [0.015, ...]]}
  """
  @spec embed_batch([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    model = Keyword.get(opts, :model, @default_model)
    batch_size = Keyword.get(opts, :batch_size, @max_batch_size)

    client = openai_client()

    if client do
      case client do
        AONCrawler.LLM.Ollama ->
          ollama_model =
            Application.get_env(:aoncrawler, [:indexer, :embedding_model], "mxbai-embed-large")

          do_embed_batch_ollama(texts, ollama_model, batch_size)

        _ ->
          texts
          |> Enum.chunk_every(batch_size)
          |> Enum.flat_map(fn batch ->
            case embed_batch_request(batch, model) do
              {:ok, embeddings} ->
                embeddings

              {:error, reason} ->
                Logger.error("Batch embedding failed", error: inspect(reason))
                []
            end
          end)
          |> then(fn
            [] -> {:error, :all_batches_failed}
            embeddings -> {:ok, embeddings}
          end)
      end
    else
      {:error, :not_configured}
    end
  end

  defp do_embed_batch_ollama(texts, model, _batch_size) do
    results =
      Enum.map(texts, fn text ->
        case AONCrawler.LLM.Ollama.embed(text, model: model) do
          {:ok, embedding} -> {:ok, embedding}
          {:error, _} -> {:error, :failed}
        end
      end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, emb} -> emb end)

    if length(results) == length(texts) do
      {:ok, results}
    else
      {:error, :all_batches_failed}
    end
  end

  @doc """
  Returns the embedding dimension for a model.
  """
  @spec dimensions(String.t()) :: pos_integer()
  def dimensions(model) do
    case model do
      "text-embedding-3-small" -> 1536
      "text-embedding-3-large" -> 3072
      "text-embedding-ada-002" -> 1536
      _ -> 1536
    end
  end

  @doc """
  Returns whether the client is configured.
  """
  @spec ready?() :: boolean()
  def ready? do
    api_key = Application.get_env(:aoncrawler, :openai_api_key)
    api_key not in [nil, ""]
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp embed_single(text, model) do
    client = openai_client()

    if client do
      case client do
        AONCrawler.LLM.Ollama ->
          client.embed(text, model: model)

        _ ->
          case client.embedding_create(%{
                 model: model,
                 input: text
               }) do
            {:ok, response} ->
              embedding = extract_embedding(response)
              {:ok, embedding}

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      {:error, :not_configured}
    end
  rescue
    _e in KeyError ->
      {:error, :not_configured}

    e ->
      {:error, e}
  end

  defp embed_batch_request(texts, model) do
    client = openai_client()

    if client do
      case client do
        AONCrawler.LLM.Ollama ->
          client.embed_batch(texts, model: model)

        _ ->
          case client.embedding_create(%{
                 model: model,
                 input: texts
               }) do
            {:ok, response} ->
              embeddings = extract_batch_embeddings(response)
              {:ok, embeddings}

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      {:error, :not_configured}
    end
  rescue
    _e in KeyError ->
      {:error, :not_configured}

    e ->
      {:error, e}
  end

  defp extract_embedding(response) do
    response
    |> Map.get(:data, [])
    |> List.first()
    |> Map.get(:embedding, [])
  end

  defp extract_batch_embeddings(response) do
    response
    |> Map.get(:data, [])
    |> Enum.sort_by(fn item -> Map.get(item, :index, 0) end)
    |> Enum.map(fn item -> Map.get(item, :embedding, []) end)
  end

  defp openai_client do
    case Application.get_env(:aoncrawler, :openai_client) do
      nil ->
        if Application.get_env(:aoncrawler, :use_ollama, true) do
          AONCrawler.LLM.Ollama
        end

      client ->
        client
    end
  end
end
