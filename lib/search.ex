defmodule AONCrawler.Search do
  @moduledoc """
  Local vector search using cosine similarity.

  Provides semantic search over embedded chunks.
  """

  @doc """
  Searches for relevant chunks given a query.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 5)
    min_score = Keyword.get(opts, :min_score, 0.3)

    embeddings = AONCrawler.Storage.load_embeddings()
    chunks = AONCrawler.Storage.load_chunks()

    if length(embeddings) == 0 do
      IO.puts("No embeddings found. Run: mix embed")
      {:ok, []}
    else
      chunk_map = Enum.into(chunks, %{}, fn c -> {c.id, c} end)

      case AONCrawler.LLM.Ollama.embed(query) do
        {:ok, query_vector} ->
          results =
            embeddings
            |> Enum.map(fn emb ->
              chunk = Map.get(chunk_map, emb.chunk_id, %{})
              text = Map.get(chunk, :text, "") || ""

              score = cosine_similarity(query_vector, emb.vector)
              Map.put(emb, :score, score) |> Map.put(:text, text)
            end)
            |> Enum.filter(fn emb -> emb.score >= min_score end)
            |> Enum.sort_by(fn emb -> emb.score end, :desc)
            |> Enum.take(top_k)

          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end
    end
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
end
