defmodule Mix.Tasks.Index do
  @moduledoc """
  Chunks documents into smaller pieces for embedding.

  ## Usage

      mix index

  ## Options

      - `--chunk-size <n>` - Maximum characters per chunk. Default: 1000.
      - `--overlap <n>` - Character overlap between chunks. Default: 100.

  ## Examples

      mix index
      mix index --chunk-size 500 --overlap 50
  """
  use Mix.Task

  @shortdoc "Chunk documents for embedding"

  @default_chunk_size 1000
  @default_overlap 100

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:aoncrawler)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          chunk_size: :integer,
          overlap: :integer
        ],
        aliases: [c: :chunk_size, o: :overlap]
      )

    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    overlap = Keyword.get(opts, :overlap, @default_overlap)

    IO.puts("==================")
    IO.puts("Index Phase - Chunking Documents")
    IO.puts("==================")
    IO.puts("Chunk size: #{chunk_size} characters")
    IO.puts("Overlap: #{overlap} characters")
    IO.puts("")

    :ok = AONCrawler.Storage.ensure_directories()

    documents = AONCrawler.Storage.load_documents()

    if Enum.empty?(documents) do
      IO.puts(:stderr, "No documents found. Run: mix crawl")
      exit({:shutdown, 1})
    end

    IO.puts("Loaded #{length(documents)} documents")
    IO.puts("Creating chunks...")
    IO.puts("")

    chunks =
      documents
      |> Enum.flat_map(fn doc ->
        chunk_document(doc, chunk_size, overlap)
      end)

    IO.puts("Created #{length(chunks)} chunks")

    Enum.each(chunks, &AONCrawler.Storage.append_chunk/1)

    IO.puts("")
    IO.puts("Indexing complete!")
    IO.puts("Run: mix embed")
  end

  defp chunk_document(doc, chunk_size, overlap) do
    text = Map.get(doc, :text, "") || ""

    if String.trim(text) == "" do
      []
    else
      do_chunk_text(text, Map.get(doc, :id, ""), doc, chunk_size, overlap, 0, [])
    end
  end

  defp do_chunk_text("", _doc_id, _doc, _chunk_size, _overlap, _index, acc) do
    Enum.reverse(acc)
  end

  defp do_chunk_text(text, doc_id, doc, chunk_size, overlap, index, acc) do
    if String.length(text) <= chunk_size do
      chunk = %{
        id: "#{doc_id}_chunk_#{index}",
        document_id: doc_id,
        text: String.trim(text),
        chunk_index: index,
        total_chunks: index + 1,
        metadata: %{
          url: Map.get(doc, :url, ""),
          source: to_string(Map.get(doc, :content_type, "unknown"))
        }
      }

      Enum.reverse([chunk | acc])
    else
      chunk_text = String.slice(text, 0, chunk_size)
      remaining = String.slice(text, chunk_size - overlap, String.length(text))

      chunk = %{
        id: "#{doc_id}_chunk_#{index}",
        document_id: doc_id,
        text: String.trim(chunk_text),
        chunk_index: index,
        total_chunks: index + 1,
        metadata: %{
          url: Map.get(doc, :url, ""),
          source: to_string(Map.get(doc, :content_type, "unknown"))
        }
      }

      do_chunk_text(remaining, doc_id, doc, chunk_size, overlap, index + 1, [chunk | acc])
    end
  end
end
