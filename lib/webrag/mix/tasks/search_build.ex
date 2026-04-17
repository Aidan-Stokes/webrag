defmodule Mix.Tasks.Search.Build do
  @moduledoc """
  Builds IDF (Inverse Document Frequency) index for TF-IDF scoring.

  This task is automatically run as part of `mix embed`. 
  Use this only if you need to rebuild the IDF index manually.

  ## Usage

      mix search.build
  """

  @shortdoc "Build IDF index (auto-runs with mix embed)"

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:webrag)

    # Load embed completion callback and run IDF build directly
    chunks = WebRAG.Storage.load_chunks()
    total_docs = length(chunks)

    Logger.info("Computing IDF for #{total_docs} chunks...")

    freq_map =
      Enum.reduce(chunks, %{}, fn chunk, acc ->
        terms =
          chunk.text
          |> String.downcase()
          |> String.replace(~r/[^\w\s]/, "")
          |> String.split()
          |> Enum.filter(fn w -> String.length(w) > 2 end)
          |> Enum.map(fn w -> stem_word(w) end)
          |> Enum.uniq()

        Enum.reduce(terms, acc, fn term, inner_acc ->
          Map.update(inner_acc, term, 1, &(&1 + 1))
        end)
      end)

    Logger.info("Found #{map_size(freq_map)} unique terms")

    idf_map =
      freq_map
      |> Enum.map(fn {term, freq} ->
        safe_freq = max(freq, 1)
        idf = :math.log(total_docs / safe_freq)
        {term, %{frequency: freq, idf: idf}}
      end)
      |> Map.new()

    # Save IDF
    json_path = Path.join(["data", "idf_terms.json"])

    data =
      idf_map
      |> Map.to_list()
      |> Enum.map(fn {term, d} -> %{term: term, frequency: d[:frequency], idf: d[:idf]} end)

    File.write!(json_path, Jason.encode!(data, pretty: true))
    Logger.info("IDF index saved to data/idf_terms.json")
  end

  defp stem_word(word) do
    String.replace(word, ~r/(s|es|ed|ing|'s|'s)$/, "")
  end
end
