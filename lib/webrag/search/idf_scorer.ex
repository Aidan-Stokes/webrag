defmodule WebRAG.Search.IDFScorer do
  @moduledoc """
  TF-IDF scoring for improved search relevance.

  IDF (Inverse Document Frequency) measures how rare/common a term is across
  your indexed chunks. Rare terms get higher weight, common terms get lower weight.

  This is computed once when building the index, then used for scoring.
  """

  @doc """
  Computes IDF scores for all terms in the given chunks.

  Returns a map of term => idf_score.
  """
  def compute_idf(chunks) do
    total_docs = length(chunks)
    IO.puts("Computing IDF for #{total_docs} chunks...")

    # Single pass: build frequency map
    freq_map =
      Enum.reduce(chunks, %{}, fn chunk, acc ->
        terms =
          chunk.text
          |> String.downcase()
          |> String.replace(~r/[^\w\s]/, "")
          |> String.split()
          |> Enum.filter(fn w -> String.length(w) > 2 end)
          |> Enum.map(&stem_word/1)
          |> Enum.uniq()

        Enum.reduce(terms, acc, fn term, inner_acc ->
          Map.update(inner_acc, term, 1, &(&1 + 1))
        end)
      end)

    IO.puts("Found #{map_size(freq_map)} unique terms")

    # Compute IDF scores
    freq_map
    |> Enum.map(fn {term, freq} ->
      safe_freq = max(freq, 1)
      idf = :math.log(total_docs / safe_freq)
      {term, %{frequency: freq, idf: idf}}
    end)
    |> Map.new()
  end

  @doc """
  Calculates TF-IDF score for a chunk given query keywords.

  Returns a score based on sum of IDF weights for matching terms.
  """
  def tf_idf_score(query_keywords, chunk_text, idf_map) do
    chunk_lower = String.downcase(chunk_text)

    query_keywords
    |> Enum.reduce(0.0, fn kw, acc ->
      term_matches = String.contains?(chunk_lower, kw)

      if term_matches do
        idf_data = Map.get(idf_map, kw, %{idf: 0})
        acc + idf_data[:idf]
      else
        acc
      end
    end)
  end

  @doc """
  Computes hybrid score combining embedding similarity with TF-IDF.
  """
  def hybrid_score(embed_score, tfidf_score, idf_map) do
    # Normalize TF-IDF score to 0-1 range based on max possible
    max_idf = idf_max(idf_map)
    normalized = if max_idf > 0, do: tfidf_score / max_idf, else: 0

    embed_weight = 0.7
    (1 - embed_weight) * embed_score + embed_weight * normalized
  end

  # Extract unique stemmed terms from all chunks
  defp extract_unique_terms(chunks) do
    chunks
    |> Enum.flat_map(fn chunk ->
      chunk.text
      |> String.downcase()
      |> String.replace(~r/[^\w\s]/, "")
      |> String.split()
      |> Enum.filter(fn w -> String.length(w) > 2 end)
      |> Enum.map(&stem_word/1)
    end)
    |> Enum.uniq()
  end

  # Count how many chunks contain a term
  defp count_documents_containing(chunks, term) do
    Enum.count(chunks, fn chunk ->
      String.contains?(String.downcase(chunk.text), term)
    end)
  end

  # Stem a word for matching (remove common suffixes)
  defp stem_word(word) do
    String.replace(word, ~r/(s|es|ed|ing|'s|'s)$/, "")
  end

  # Get max IDF for normalization
  defp idf_max(idf_map) do
    idf_map
    |> Map.values()
    |> Enum.map(fn data -> data[:idf] || 0 end)
    |> Enum.max(fn -> 1 end)
  end
end
