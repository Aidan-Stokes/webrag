defmodule Mix.Tasks.LoadAon do
  @moduledoc """
  Loads Pathfinder 2e data from aon_docs.jsonl into the database.

  ## Usage

      mix load_aon

  ## Options

      - `--file` - Path to JSONL file (default: aon_docs.jsonl in project root)
      - `--chunk-size` - Words per chunk (default: 150)
      - `--overlap` - Word overlap between chunks (default: 20)

  ## Example

      mix load_aon
      mix load_aon --file ./my_data.jsonl --chunk-size 200
  """
  use Mix.Task

  @shortdoc "Load AoN data into database"

  @chunk_size 150
  @overlap 20

  @impl true
  def run(args) do
    IO.puts("==================")
    IO.puts("Loading Pathfinder 2e data from Archives of Nethys...")
    IO.puts("==================")

    # Parse options
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          file: :string,
          chunk_size: :integer,
          overlap: :integer
        ],
        aliases: [f: :file, c: :chunk_size, o: :overlap]
      )

    file = Keyword.get(opts, :file, "aon_docs.jsonl")
    chunk_size = Keyword.get(opts, :chunk_size, @chunk_size)
    overlap = Keyword.get(opts, :overlap, @overlap)

    # Initialize database
    IO.puts("Initializing database...")
    AONCrawler.DB.init()

    # Check if already loaded
    stats = AONCrawler.DB.stats()

    if stats.documents > 0 do
      IO.puts("Database already has #{stats.documents} documents, #{stats.chunks} chunks")
      response = IO.gets("Load again? (y/N): ")

      if String.downcase(String.trim(response)) != "y" do
        IO.puts("Skipping load.")
        :ok
      else
        do_load(file, chunk_size, overlap)
      end
    else
      do_load(file, chunk_size, overlap)
    end
  end

  defp do_load(file, chunk_size, overlap) do
    # Check file exists
    unless File.exists?(file) do
      IO.puts(:stderr, "File not found: #{file}")
      IO.puts(:stderr, "Please provide a valid JSONL file path.")
      exit({:shutdown, 1})
    end

    IO.puts("Loading from: #{file}")
    IO.puts("Chunk size: #{chunk_size} words, overlap: #{overlap}")

    # Read and parse JSONL
    IO.puts("Parsing JSONL...")

    documents =
      file
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line ->
        case Jason.decode(line) do
          {:ok, doc} -> doc
          _ -> nil
        end
      end)
      |> Stream.reject(&is_nil/1)
      |> Enum.to_list()

    IO.puts("Parsed #{length(documents)} documents")

    # Save documents
    IO.puts("Saving documents...")
    Enum.each(documents, &AONCrawler.DB.save_document/1)

    # Chunk documents
    IO.puts("Chunking documents...")

    chunks =
      documents
      |> Stream.flat_map(fn doc ->
        chunk_text(doc["text"] || "", doc["url"] || "", chunk_size, overlap)
      end)
      |> Enum.to_list()

    IO.puts("Created #{length(chunks)} chunks")

    # Save chunks
    IO.puts("Saving chunks...")
    AONCrawler.DB.save_chunks_list(chunks)

    # Print stats
    stats = AONCrawler.DB.stats()

    IO.puts("")
    IO.puts("==================")
    IO.puts("Done! Database stats:")
    IO.puts("  Documents: #{stats.documents}")
    IO.puts("  Chunks: #{stats.chunks}")
    IO.puts("  Embeddings: #{stats.embeddings}")
    IO.puts("==================")
  end

  # Chunks text into smaller pieces
  defp chunk_text("", _url, _size, _overlap), do: []

  defp chunk_text(text, url, chunk_size, overlap) do
    # Clean text
    text =
      text
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    words = String.split(text, " ", trim: true)
    word_count = length(words)

    if word_count == 0 do
      []
    else
      do_chunk_words(words, url, chunk_size, overlap, 0, [])
      |> Enum.with_index()
      |> Enum.map(fn {chunk_words, index} ->
        content = Enum.join(chunk_words, " ")

        %{
          "id" => "#{url}_chunk_#{index}",
          "document_id" => url,
          "content" => content,
          "chunk_index" => index,
          "total_chunks" => length(words),
          "word_count" => length(chunk_words)
        }
      end)
    end
  end

  defp do_chunk_words([], _url, _chunk_size, _overlap, _index, acc) do
    Enum.reverse(acc)
  end

  defp do_chunk_words(words, url, chunk_size, overlap, index, acc) do
    chunk = Enum.take(words, chunk_size)
    remaining = Enum.drop(words, chunk_size - overlap)
    new_acc = [chunk | acc]

    if length(chunk) < chunk_size || length(remaining) == 0 do
      do_chunk_words([], url, chunk_size, overlap, index + 1, new_acc)
    else
      do_chunk_words(remaining, url, chunk_size, overlap, index + 1, new_acc)
    end
  end
end
