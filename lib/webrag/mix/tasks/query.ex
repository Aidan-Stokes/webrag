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
  alias WebRAG.UI

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

    UI.write_header("Semantic Search", [
      {"Query", query},
      {"Top K", top_k}
    ])

    if !WebRAG.LLM.Ollama.available?() do
      UI.error("Ollama is not running!")
      IO.puts(:stderr, "Please start Ollama: ollama serve")
      exit({:shutdown, 1})
    end

    embeddings = WebRAG.Storage.load_embeddings()

    if length(embeddings) == 0 do
      UI.error("No embeddings found!")
      IO.puts("Please run first:")
      IO.puts("  mix discover")
      IO.puts("  mix crawl")
      IO.puts("  mix index")
      IO.puts("  mix embed")
      exit({:shutdown, 1})
    end

    IO.puts("#{UI.ANSI.gray()}Searching #{length(embeddings)} embeddings...#{UI.ANSI.reset()}")

    case WebRAG.Search.search(query, top_k: top_k) do
      {:ok, []} ->
        UI.warn("No relevant results found.")

      {:ok, results} ->
        UI.section("Search Results (#{length(results)} found)")
        IO.puts("")

        results
        |> Enum.with_index(1)
        |> Enum.each(fn {result, i} ->
          UI.format_result(result, i, truncate: true, show_breakdown: true)
          IO.puts("#{UI.ANSI.gray()}#{String.duplicate("─", 60)}#{UI.ANSI.reset()}")
        end)

        # Print best passage at end
        if length(results) > 0 do
          best = Enum.max_by(results, fn r -> r.score end)
          UI.section("Best Passage")
          IO.puts("#{UI.ANSI.green()}Score: #{Float.round(best.score, 3)}#{UI.ANSI.reset()}")
          IO.puts("")
          IO.puts(best.text)
        end

        IO.puts("")
        UI.section("Generating Answer")

        answer_query(query, results)
    end
  end

  defp answer_query(query, results) do
    context =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {result, i} ->
        UI.format_passage(result, i)
      end)
      |> Enum.join("\n---\n")

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
        UI.section("Answer")
        IO.puts("")
        IO.puts(response.content)
        IO.puts("")

      {:error, reason} ->
        UI.error("Query failed: #{inspect(reason)}")
        DLQ.save(:query, query, reason, %{})
        IO.puts("")
        IO.puts("Query saved for retry. Run 'mix network.retry --phase query' to retry.")
    end
  end
end
