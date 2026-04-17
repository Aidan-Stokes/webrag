defmodule WebRAG.Search do
  @moduledoc """
  Local vector search using cosine similarity with hybrid keyword boosting.

  Provides semantic search over embedded chunks with support for
  result diversity (avoiding multiple results from the same document).
  """

  @default_top_k 5
  @default_min_score 0.25
  @default_max_per_doc 5
  @keyword_weight 0.3

  @doc """
  Searches for relevant chunks given a query.

  ## Options

    - `:top_k` - Number of results to return (default: 5)
    - `:min_score` - Minimum similarity threshold (default: 0.25)
    - `:max_per_doc` - Maximum results per document (default: 2)

  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    min_score = Keyword.get(opts, :min_score, @default_min_score)
    max_per_doc = Keyword.get(opts, :max_per_doc, @default_max_per_doc)

    embeddings = WebRAG.Storage.load_embeddings()
    chunks = WebRAG.Storage.load_chunks()

    if length(embeddings) == 0 do
      IO.puts("No embeddings found. Run: mix embed")
      {:ok, []}
    else
      chunk_map = Enum.into(chunks, %{}, fn c -> {c.id, c} end)

      case WebRAG.LLM.Ollama.embed(query) do
        {:ok, query_vector} ->
          query_keywords = extract_keywords(query)

          all_results =
            Enum.map(embeddings, fn emb ->
              chunk = Map.get(chunk_map, emb.chunk_id, %{})
              text = Map.get(chunk, :text, "") || ""
              document_id = Map.get(chunk, :document_id, "")

              embed_score = cosine_similarity(query_vector, emb.vector)
              keyword_score = calculate_keyword_score(text, query_keywords)
              score = hybrid_score(embed_score, keyword_score)

              %{
                score: score,
                embed_score: embed_score,
                keyword_score: keyword_score,
                text: text,
                chunk_id: emb.chunk_id,
                document_id: document_id,
                metadata: Map.get(chunk, :metadata, %{})
              }
            end)
            |> Enum.filter(fn r -> r.score >= min_score end)
            |> Enum.sort_by(fn r -> r.score end, :desc)

          results = diverse_results(all_results, top_k: top_k, max_per_doc: max_per_doc)

          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns diverse results, limiting results per document for better coverage.
  """
  @spec diverse_results([map()], keyword()) :: [map()]
  def diverse_results(results, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    max_per_doc = Keyword.get(opts, :max_per_doc, @default_max_per_doc)

    results
    |> Enum.reduce({[], %{}}, fn result, {selected, doc_counts} ->
      doc_id = result.document_id || "none"
      current_count = Map.get(doc_counts, doc_id, 0)

      cond do
        current_count < max_per_doc and length(selected) < top_k ->
          {[result | selected], Map.put(doc_counts, doc_id, current_count + 1)}

        length(selected) >= top_k ->
          {selected, doc_counts}

        true ->
          {selected, doc_counts}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp cosine_similarity(vec1, vec2) do
    dot = dot_product(vec1, vec2)
    mag1 = magnitude(vec1)
    mag2 = magnitude(vec2)

    if mag1 == 0 or mag2 == 0 do
      0.0
    else
      dot / (mag1 * mag2)
    end
  end

  defp dot_product(vec1, vec2) do
    Enum.zip(vec1, vec2)
    |> Enum.reduce(0, fn {a, b}, acc -> a * b + acc end)
  end

  defp magnitude(vec) do
    :math.sqrt(Enum.reduce(vec, 0, fn x, acc -> x * x + acc end))
  end

  defp extract_keywords(query) do
    query
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.filter(fn w -> String.length(w) > 2 end)
    |> Enum.map(&stem_word/1)
    |> Enum.uniq()
  end

  defp stem_word(word) do
    String.replace(word, ~r/(s|es|ed|ing)$/, "")
  end

  defp calculate_keyword_score(text, keywords) do
    if length(keywords) == 0 do
      0.0
    else
      text_lower = String.downcase(text)
      matches = Enum.count(keywords, fn kw -> String.contains?(text_lower, kw) end)
      matches / length(keywords)
    end
  end

  defp hybrid_score(embed_score, keyword_score) do
    (1 - @keyword_weight) * embed_score + @keyword_weight * keyword_score
  end
end
