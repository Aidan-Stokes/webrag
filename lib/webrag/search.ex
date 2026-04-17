defmodule WebRAG.Search do
  @moduledoc """
  Hybrid search combining vector similarity and keyword matching.
  """
  @default_top_k 5
  @default_min_score 0.1
  @default_max_per_doc 5
  @keyword_weight 0.3

  @stopwords ~w(the a an is are was were be been being have has had do does did will would could should may might must shall can this that these those what when where why how who which for from of and or not but with into onto about above below under over after before between during through because)

  def search(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    min_score = Keyword.get(opts, :min_score, @default_min_score)
    max_per_doc = Keyword.get(opts, :max_per_doc, @default_max_per_doc)

    chunks = WebRAG.Storage.load_chunks()
    chunk_map = Enum.reduce(chunks, %{}, fn c, acc -> Map.put(acc, c.id, c) end)

    if WebRAG.Indexer.VectorStore.loaded?() == false do
      WebRAG.Indexer.VectorStore.load_embeddings()
    end

    case WebRAG.LLM.Ollama.embed(query) do
      {:ok, qv} ->
        kw = extract_keywords(query)
        idf = load_idf_terms()

        case WebRAG.Indexer.VectorStore.search(qv, top_k: top_k * 3, min_score: min_score * 0.5) do
          [] ->
            {:ok, []}

          vector_results ->
            results =
              Enum.map(vector_results, fn vr ->
                chunk = Map.get(chunk_map, vr.chunk_id)
                txt = if chunk, do: chunk.text, else: ""
                doc_id = if chunk, do: chunk.document_id, else: ""
                ts = tfidf(txt, kw, idf)

                %{
                  score: (1 - @keyword_weight) * vr.score + @keyword_weight * ts,
                  embed_score: vr.score,
                  keyword_score: ts,
                  text: txt,
                  chunk_id: vr.chunk_id,
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

      {:error, reason} ->
        {:error, reason}
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
    dot = Enum.zip(v1, v2) |> Enum.reduce(0, fn {a, b}, c -> a * b + c end)
    mag1 = :math.sqrt(Enum.reduce(v1, 0, fn x, c -> x * x + c end))
    mag2 = :math.sqrt(Enum.reduce(v2, 0, fn x, c -> x * x + c end))
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
        exact = Enum.any?(vars, fn v -> String.contains?(tl, v) end)

        if exact do
          a + (Map.get(idf, k, %{})[:idf] || 0)
        else
          if String.length(k) > 4 and fuzzy_match?(tl, k, 2) do
            a + 1.0
          else
            a
          end
        end
      end)

    max_kw = length(kw) * 5.0
    min(base / max_kw * 1.5, 1.0)
  end

  defp stem_variants(w) do
    # Load mappings from file or use defaults
    mappings = %{
      "dwarfs" => "dwarf",
      "elfs" => "elf",
      "orcs" => "orc",
      "humans" => "human",
      "halflings" => "halfling",
      "gnomes" => "gnome",
      "elves" => "elf",
      "dwarves" => "dwarf"
    }

    # Try file-based mappings first
    mappings =
      if File.exists?("data/word_mappings.txt") do
        file_maps =
          "data/word_mappings.txt"
          |> File.stream!()
          |> Stream.reject(fn l -> String.trim(l) == "" or String.starts_with?(l, "#") end)
          |> Enum.map(fn l ->
            case String.split(String.trim(l), "=>", parts: 2) do
              [p, s] -> {String.trim(p), String.trim(s)}
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.into(%{})

        Map.merge(mappings, file_maps)
      else
        mappings
      end

    singular = Map.get(mappings, w)
    stemmed = String.replace(w, ~r/(s|es|ed|ing)$/, "")

    result = [w]
    if singular && singular != w, do: result ++ [singular], else: result
    if stemmed != w && stemmed != singular, do: result ++ [stemmed], else: result

    Enum.uniq(result)
  end

  # Simple fuzzy: check if word is prefix-similar  
  defp fuzzy_match?(text, word, _max_dist) do
    tws = String.split(String.downcase(text), ~r/\s+/) |> Enum.map(&String.trim/1)
    target = String.downcase(word)

    # Check if target is close to any text word by prefix
    Enum.any?(tws, fn tw ->
      (String.starts_with?(tw, target) and String.length(target) > 3) or
        (String.starts_with?(target, tw) and String.length(tw) > 3)
    end)
  end

  defp levenshtein(s1, s2) do
    len1 = String.length(s1)
    len2 = String.length(s2)
    if abs(len1 - len2) > 2, do: 999, else: do_calc(s1, s2)
  end

  defp do_calc(s1, s2) do
    len1 = String.length(s1)
    len2 = String.length(s2)

    d =
      for i <- 0..len1,
          j <- 0..len2,
          into: %{},
          do: {i * 1000 + j, if(i == 0, do: j, else: if(j == 0, do: i, else: 999))}

    String.graphemes(s1)
    |> Enum.with_index(1)
    |> Enum.each(fn {c1, i} ->
      String.graphemes(s2)
      |> Enum.with_index(1)
      |> Enum.each(fn {c2, j} ->
        cost = if c1 == c2, do: 0, else: 1

        v =
          Enum.min([
            d[(i - 1) * 1000 + j] + 1,
            d[i * 1000 + (j - 1)] + 1,
            d[(i - 1) * 1000 + (j - 1)] + cost
          ])

        d = Map.put(d, i * 1000 + j, v)
      end)
    end)

    d[len1 * 1000 + len2]
  end

  defp load_idf_terms, do: WebRAG.Storage.load_idf_terms()
  defp hybrid(e, t), do: (1 - @keyword_weight) * e + @keyword_weight * t
end
