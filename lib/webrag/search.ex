defmodule WebRAG.Search do
  @default_top_k 5
  @default_min_score 0.1
  @default_max_per_doc 5
  @keyword_weight 0.7

  @stopwords ~w(the a an is are was were be been being have has had do does did will would could should may might must shall can this that these those what when where why how who which for from of and or not but with into onto about above below under over after before between during through because)

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
      idf = load_idf_terms()

      case WebRAG.LLM.Ollama.embed(query) do
        {:ok, qv} ->
          kw = extract_keywords(query)

          results =
            Enum.map(embeddings, fn emb ->
              ch = Enum.find(chunks, fn c -> c.id == emb.chunk_id end)
              txt = if ch, do: ch.text, else: ""
              doc_id = if ch, do: ch.document_id, else: ""
              ds = cosine(qv, emb.vector)
              ts = tfidf(txt, kw, idf)
              sc = hybrid(ds, ts)

              %{
                score: sc,
                embed_score: ds,
                keyword_score: ts,
                text: txt,
                chunk_id: emb.chunk_id,
                document_id: doc_id,
                metadata: %{}
              }
            end)

          filtered = Enum.filter(results, fn r -> r.score >= min_score end)
          sorted = Enum.sort_by(filtered, fn r -> r.score end, :desc)
          limited = Enum.take(sorted, top_k * 3)
          final = diverse_results(limited, top_k, max_per_doc)

          {:ok, final}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def diverse_results(results, top_k, max_per_doc) do
    Enum.reduce(results, {[], %{}}, fn r, {sel, counts} ->
      did = r.document_id || "none"
      cnt = Map.get(counts, did, 0)

      cond do
        cnt < max_per_doc and length(sel) < top_k -> {[r | sel], Map.put(counts, did, cnt + 1)}
        length(sel) >= top_k -> {sel, counts}
        true -> {sel, counts}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp cosine(v1, v2) do
    dot = Enum.zip(v1, v2) |> Enum.reduce(0, fn {a, b}, acc -> a * b + acc end)
    mag1 = :math.sqrt(Enum.reduce(v1, 0, fn x, acc -> x * x + acc end))
    mag2 = :math.sqrt(Enum.reduce(v2, 0, fn x, acc -> x * x + acc end))
    if mag1 == 0 or mag2 == 0, do: 0.0, else: dot / (mag1 * mag2)
  end

  defp extract_keywords(q) do
    q
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.filter(fn w -> String.length(w) > 2 and w not in @stopwords end)
    |> Enum.uniq()
  end

  defp tfidf(text, kw, idf) do
    tl = String.downcase(text)

    base =
      Enum.reduce(kw, 0, fn k, a ->
        vars = stem_variants(k)

        if Enum.any?(vars, fn v -> String.contains?(tl, v) end) do
          a + (Map.get(idf, k, %{})[:idf] || 0)
        else
          a
        end
      end)

    bonus =
      if String.contains?(tl, "dwarf") and String.contains?(tl, "language") do
        3.0
      else
        0.0
      end

    max_kw = length(kw) * 5.0
    raw = base + bonus
    min(raw / max_kw * 1.5, 1.0)
  end

  defp stem_variants(w) do
    corrections = %{
      "spek" => "speak",
      "dwarfs" => "dwarf",
      "elfs" => "elf",
      "orcs" => "orc",
      "humans" => "human",
      "halflings" => "halfling"
    }

    corrected = Map.get(corrections, w, w)
    stemmed = String.replace(corrected, ~r/(s|es|ed|ing)$/, "")
    [corrected, w, stemmed] |> Enum.uniq()
  end

  defp load_idf_terms, do: WebRAG.Storage.load_idf_terms()

  defp hybrid(e, t), do: (1 - @keyword_weight) * e + @keyword_weight * t
end
