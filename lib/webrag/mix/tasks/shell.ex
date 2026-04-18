defmodule Mix.Tasks.Shell do
  @moduledoc """
  Interactive search shell for querying your RAG system.

  ## Usage

      mix shell

  ## Commands

      Once in the shell:
      - Type your question and press Enter to search
      - :help - Show available commands
      - :source <domain> - Filter by source (e.g., :source aonprd)
      - :top <n> - Set number of results (e.g., :top 10)
      - :history - Show query history
      - :clear - Clear current results
      - :quit or :exit - Exit the shell

  ## Examples

      mix shell
      > What does shield block do?
      > :source finance.yahoo.com
      > AAPL earnings
      > :quit
  """
  use Mix.Task
  require Logger

  @shortdoc "Interactive search shell"

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:webrag)

    IO.puts("")
    IO.puts("╔═══════════════════════════════════════════════════╗")
    IO.puts("║           WebRAG Interactive Shell                 ║")
    IO.puts("║  Type your question or :help for commands         ║")
    IO.puts("╚═══════════════════════════════════════════════════╝")
    IO.puts("")
    IO.puts("Embeddings will load on first query...\n")

    state = %{
      history: [],
      source_filter: nil,
      top_k: 5,
      last_context: []
    }

    loop(state)
  end

  defp loop(state) do
    prompt = build_prompt(state)

    case IO.gets(prompt) do
      :eof ->
        IO.puts("\nGoodbye!")
        {:ok, state}

      {:error, reason} ->
        IO.puts("\nError: #{inspect(reason)}")
        {:ok, state}

      input ->
        input = String.trim(input)

        if input == "" do
          loop(state)
        else
          {new_state, cont} = process_input(input, state)
          if cont, do: loop(new_state), else: {:ok, new_state}
        end
    end
  end

  defp build_prompt(state) do
    source_str = if state.source_filter, do: " [#{state.source_filter}]", else: ""
    "❯#{source_str} "
  end

  defp process_input(":" <> cmd, state) do
    process_command(String.trim(cmd), state)
  end

  defp process_input(query, state) do
    IO.puts("")

    case WebRAG.Search.search(query, top_k: state.top_k, source: state.source_filter) do
      {:ok, []} ->
        IO.puts("  No results found.\n")
        {state, true}

      {:ok, results} ->
        display_results(results, query)

        IO.puts("Generate LLM answer? (y/n, default y, enter for yes): ")
        answer = IO.gets("")
        trimmed = String.downcase(String.trim(answer))

        # Default to yes if just enter pressed
        do_generate = trimmed == "" or trimmed == "y" or trimmed == "yes"

        if do_generate do
          generate_answer(query, results)
        end

        # Save to history
        new_history = [{query, length(results)} | state.history] |> Enum.take(50)

        {put_in(state.history, new_history), true}

      {:error, reason} ->
        IO.puts("  Error: #{inspect(reason)}\n")
        {state, true}
    end
  end

  defp generate_answer(query, results) do
    IO.puts("")
    IO.puts("─" |> String.duplicate(60))
    IO.puts("Generating answer from #{length(results)} passages...")
    IO.puts("─" |> String.duplicate(60))
    IO.puts("")

    context =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} ->
        "[Passage #{i} (source: #{r.metadata["url"]})]\n#{r.text}"
      end)
      |> Enum.join("\n\n---\n\n")

    system_prompt = """
    You are a helpful AI assistant answering questions based on the provided context.

    Context:
    #{context}

    Question: #{query}

    Provide a clear, accurate answer based on the context above.
    """

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: query}
    ]

    case WebRAG.LLM.Ollama.chat(messages, model: "llama3") do
      {:ok, response} ->
        IO.puts("ANSWER:")
        IO.puts("")
        IO.puts(response.content)
        IO.puts("")

      {:error, reason} ->
        IO.puts("Error generating answer: #{inspect(reason)}\n")
    end
  end

  defp process_command("help", state) do
    IO.puts("""
    Available commands:
      :quit, :exit     Exit the shell
      :clear           Clear the screen
      :history         Show query history
      :source <domain> Set source filter (e.g., :source aonprd, :source finance.yahoo.com)
      :source clear    Clear source filter
      :top <n>         Set number of results (default: 5)
      :stats           Show system statistics
      :reload          Reload embeddings
    """)

    {state, true}
  end

  defp process_command("quit", _state), do: {nil, false}
  defp process_command("exit", _state), do: {nil, false}

  defp process_command("clear", state) do
    System.cmd("clear", [])
    {state, true}
  end

  defp process_command("history", state) do
    IO.puts("Query history:")

    Enum.with_index(state.history, 1)
    |> Enum.each(fn {{query, count}, i} ->
      IO.puts("  #{i}. #{query} (#{count} results)")
    end)

    IO.puts("")
    {state, true}
  end

  defp process_command("stats", state) do
    IO.puts("System statistics:")
    IO.puts("  Chunks: #{WebRAG.Storage.count_chunks()}")
    IO.puts("  Embeddings: #{WebRAG.Storage.count_embeddings()}")
    IO.puts("  Documents: #{length(WebRAG.Storage.load_documents())}")
    IO.puts("  Current filter: #{state.source_filter || "none"}")
    IO.puts("")
    {state, true}
  end

  defp process_command("reload", state) do
    IO.puts("Reloading embeddings...")
    WebRAG.Indexer.VectorStore.clear()
    WebRAG.Indexer.VectorStore.load_embeddings()
    IO.puts("Done.\n")
    {state, true}
  end

  defp process_command("source", state) do
    IO.puts("Current source filter: #{state.source_filter || "none"}\n")
    IO.puts("Use :source <domain> to filter (e.g., :source aonprd)")
    IO.puts("Use :source clear to remove filter\n")
    {state, true}
  end

  defp process_command("source clear", state) do
    IO.puts("Source filter cleared.\n")
    {put_in(state.source_filter, nil), true}
  end

  defp process_command("source " <> domain, state) do
    domain = String.trim(domain)

    if domain == "" do
      IO.puts("Usage: :source <domain>\n")
    else
      IO.puts("Filtering by source: #{domain}\n")
    end

    {put_in(state.source_filter, domain), true}
  end

  defp process_command("top " <> n_str, state) do
    n = String.trim(n_str) |> String.to_integer()

    if n > 0 and n <= 50 do
      IO.puts("Top K set to #{n}\n")
      {put_in(state.top_k, n), true}
    else
      IO.puts("Invalid number. Use :top <n> where n is 1-50\n")
      {state, true}
    end
  rescue
    _ ->
      IO.puts("Invalid number. Use :top <n> where n is 1-50\n")
      {state, true}
  end

  defp process_command(cmd, state) do
    IO.puts("Unknown command: :#{cmd}\n")
    IO.puts("Type :help for available commands\n")
    {state, true}
  end

  defp display_results(results, _query) do
    IO.puts("─" |> String.duplicate(60))

    Enum.with_index(results, 1)
    |> Enum.each(fn {r, i} ->
      score_color =
        cond do
          r.score >= 0.7 -> IO.ANSI.green()
          r.score >= 0.5 -> IO.ANSI.yellow()
          true -> IO.ANSI.red()
        end

      IO.puts(
        "#{IO.ANSI.green()}[#{i}]#{IO.ANSI.reset()} #{score_color}Score: #{Float.round(r.score, 2)}#{IO.ANSI.reset()}"
      )

      if r.metadata && r.metadata["url"] do
        IO.puts("    #{IO.ANSI.cyan()}#{r.metadata["url"]}#{IO.ANSI.reset()}")
      end

      # Truncate text display
      text =
        if String.length(r.text) > 400 do
          String.slice(r.text, 0, 400) <> "..."
        else
          r.text
        end

      IO.puts("    #{text}")
      IO.puts("")
    end)

    IO.puts("─" |> String.duplicate(60))
    IO.puts("Found #{length(results)} results")
    IO.puts("")
  end

  defp wait_for_load(attempts) when attempts >= 60 do
    :ok
  end

  defp wait_for_load(attempts) do
    if WebRAG.Indexer.VectorStore.loaded?() do
      :ok
    else
      IO.write(".")
      Process.sleep(500)
      wait_for_load(attempts + 1)
    end
  end
end
