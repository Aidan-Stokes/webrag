defmodule WebRAG.API.Controller do
  @moduledoc """
  Controller for API requests.

  Handles HTTP requests and delegates to appropriate services.
  """

  use Phoenix.Controller, formats: [:json]
  require Logger

  alias WebRAG.LLM.Client
  alias WebRAG.Retriever.SearchService

  plug(:accepts, ["json"])

  @doc """
  Handles query POST requests.

  Expected body:
      %{
        "question": "How does shove work?"
      }

  Optional:
      - "model" - LLM model
      - "top_k" - Number of context results
  """
  def query(conn, params) do
    question = Map.get(params, "question")

    if question do
      opts =
        [
          model: Map.get(params, "model"),
          temperature: Map.get(params, "temperature"),
          top_k: Map.get(params, "top_k", 5),
          min_score: Map.get(params, "min_score", 0.7)
        ]
        |> Enum.reject(fn {_, v} -> v == nil end)
        |> Enum.into(%{})

      case Client.query(question, opts) do
        {:ok, response} ->
          json(conn, %{
            success: true,
            answer: response.text,
            model: response.model,
            sources: response.sources,
            metadata: %{
              total_tokens: response.usage["total_tokens"],
              latency_ms: response.latency_ms
            }
          })

        {:error, reason} ->
          Logger.error("Query failed", error: inspect(reason))

          conn
          |> put_status(500)
          |> json(%{
            success: false,
            error: "Query failed",
            reason: inspect(reason)
          })
      end
    else
      conn
      |> put_status(400)
      |> json(%{
        success: false,
        error: "Missing required field: question"
      })
    end
  end

  @doc """
  Health check endpoint.
  """
  def health(conn, _params) do
    json(conn, %{
      status: "healthy",
      version: "0.1.0",
      services: %{
        llm_client: Client.ready?(),
        embedding_client: WebRAG.Indexer.EmbeddingClient.ready?()
      }
    })
  end

  @doc """
  System statistics endpoint.
  """
  def stats(conn, _params) do
    json(conn, %{
      crawler:
        WebRAG.Crawler.Coordinator.get_stats() |> Map.take([:status, :pending, :completed]),
      retriever: SearchService.stats() |> Map.take([:total_queries, :successful_queries]),
      llm: Client.stats() |> Map.take([:total_queries, :successful_queries])
    })
  end
end
