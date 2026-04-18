defmodule Mix.Tasks.Shell do
  @moduledoc """
  Interactive chat shell for the RAG system with conversation memory.

  ## Usage

      mix shell

  ## Features

  - Chat with the LLM using your Pathfinder 2e knowledge base
  - Conversation memory persisted across sessions
  - Chain-of-thought reasoning display
  - File picker to include custom documents in context

  ## Commands

      Once in the shell:
      - Type your question and press Enter to chat
      - :help - Show available commands
      - :new - Start a new conversation
      - :conversations - List past conversations
      - :load <id> - Load a past conversation
      - :delete <id> - Delete a conversation
      - :files - Open file browser to add documents
      - :files list - Show included files
      - :files clear - Remove included files
      - :source <domain> - Filter by source
      - :top <n> - Set number of context results
      - :clear - Clear the screen
      - :quit or :exit - Exit the shell

  ## Examples

      mix shell
      > What does shield block do?
      > :new
      > How do cantrips scale?
      > :load abc123
      > :quit
  """
  use Mix.Task
  require Logger

  @shortdoc "Interactive chat shell with memory"

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:webrag)

    IO.puts("")
    IO.puts("╔═══════════════════════════════════════════════════╗")
    IO.puts("║      WebRAG Chat - Pathfinder 2e Assistant       ║")
    IO.puts("║  Type your question or :help for commands         ║")
    IO.puts("╚═══════════════════════════════════════════════════╝")
    IO.puts("")
    IO.puts("Embeddings will load on first query...\n")

    state = %{
      current_conversation_id: nil,
      included_files: [],
      source_filter: nil,
      top_k: 5
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
    conv_info =
      if state.current_conversation_id do
        " [Conversation]"
      else
        ""
      end

    file_info =
      if length(state.included_files) > 0 do
        " [#{length(state.included_files)} file(s)]"
      else
        ""
      end

    source_str = if state.source_filter, do: " [#{state.source_filter}]", else: ""

    "❯#{conv_info}#{file_info}#{source_str} "
  end

  defp process_input(":" <> cmd, state) do
    process_command(String.trim(cmd), state)
  end

  defp process_input(query, state) do
    IO.puts("")

    response =
      if state.current_conversation_id do
        WebRAG.LLM.Client.continue_conversation(
          state.current_conversation_id,
          query,
          top_k: state.top_k,
          min_score: 0.7
        )
      else
        case WebRAG.LLM.Client.start_conversation(nil) do
          {:ok, conversation} ->
            new_id = conversation["id"]

            result =
              WebRAG.LLM.Client.continue_conversation(
                new_id,
                query,
                top_k: state.top_k,
                min_score: 0.7
              )

            case result do
              {:ok, _response, _conv} -> {:ok, response: _response, conversation_id: new_id}
              _ -> result
            end
        end
      end

    case response do
      {:ok, response: llm_response, conversation_id: new_id} ->
        display_response(llm_response)
        {put_in(state.current_conversation_id, new_id), true}

      {:ok, _llm_response, _conversation} ->
        display_response(_llm_response)
        {state, true}

      {:error, reason} ->
        IO.puts("  Error: #{inspect(reason)}\n")
        {state, true}
    end
  end

  defp display_response(response) do
    if response.reasoning && response.reasoning != "" do
      IO.puts(IO.ANSI.cyan() <> "Reasoning:" <> IO.ANSI.reset())
      IO.puts("  " <> IO.ANSI.light_black() <> response.reasoning <> IO.ANSI.reset())
      IO.puts("")
      IO.puts(IO.ANSI.green() <> "Answer:" <> IO.ANSI.reset())
      IO.puts("  " <> response.text)
    else
      IO.puts(IO.ANSI.green() <> "Answer:" <> IO.ANSI.reset())
      IO.puts("  " <> response.text)
    end

    IO.puts("")
    IO.puts(IO.ANSI.light_black() <> "Model: #{response.model}" <> IO.ANSI.reset())
    IO.puts("")
  end

  defp process_command("help", state) do
    IO.puts("""
    Available commands:
      :quit, :exit     Exit the shell
      :clear           Clear the screen
      :new             Start a new conversation
      :conversations   List all conversations
      :load <id>       Load a conversation by ID
      :delete <id>     Delete a conversation
      :files           Open file browser
      :files list      Show included files
      :files clear     Remove all included files
      :source <domain> Filter by source (e.g., :source aonprd)
      :source clear    Clear source filter
      :top <n>         Set number of results (default: 5)
      :stats           Show system statistics
      :reload          Reload embeddings
    """)

    {state, true}
  end

  defp process_command("quit", _state), do: {nil, false}
  defp process_command("exit", _state), do: {nil, false}

  defp process_command("new", state) do
    case WebRAG.LLM.Client.start_conversation(nil) do
      {:ok, conversation} ->
        IO.puts("Started new conversation: #{conversation["id"]}\n")
        {put_in(state.current_conversation_id, conversation["id"]), true}

      {:error, reason} ->
        IO.puts("Error starting conversation: #{inspect(reason)}\n")
        {state, true}
    end
  end

  defp process_command("conversations", state) do
    conversations = WebRAG.LLM.Client.list_conversations()

    if length(conversations) == 0 do
      IO.puts("No conversations yet.\n")
    else
      IO.puts("Conversations:")
      IO.puts(String.duplicate("-", 50))

      Enum.each(conversations, fn conv ->
        id = conv["id"] |> String.slice(0, 8)
        title = conv["title"] || "Untitled"
        count = conv["messages_count"] || 0
        updated = conv["updated_at"] || conv["inserted_at"] || "unknown"

        IO.puts("  #{id}... | #{count} messages | #{title}")
        IO.puts("         Updated: #{updated}")
      end)
    end

    IO.puts("")
    {state, true}
  end

  defp process_command("load", state) do
    IO.puts("Enter conversation ID: ")
    id = IO.gets("") |> String.trim()

    if id == "" do
      IO.puts("No ID provided.\n")
      {state, true}
    else
      case WebRAG.LLM.Client.load_conversation(id) do
        {:ok, conversation, messages} ->
          IO.puts("Loaded conversation: #{conversation["title"]}\n")
          IO.puts("Messages: #{length(messages)}\n")

          display_conversation_history(messages)

          {put_in(state.current_conversation_id, id), true}

        {:error, :not_found} ->
          IO.puts("Conversation not found.\n")
          {state, true}
      end
    end
  end

  defp display_conversation_history(messages) do
    IO.puts("")
    IO.puts("Conversation history:")
    IO.puts(String.duplicate("-", 50))

    Enum.each(messages, fn msg ->
      role = msg["role"]
      content = msg["content"] |> String.slice(0, 200)

      if role == "user" do
        IO.puts(IO.ANSI.blue() <> "You: " <> IO.ANSI.reset() <> content)
      else
        IO.puts(IO.ANSI.green() <> "Assistant: " <> IO.ANSI.reset() <> content)
      end

      if msg["reasoning"] && msg["reasoning"] != "" do
        IO.puts(
          IO.ANSI.light_black() <> "  (Reasoning: " <> msg["reasoning"] <> ")" <> IO.ANSI.reset()
        )
      end
    end)

    IO.puts("")
  end

  defp process_command("delete", state) do
    IO.puts("Enter conversation ID to delete: ")
    id = IO.gets("") |> String.trim()

    if id == "" do
      IO.puts("No ID provided.\n")
      {state, true}
    else
      case WebRAG.LLM.Client.load_conversation(id) do
        {:ok, conversation, _} ->
          IO.puts("Delete conversation '#{conversation["title"]}'? (y/n)")
          confirm = IO.gets("") |> String.downcase() |> String.trim()

          if confirm == "y" do
            WebRAG.LLM.Client.delete_conversation(id)
            IO.puts("Deleted.\n")

            new_state =
              if state.current_conversation_id == id do
                put_in(state.current_conversation_id, nil)
              else
                state
              end

            {new_state, true}
          else
            IO.puts("Cancelled.\n")
            {state, true}
          end

        {:error, :not_found} ->
          IO.puts("Conversation not found.\n")
          {state, true}
      end
    end
  end

  defp process_command("files", state) do
    {new_state, _} = WebRAG.FileBrowser.run_file_picker(state)
    {new_state, true}
  end

  defp process_command("files list", state) do
    if length(state.included_files) == 0 do
      IO.puts("No files included.\n")
    else
      IO.puts("Included files:")

      Enum.each(state.included_files, fn file ->
        IO.puts("  - #{file}")
      end)

      IO.puts("")
    end

    {state, true}
  end

  defp process_command("files clear", state) do
    IO.puts("Cleared included files.\n")
    {put_in(state.included_files, []), true}
  end

  defp process_command("clear", state) do
    System.cmd("clear", [])
    {state, true}
  end

  defp process_command("stats", state) do
    IO.puts("System statistics:")
    IO.puts("  Chunks: #{WebRAG.Storage.count_chunks()}")
    IO.puts("  Embeddings: #{WebRAG.Storage.count_embeddings()}")
    IO.puts("  Documents: #{length(WebRAG.Storage.load_documents())}")
    IO.puts("  Conversations: #{length(WebRAG.LLM.Client.list_conversations())}")
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
end
