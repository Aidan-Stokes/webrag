defmodule Mix.Tasks.Search.BuildIdf do
  @moduledoc """
  Builds IDF (Inverse Document Frequency) index for TF-IDF scoring.

  This analyzes all indexed chunks to compute how rare/common each term is,
  which improves search relevance by boosting rare terms and penalizing common ones.

  ## Usage

      mix search.build_idf

  ## What it does

  1. Loads all indexed chunks
  2. Extracts unique terms from each chunk
  3. Computes IDF scores: log(total_chunks / documents_containing_term)
  4. Saves IDF data to data/idf_terms.pb

  Run this after:
  - Running mix embed (to index new content)
  - Any data crawl/index cycle

  ## Examples

      mix search.build_idf
  """
  use Mix.Task
  require Logger

  alias WebRAG.Search.IDFScorer

  @shortdoc "Build IDF index for search"

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:webrag)

    Logger.info("Building IDF index...")

    chunks = WebRAG.Storage.load_chunks()

    if length(chunks) == 0 do
      Logger.error("No chunks found. Run mix embed first.")
      exit({:shutdown, 1})
    end

    Logger.info("Analyzing #{length(chunks)} chunks...")

    idf_map = IDFScorer.compute_idf(chunks)

    Logger.info("Computed #{map_size(idf_map)} unique terms")

    # Save to storage
    json_path = Path.join(["data", "idf_terms.json"])

    data =
      idf_map
      |> Map.to_list()
      |> Enum.map(fn {term, d} -> %{term: term, frequency: d[:frequency], idf: d[:idf]} end)

    File.write!(json_path, Jason.encode!(data, pretty: true))
    Logger.info("IDF index saved to data/idf_terms.json")

    # Show some example IDF scores
    example_terms = ["orc", "boost", "attribute", "character", "genie", "spell", "mechanics"]
    Logger.info("Sample IDF scores:")

    Enum.each(example_terms, fn term ->
      data = Map.get(idf_map, term)

      if data do
        Logger.info("  #{term}: frequency=#{data[:frequency]}, idf=#{Float.round(data[:idf], 3)}")
      else
        Logger.info("  #{term}: not found")
      end
    end)
  end
end
