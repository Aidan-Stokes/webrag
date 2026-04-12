defmodule Mix.Tasks.Query do
  @moduledoc """
  Query the Pathfinder 2e rules database.

  ## Usage

      mix query "your question here"

  ## Options

      - `--top-k` - Number of results (default: 3)
      - `--model` - Ollama chat model (default: llama3)

  ## Example

      mix query "How does Shove work?"
      mix query "What happens on a critical hit?" --top-k 5
  """
  use Mix.Task

  @shortdoc "Query the rules database"

  @default_top_k 3
  @default_chat_model "llama3"

  @impl true
  def run(args) do
    # Parse arguments as query string
    query = Enum.join(args, " ")

    if query == "" do
      IO.puts("Usage: mix query \"your question here\"")
      exit({:shutdown, 1})
    end

    IO.puts("")
    IO.puts("==================")
    IO.puts("Query: #{query}")
    IO.puts("==================")
    IO.puts("")

    # Initialize database
    AONCrawler.DB.init()

    # Check Ollama
    if !AONCrawler.LLM.Ollama.available?() do
      IO.puts(:stderr, "ERROR: Ollama is not running!")
      IO.puts(:stderr, "Please start Ollama: ollama serve")
      exit({:shutdown, 1})
    end

    # Check embeddings
    stats = AONCrawler.DB.stats()

    if stats.embeddings == 0 do
      IO.puts("No embeddings found!")
      IO.puts("Please run first:")
      IO.puts("  mix load_aon")
      IO.puts("  mix gen_embeddings")
      exit({:shutdown, 1})
    end

    IO.puts("Searching #{stats.embeddings} embeddings...")

    # Search
    case AONCrawler.Search.search(query, top_k: @default_top_k) do
      {:ok, []} ->
        IO.puts("No relevant results found.")

      {:ok, results} ->
        IO.puts("Found #{length(results)} relevant passages:")
        IO.puts("")

        # Build context from results
        context =
          results
          |> Enum.with_index(1)
          |> Enum.map(fn {result, i} ->
            """
            [Passage #{i} (score: #{Float.round(result["score"], 3)}]
            #{result["content"]}
            """
          end)
          |> Enum.join("\n---\n")

        # Display results
        Enum.each(results, fn result ->
          IO.puts("---")
          IO.puts("Score: #{Float.round(result["score"], 3)}")
          IO.puts("")
          IO.puts(result["content"])
          IO.puts("")
        end)

        IO.puts("==================")
        IO.puts("Generating answer with Ollama...")
        IO.puts("==================")

        # Generate answer using Ollama
        answer_query(query, context)
    end
  end

  defp answer_query(query, context) do
    system_prompt = """
    You are an expert Pathfinder 2nd Edition rules assistant.

    Your knowledge comes ONLY from the provided context passages. If the context does not contain
    enough information to answer the question, say so clearly.

    Never make up rules or mechanics that aren't in the context.

    Context:
    #{context}

    Question: #{query}

    Provide a clear, accurate answer based on the rules context above.
    """

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: query}
    ]

    case AONCrawler.LLM.Ollama.chat(messages, model: @default_chat_model) do
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
    end
  end
end
