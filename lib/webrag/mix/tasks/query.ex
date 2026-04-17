defmodule Mix.Tasks.Query do
  @moduledoc """
  Performs semantic search and generates an LLM response.

  ## Usage

      mix query "your question"

  ## Options

      - `--top-k <n>` - Number of results to return. Default: 5.

  ## Examples

      mix query "How does Shove work?"
      mix query "What happens on a critical hit?" --top-k 5
  """
  use Mix.Task

  alias WebRAG.Network.DLQ

  @shortdoc "Semantic search with LLM response"

  @default_top_k 5
  @default_chat_model "llama3"

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:webrag)

    {opts, query_args, _} =
      OptionParser.parse(args,
        switches: [
          top_k: :integer
        ],
        aliases: [k: :top_k]
      )

    query = Enum.join(query_args, " ")

    if query == "" do
      IO.puts("Usage: mix query \"your question here\"")
      exit({:shutdown, 1})
    end

    top_k = Keyword.get(opts, :top_k, @default_top_k)

    IO.puts("")
    IO.puts("==================")
    IO.puts("Query: #{query}")
    IO.puts("==================")
    IO.puts("")

    if !WebRAG.LLM.Ollama.available?() do
      IO.puts(:stderr, "ERROR: Ollama is not running!")
      IO.puts(:stderr, "Please start Ollama: ollama serve")
      exit({:shutdown, 1})
    end

    embeddings = WebRAG.Storage.load_embeddings()

    if length(embeddings) == 0 do
      IO.puts("No embeddings found!")
      IO.puts("Please run first:")
      IO.puts("  mix discover")
      IO.puts("  mix crawl")
      IO.puts("  mix index")
      IO.puts("  mix embed")
      exit({:shutdown, 1})
    end

    IO.puts("Searching #{length(embeddings)} embeddings...")

    case WebRAG.Search.search(query, top_k: top_k) do
      {:ok, []} ->
        IO.puts("No relevant results found.")

      {:ok, results} ->
        IO.puts("Found #{length(results)} relevant passages:")
        IO.puts("")

        context =
          results
          |> Enum.with_index(1)
          |> Enum.map(fn {result, i} ->
            """
            [Passage #{i} (score: #{Float.round(result.score, 3)}]
            #{result.text}
            """
          end)
          |> Enum.join("\n---\n")

        Enum.each(results, fn result ->
          IO.puts("---")
          IO.puts("Score: #{Float.round(result.score, 3)}")
          IO.puts("")
          IO.puts(result.text)
          IO.puts("")
        end)

        IO.puts("==================")
        IO.puts("Generating answer with Ollama...")
        IO.puts("==================")

        answer_query(query, context)
    end
  end

  defp answer_query(query, context) do
    system_prompt = """
    You are a helpful AI assistant answering questions about Pathfinder 2nd Edition rules, mechanics, and content.

    Your knowledge comes ONLY from the provided context passages. If the context does not contain
    enough information to answer the question, say so clearly.

    When answering questions about game mechanics, rules, or stats:
    - Quote specific rules or text from the context when relevant
    - Be precise with ability names, conditions, and mechanics
    - If multiple passages are relevant, synthesize them into a coherent answer

    Never make up information that isn't in the context. If you're unsure, say so.

    Context:
    #{context}

    Question: #{query}

    Provide a clear, accurate answer based on the context above. Include specific citations when relevant.
    """

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: query}
    ]

    case WebRAG.LLM.Ollama.chat(messages, model: @default_chat_model) do
      {:ok, response} ->
        IO.puts("")
        IO.puts("==================")
        IO.puts("ANSWER:")
        IO.puts("==================")
        IO.puts("")
        IO.puts(response.content)
        IO.puts("")

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        DLQ.save(:query, query, reason, %{})
        IO.puts("")
        IO.puts("Query saved for retry. Run 'mix network.retry --phase query' to retry.")
    end
  end
end
