defmodule WebRAG.LLM.Ollama do
  @moduledoc """
  Ollama client for local embeddings and chat using System.cmd for reliability.
  """

  @base_url "http://localhost:11434"
  @default_embedding_model "mxbai-embed-large"
  @default_chat_model "llama3"

  @doc """
  Generates an embedding for text using Ollama.
  """
  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    model = Keyword.get(opts, :model, @default_embedding_model)

    result = curl_embed(model, text)

    case result do
      {:ok, %{"embedding" => embedding}} ->
        {:ok, embedding}

      {:ok, %{"error" => error}} ->
        {:error, error}

      error ->
        error
    end
  end

  @doc """
  Generates embeddings for multiple texts.
  """
  @spec embed_batch([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    model = Keyword.get(opts, :model, @default_embedding_model)

    results =
      Enum.map(texts, fn text ->
        case curl_embed(model, text) do
          {:ok, %{"embedding" => embedding}} -> {:ok, embedding}
          {:ok, %{"error" => _}} -> {:error, :api_error}
          _ -> {:error, :curl_error}
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
      {:error, :partial_failure}
    end
  end

  @doc """
  Sends a chat completion request to Ollama.
  """
  @spec chat([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []) do
    model = Keyword.get(opts, :model, @default_chat_model)
    temperature = Keyword.get(opts, :temperature, 0.3)
    max_tokens = Keyword.get(opts, :max_tokens, 1500)

    body = %{
      model: model,
      messages: messages,
      temperature: temperature,
      max_tokens: max_tokens,
      stream: false
    }

    result = curl_post("#{@base_url}/api/chat", body)

    case result do
      {:ok, %{"message" => %{"content" => content}}} ->
        {:ok, %{content: content, model: model, done: true}}

      {:ok, %{"error" => error}} ->
        {:error, error}

      _ ->
        {:error, :curl_failed}
    end
  end

  @doc """
  Checks if Ollama is running and accessible.
  """
  @spec available?() :: boolean()
  def available? do
    case curl_get("#{@base_url}/api/tags") do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Returns available models from Ollama.
  """
  @spec models() :: {:ok, [map()]} | {:error, term()}
  def models do
    case curl_get("#{@base_url}/api/tags") do
      {:ok, %{"models" => models}} -> {:ok, models}
      {:ok, %{"error" => error}} -> {:error, error}
      _ -> {:error, :curl_failed}
    end
  end

  @doc """
  Returns embedding dimension for current model.
  """
  @spec embedding_dimensions() :: pos_integer()
  def embedding_dimensions, do: 768

  # Curl helpers

  defp curl_embed(model, text) do
    json = Jason.encode!(%{model: model, prompt: text})

    case System.cmd("curl", [
           "-s",
           "-X",
           "POST",
           "-H",
           "Content-Type: application/json",
           "-d",
           json,
           "#{@base_url}/api/embeddings"
         ]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, json}
          _ -> {:error, :parse_error}
        end

      {output, _} ->
        case Jason.decode(output) do
          {:ok, %{"error" => error}} -> {:error, error}
          _ -> {:error, :curl_error}
        end
    end
  end

  defp curl_post(url, body) do
    json = Jason.encode!(body)

    case System.cmd("curl", [
           "-s",
           "-X",
           "POST",
           "-H",
           "Content-Type: application/json",
           "-d",
           json,
           url
         ]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, json}
          _ -> {:error, :parse_error}
        end

      {output, _} ->
        case Jason.decode(output) do
          {:ok, %{"error" => error}} -> {:error, error}
          _ -> {:error, :curl_error}
        end
    end
  end

  defp curl_get(url) do
    case System.cmd("curl", ["-s", url]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, json}
          _ -> {:error, :parse_error}
        end

      {_, _} ->
        {:error, :curl_error}
    end
  end
end
