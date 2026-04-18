defmodule WebRAG.LLM.Client do
  @moduledoc """
  LLM client for generating rule-based responses using Ollama.

  This module provides the interface for interacting with Ollama LLMs to answer
  Pathfinder 2e rules questions. It handles:

  - **Prompt Construction**: Builds context-grounded prompts from retrieved content
  - **API Communication**: Interfaces with Ollama local models
  - **Response Parsing**: Extracts and formats responses with reasoning
  - **Error Handling**: Gracefully handles failures with fallbacks

  ## Architecture

  The LLM client sits between the Retriever and the user:
  1. User query → Retriever → Context → LLM.Client → Answer + reasoning + citations
  2. Falls back to "I don't know" when context is insufficient

  ## Usage

      # Direct query
      {:ok, response} = Client.query("How does the Shove action work?")

      # With options
      {:ok, response} = Client.query(
        "Fireball damage",
        model: "llama3",
        temperature: 0.3,
        top_k: 3
      )

      # Response includes answer and sources
      %{text: answer, reasoning: reasoning, sources: sources} = response
  """

  use GenServer
  require Logger

  alias WebRAG.Types
  alias WebRAG.Retriever.SearchService
  alias WebRAG.LLM.Ollama
  alias WebRAG.Storage

  @default_model "llama3"
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

  - `:model` - LLM model to use (default: "llama3")
  - `:temperature` - Sampling temperature (default: 0.3)
  - `:max_tokens` - Maximum tokens in response (default: 1500)
  - `:top_k` - Number of context results (default: 5)
  - `:min_score` - Minimum similarity threshold (default: 0.7)

  ## Returns

  `{:ok, Types.LLMResponse.t()}` on success

  ## Example

      iex> Client.query("How does Shove work?")
      {:ok, %Types.LLMResponse{
        text: "Shove is an Athletics action...",
        reasoning: "Let me analyze the rules for Shove...",
        sources: ["https://2e.aonprd.com/Actions.aspx?ID=1"],
        model: "llama3"
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
    Ollama.available?()
  end

  @doc """
  Returns whether Ollama is available.
  """
  @spec available?() :: boolean()
  def available? do
    Ollama.available?()
  end

  @doc """
  Returns available Ollama models.
  """
  @spec models() :: {:ok, [map()]} | {:error, term()}
  def models do
    Ollama.models()
  end

  @doc """
  Starts a new conversation and returns the conversation ID.
  """
  @spec start_conversation(String.t() | nil) :: {:ok, map()}
  def start_conversation(title \\ nil) do
    id = Storage.new_conversation_id()

    conversation = %{
      "id" => id,
      "title" => title || "New Conversation",
      "model" => @default_model,
      "messages_count" => 0,
      "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Storage.save_conversation(conversation)

    {:ok, conversation}
  end

  @doc """
  Continues a conversation by adding a user message and getting AI response.
  """
  @spec continue_conversation(String.t(), String.t(), keyword()) :: {:ok, map(), map()}
  def continue_conversation(conversation_id, question, opts \\ []) do
    conversation = Storage.load_conversation(conversation_id)

    if is_nil(conversation) do
      {:error, :conversation_not_found}
    else
      model = Keyword.get(opts, :model, conversation["model"] || @default_model)
      temperature = Keyword.get(opts, :temperature, @default_temperature)
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
      top_k = Keyword.get(opts, :top_k, @default_top_k)
      min_score = Keyword.get(opts, :min_score, 0.7)

      messages = build_conversation_messages(conversation, question)

      with {:ok, context, _results} <-
             SearchService.search_with_context(question, top_k: top_k, min_score: min_score),
           {:ok, context} <- build_context_with_history(question, context, messages),
           {:ok, llm_response} <-
             call_llm_with_messages(context,
               model: model,
               temperature: temperature,
               max_tokens: max_tokens
             ) do
        user_message = %{
          "id" => UUID.uuid4(),
          "role" => "user",
          "content" => question,
          "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        assistant_message = %{
          "id" => UUID.uuid4(),
          "role" => "assistant",
          "content" => llm_response.text,
          "reasoning" => llm_response.reasoning,
          "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        Storage.save_message(conversation_id, user_message)
        Storage.save_message(conversation_id, assistant_message)

        title =
          if is_nil(conversation["title"]) or conversation["title"] == "New Conversation" do
            if String.length(question) > 50 do
              String.slice(question, 0, 50) <> "..."
            else
              question
            end
          else
            conversation["title"]
          end

        updated_conversation = Map.put(conversation, "title", title)
        Storage.save_conversation(updated_conversation)

        {:ok, llm_response, updated_conversation}
      else
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Loads a conversation and its messages.
  """
  @spec load_conversation(String.t()) :: {:ok, map(), [map()]} | {:error, :not_found}
  def load_conversation(conversation_id) do
    conversation = Storage.load_conversation(conversation_id)

    if is_nil(conversation) do
      {:error, :not_found}
    else
      messages = Storage.load_messages(conversation_id)
      {:ok, conversation, messages}
    end
  end

  @doc """
  Lists all conversations.
  """
  @spec list_conversations() :: [map()]
  def list_conversations do
    Storage.list_conversations()
  end

  @doc """
  Deletes a conversation.
  """
  @spec delete_conversation(String.t()) :: :ok
  def delete_conversation(conversation_id) do
    Storage.delete_conversation(conversation_id)
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

    Logger.info("LLM.Client started with Ollama")
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
     Show your step-by-step reasoning before giving the final answer.
     If the context doesn't contain enough information, say so explicitly.
     """}
  end

  defp call_llm(prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    messages = [
      %{role: "system", content: prompt},
      %{role: "user", content: "Please answer the question above."}
    ]

    case Ollama.chat(messages, model: model, temperature: temperature, max_tokens: max_tokens) do
      {:ok, response} ->
        {:ok, parse_response(response, model)}

      {:error, reason} ->
        Logger.error("Ollama API error", error: inspect(reason))
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("LLM call failed", error: inspect(e))
      {:error, e}
  end

  defp parse_response(response, model) do
    content = Map.get(response, :content, "")

    {reasoning, text} = parse_reasoning_and_text(content)

    %Types.LLMResponse{
      text: text,
      reasoning: reasoning,
      model: model,
      finish_reason: "stop",
      usage: %{
        "prompt_tokens" => 0,
        "completion_tokens" => 0,
        "total_tokens" => 0
      },
      sources: [],
      latency_ms: 0,
      inserted_at: DateTime.utc_now()
    }
  end

  defp parse_reasoning_and_text(content) do
    reasoning_pattern = ~r/REASONING:(.*?)(?:FINAL ANSWER:|$)/is
    answer_pattern = ~r/FINAL ANSWER:(.*?)$/is

    reasoning =
      case Regex.run(reasoning_pattern, content) do
        nil -> nil
        [_, r] -> String.trim(r)
      end

    text =
      case Regex.run(answer_pattern, content) do
        nil -> content
        [_, t] -> String.trim(t)
      end

    {reasoning, text}
  end

  defp build_conversation_messages(conversation, _current_question) do
    messages_dir =
      Path.join([Storage.data_dir(), "conversations", conversation["id"], "messages"])

    if File.exists?(messages_dir) do
      Path.wildcard(Path.join(messages_dir, "*.json"))
      |> Enum.map(fn path ->
        case File.read(path) do
          {:ok, data} -> Jason.decode!(data, keys: :strings)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1["inserted_at"])
    else
      []
    end
  end

  defp build_context_with_history(question, context, previous_messages) do
    system_prompt = Types.default_system_prompt()

    history =
      previous_messages
      |> Enum.map(fn msg ->
        "#{msg["role"]}: #{msg["content"]}"
      end)
      |> Enum.join("\n\n")

    {:ok,
     """
     #{system_prompt}

     ---

     Conversation History:
     #{if history == "", do: "(No previous messages)", else: history}

     ---

     Relevant Rules Context:
     #{context}

     ---

     Current Question: #{question}

     Please provide a clear, accurate answer based on the rules context above and conversation history.
     Show your step-by-step reasoning before giving the final answer.
     If the context doesn't contain enough information, say so explicitly.
     """}
  end

  defp call_llm_with_messages(prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    messages = [
      %{role: "system", content: prompt}
    ]

    case Ollama.chat(messages, model: model, temperature: temperature, max_tokens: max_tokens) do
      {:ok, response} ->
        {:ok, parse_response(response, model)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, e}
  end
end
