defmodule AONCrawler.LLM.Client do
  @moduledoc """
  LLM client for generating rule-based responses.

  This module provides the interface for interacting with LLMs to answer
  Pathfinder 2e rules questions. It handles:

  - **Prompt Construction**: Builds context-grounded prompts from retrieved content
  - **API Communication**: Interfaces with OpenAI or other LLM providers
  - **Response Parsing**: Extracts and formats responses with citations
  - **Error Handling**: Gracefully handles failures with fallbacks

  ## Architecture

  The LLM client sits between the Retriever and the user:
  1. User query → Retriever → Context → LLM.Client → Answer + citations
  2. Falls back to "I don't know" when context is insufficient

  ## Usage

      # Direct query
      {:ok, response} = Client.query("How does the Shove action work?")

      # With options
      {:ok, response} = Client.query(
        "Fireball damage",
        model: "gpt-4-turbo",
        temperature: 0.3,
        top_k: 3
      )

      # Response includes answer and sources
      %{text: answer, sources: sources} = response

  ## Design Decisions

  1. **Grounding**: Prompts are strictly grounded in retrieved context
  2. **Conservative**: Prefers "I don't know" over hallucinations
  3. **Source Citations**: Includes source references in responses
  4. **Structured Output**: Returns a well-defined response struct
  """

  use GenServer
  require Logger

  alias AONCrawler.Types
  alias AONCrawler.Retriever.SearchService

  @default_model "gpt-4-turbo"
  @default_temperature 0.3
  @default_max_tokens 1500
  @default_top_k 5

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the LLM client.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Answers a rules question using RAG.

  ## Parameters

  - `question` - The user's question
  - `opts` - Query options

  ## Options

  - `:model` - LLM model to use (default: "gpt-4-turbo")
  - `:temperature` - Sampling temperature (default: 0.3)
  - `:max_tokens` - Maximum tokens in response (default: 1500)
  - `:top_k` - Number of context results (default: 5)
  - `:min_score` - Minimum similarity threshold (default: 0.7)

  ## Returns

  `{:ok, Types.LLMResponse.t()}` on success

  ## Example

      iex> Client.query("How does Shove work?")
      {:ok, %Types.LLMResponse{
        text: "Shove is aAthletics action...",
        sources: ["https://2e.aonprd.com/Actions.aspx?ID=1"],
        model: "gpt-4-turbo"
      }}
  """
  @spec query(String.t(), keyword()) :: {:ok, Types.llm_response()} | {:error, term()}
  def query(question, opts \\ []) when is_binary(question) do
    GenServer.call(__MODULE__, {:query, question, opts}, 120_000)
  end

  @doc """
  Answers a question synchronously without GenServer overhead.
  """
  @spec query_sync(String.t(), keyword()) :: {:ok, Types.llm_response()} | {:error, term()}
  def query_sync(question, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    min_score = Keyword.get(opts, :min_score, 0.7)

    with {:ok, context, _results} <-
           SearchService.search_with_context(question, top_k: top_k, min_score: min_score),
         {:ok, context} <- build_context(question, context) do
      call_llm(context, model: model, temperature: temperature, max_tokens: max_tokens)
    else
      {:error, reason} ->
        Logger.error("Query failed", error: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Returns the client's statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Checks if the LLM client is configured and ready.
  """
  @spec ready?() :: boolean()
  def ready? do
    configured?() && api_key_present?()
  end

  @doc """
  Returns whether the client has an API key configured.
  """
  @spec api_key_present?() :: boolean()
  def api_key_present? do
    Application.get_env(:aoncrawler, :openai_api_key) not in [nil, ""]
  end

  @doc """
  Returns whether the client is configured.
  """
  @spec configured?() :: boolean()
  def configured? do
    case openai_client() do
      nil -> false
      _ -> true
    end
  end

  # ============================================================================
  # Server Implementation
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      total_queries: 0,
      successful_queries: 0,
      failed_queries: 0,
      total_tokens: 0,
      avg_latency_ms: 0
    }

    Logger.info("LLM.Client started")
    {:ok, state}
  end

  @impl true
  def handle_call({:query, question, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    result = query_sync(question, opts)

    query_time_ms = System.monotonic_time(:millisecond) - start_time

    new_state =
      case result do
        {:ok, response} ->
          %{
            state
            | total_queries: state.total_queries + 1,
              successful_queries: state.successful_queries + 1,
              total_tokens: state.total_tokens + (response.usage["total_tokens"] || 0),
              avg_latency_ms:
                (state.avg_latency_ms * state.successful_queries + query_time_ms) /
                  (state.successful_queries + 1)
          }

        {:error, _} ->
          %{
            state
            | total_queries: state.total_queries + 1,
              failed_queries: state.failed_queries + 1
          }
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_context(_question, context) when context == "" or context == nil do
    {:ok,
     """
     The question cannot be answered based on the available rules content.
     Respond that you don't have enough information from the provided rules to answer this question.
     """}
  end

  defp build_context(question, context) do
    system_prompt = Types.default_system_prompt()

    {:ok,
     """
     #{system_prompt}

     ---

     Relevant Rules Context:
     #{context}

     ---

     User Question: #{question}

     Please provide a clear, accurate answer based on the rules context above.
     If the context doesn't contain enough information, say so explicitly.
     """}
  end

  defp call_llm(prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    client = openai_client()

    case client.chat_completion(%{
           model: model,
           messages: [
             %{role: "system", content: prompt}
           ],
           temperature: temperature,
           max_tokens: max_tokens
         }) do
      {:ok, response} ->
        {:ok, parse_response(response)}

      {:error, reason} ->
        Logger.error("OpenAI API error", error: inspect(reason))
        {:error, reason}
    end
  rescue
    e in KeyError ->
      Logger.error("OpenAI client not configured", error: inspect(e))
      {:error, :not_configured}

    e ->
      Logger.error("LLM call failed", error: inspect(e))
      {:error, e}
  end

  defp parse_response(response) do
    message = Map.get(response, :choices, []) |> List.first() |> Map.get(:message, %{})

    usage = Map.get(response, :usage, %{})

    %Types.LLMResponse{
      text: Map.get(message, :content, ""),
      model: Map.get(response, :model, @default_model),
      finish_reason: Map.get(message, :finish_reason, "stop"),
      usage: %{
        "prompt_tokens" => Map.get(usage, :prompt_tokens, 0),
        "completion_tokens" => Map.get(usage, :completion_tokens, 0),
        "total_tokens" => Map.get(usage, :total_tokens, 0)
      },
      sources: [],
      latency_ms: 0,
      inserted_at: DateTime.utc_now()
    }
  end

  defp openai_client do
    Application.get_env(:aoncrawler, :openai_client)
  end
end
