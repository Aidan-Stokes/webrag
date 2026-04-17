defmodule Mix.Tasks.Index do
  @moduledoc """
  Chunks documents into smaller pieces for embedding.

  Uses hybrid chunking that snaps to sentence boundaries while respecting
  the maximum chunk size. This improves semantic coherence of chunks.

  ## Usage

      mix index

  ## Options

      - `--chunk-size <n>` - Maximum characters per chunk. Default: 1000.
      - `--overlap <n>` - Character overlap between chunks. Default: 100.
      - `--min-chunk-size <n>` - Minimum characters before forcing cut. Default: 200.

  ## Examples

      mix index
      mix index --chunk-size 500 --overlap 50
      mix index --chunk-size 1500 --min-chunk-size 300
  """
  use Mix.Task

  @shortdoc "Chunk documents for embedding"

  @default_chunk_size 1000
  @default_overlap 100
  @default_min_chunk_size 200

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:webrag)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          chunk_size: :integer,
          overlap: :integer,
          min_chunk_size: :integer
        ],
        aliases: [c: :chunk_size, o: :overlap, m: :min_chunk_size]
      )

    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    overlap = Keyword.get(opts, :overlap, @default_overlap)
    min_chunk_size = Keyword.get(opts, :min_chunk_size, @default_min_chunk_size)

    IO.puts("==================")
    IO.puts("Index Phase - Chunking Documents")
    IO.puts("==================")
    IO.puts("Chunk size: #{chunk_size} characters (max)")
    IO.puts("Min chunk size: #{min_chunk_size} characters (force cut below this)")
    IO.puts("Overlap: #{overlap} characters")
    IO.puts("")

    :ok = WebRAG.Storage.ensure_directories()

    documents = WebRAG.Storage.load_documents()

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

    Enum.each(chunks, &WebRAG.Storage.append_chunk/1)

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
    min_size = Application.get_env(:webrag, :min_chunk_size, @default_min_chunk_size)

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
      {chunk_text, remaining} = split_at_sentence_boundary(text, chunk_size, min_size)

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

  defp split_at_sentence_boundary(text, max_size, min_size) do
    if String.length(text) <= max_size do
      {text, ""}
    else
      chunk_candidate = String.slice(text, 0, max_size)

      sentence_endings = [
        {". ", 2},
        {"! ", 2},
        {".\n", 2},
        {"!\n", 2},
        {".\r\n", 3},
        {"!\r\n", 3},
        {"? ", 2},
        {"?\n", 2},
        {"?\r\n", 3},
        {") ", 2},
        {")\n", 2}
      ]

      {best_pos, best_dist} =
        Enum.reduce(sentence_endings, {max_size, :infinity}, fn {ending, len}, {pos, dist} ->
          parts = String.split(chunk_candidate, ending, trailing: false)

          if length(parts) > 1 do
            prefix = Enum.take(parts, length(parts) - 1) |> Enum.join(ending)
            idx = String.length(prefix)
            actual_pos = idx + len
            distance = abs(actual_pos - max_size)

            if distance < dist do
              {actual_pos, distance}
            else
              {pos, dist}
            end
          else
            {pos, dist}
          end
        end)

      cond do
        best_dist != :infinity and best_pos >= min_size ->
          {String.slice(text, 0, best_pos), String.slice(text, best_pos, String.length(text))}

        best_pos < min_size ->
          {String.slice(text, 0, max_size), String.slice(text, max_size, String.length(text))}

        true ->
          {chunk_candidate, String.slice(text, max_size, String.length(text))}
      end
    end
  end
end
