defmodule Mix.Tasks.Transform do
  @moduledoc """
  Transforms Protocol Buffer files to JSON for debugging/inspection.

  ## Usage

      mix transform

  Reads .pb files and exports to human-readable .json files.
  This command only exports - use `mix compact` for deduplication.

  ## Options

      --type <type>      Export only specific type: documents, chunks, embeddings, or all

  ## Examples

      mix transform
      mix transform --type chunks
      mix transform --type all
  """
  use Mix.Task

  @shortdoc "Export .pb files to JSON"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          type: :string
        ]
      )

    IO.puts("==================")
    IO.puts("Transform Phase - Exporting .pb to JSON")
    IO.puts("==================")
    IO.puts("")

    :ok = WebRAG.Storage.ensure_directories()

    type = Keyword.get(opts, :type, "all")

    export_type(type)

    stats = WebRAG.Storage.stats()
    IO.puts("")
    IO.puts("Data Summary:")
    IO.puts("  Documents: #{stats.documents}")
    IO.puts("  Chunks: #{stats.chunks}")
    IO.puts("  Embeddings: #{stats.embeddings}")
    IO.puts("")
    IO.puts("Transform complete!")
  end

  defp export_type("documents") do
    documents = WebRAG.Storage.load_documents()

    if documents != [],
      do: write_json(Path.join(["data", "documents", "documents.json"]), documents)

    IO.puts("  Exported #{length(documents)} documents")
  end

  defp export_type("chunks") do
    chunks = WebRAG.Storage.load_chunks()
    if chunks != [], do: write_json(Path.join(["data", "chunks", "chunks.json"]), chunks)
    IO.puts("  Exported #{length(chunks)} chunks")
  end

  defp export_type("embeddings") do
    embeddings = WebRAG.Storage.load_embeddings()

    if embeddings != [],
      do: write_json(Path.join(["data", "embeddings", "embeddings.json"]), embeddings)

    IO.puts("  Exported #{length(embeddings)} embeddings")
  end

  defp export_type(_all) do
    WebRAG.Storage.export_to_json()
  end

  defp write_json(path, data) do
    File.write!(path, Jason.encode!(data, pretty: true))
  end
end
