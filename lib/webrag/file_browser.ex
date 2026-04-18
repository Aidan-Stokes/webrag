defmodule WebRAG.FileBrowser do
  @moduledoc """
  Interactive file browser for selecting files to include in LLM context.

  Supports both CLI (numbered menu) and fzf modes.
  """

  @doc """
  Runs the file picker and returns updated state with included files.
  """
  @spec run_file_picker(map()) :: {map(), boolean()}
  def run_file_picker(state) do
    IO.puts("")
    IO.puts("═══ File Browser ═══")
    IO.puts("Select files to include in LLM context")
    IO.puts("")

    {current_files, selected_path} = run_picker_loop(state.included_files, state.included_files)

    if selected_path do
      updated_files = Enum.uniq(current_files ++ [selected_path])
      IO.puts("Added: #{selected_path}\n")
      {put_in(state.included_files, updated_files), true}
    else
      {state, true}
    end
  end

  defp run_picker_loop(current_files, _all_files) do
    home_dir = System.get_env("HOME") || "/home"
    default_path = Path.join(home_dir, "documents")

    initial_path =
      if File.exists?(default_path) do
        default_path
      else
        home_dir
      end

    IO.puts("Current directory: #{initial_path}")
    IO.puts("")

    entries = list_directory(initial_path)

    if length(entries) == 0 do
      IO.puts("Empty directory.\n")
      {current_files, nil}
    else
      display_entries(entries)
      IO.puts("")
      IO.puts("Enter number to select file, 'b' to go back, 'q' to quit,")
      IO.puts("'p <path>' to go to a specific path, or 'a' to add selected and quit:")

      input = IO.gets("") |> String.trim()

      case input do
        "q" ->
          {current_files, nil}

        "b" ->
          parent = Path.dirname(initial_path)

          if parent != initial_path do
            run_picker_loop(current_files, current_files)
          else
            {current_files, nil}
          end

        "a" ->
          {current_files, nil}

        "p " <> path ->
          full_path =
            if String.starts_with?(path, "/"), do: path, else: Path.join(initial_path, path)

          if File.exists?(full_path) && File.dir?(full_path) do
            run_picker_loop(current_files, current_files)
          else
            IO.puts("Invalid path: #{full_path}\n")
            run_picker_loop(current_files, current_files)
          end

        "" ->
          run_picker_loop(current_files, current_files)

        num ->
          case Integer.parse(num) do
            {:ok, idx} ->
              if idx >= 1 && idx <= length(entries) do
                entry = Enum.at(entries, idx - 1)

                if entry.is_dir do
                  run_picker_loop(current_files, current_files)
                else
                  {current_files, entry.path}
                end
              else
                IO.puts("Invalid selection.\n")
                run_picker_loop(current_files, current_files)
              end

            _ ->
              IO.puts("Invalid input.\n")
              run_picker_loop(current_files, current_files)
          end
      end
    end
  end

  defp list_directory(path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.map(entries, fn entry ->
          full_path = Path.join(path, entry)

          is_dir =
            case File.dir?(full_path) do
              true -> true
              _ -> false
            end

          %{name: entry, path: full_path, is_dir: is_dir}
        end)
        |> Enum.sort(fn a, b ->
          case {a.is_dir, b.is_dir} do
            {true, false} -> true
            {false, true} -> false
            _ -> a.name <= b.name
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp display_entries(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.each(fn {entry, idx} ->
      if entry.is_dir do
        IO.puts("  #{IO.ANSI.blue()}#{idx}: 📁 #{entry.name}/#{IO.ANSI.reset()}")
      else
        ext = Path.extname(entry.name)
        icon = file_icon(ext)
        size = get_file_size(entry.path)
        IO.puts("  #{idx}: #{icon} #{entry.name} (#{size})")
      end
    end)
  end

  defp file_icon(".md"), do: "📝"
  defp file_icon(".txt"), do: "📄"
  defp file_icon(".pdf"), do: "📕"
  defp file_icon(".json"), do: "📋"
  defp file_icon(".xml"), do: "📋"
  defp file_icon(".html"), do: "🌐"
  defp file_icon(".ex"), do: "🔧"
  defp file_icon(".exs"), do: "🔧"
  defp file_icon(_), do: "📄"

  defp get_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size < 1024 -> "#{size} B"
      {:ok, %{size: size}} when size < 1024 * 1024 -> "#{div(size, 1024)} KB"
      {:ok, %{size: size}} -> "#{div(size, 1024 * 1024)} MB"
      _ -> "unknown"
    end
  end

  @doc """
  Reads content from a file.
  """
  @spec read_file(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read file: #{inspect(reason)}"}
    end
  end
end
