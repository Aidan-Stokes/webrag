defmodule WebRAG.Search do
  @moduledoc """
  Hybrid search combining vector similarity and keyword matching.
  """
  @default_top_k 5
  @default_min_score 0.1
  @default_max_per_doc 5
  @keyword_weight 0.3

  @stopwords ~w(the a an is are was were be been being have has had do does did will would could should may might must shall can this that these those what when where why how who which for from of and or not but with into onto about above below under over after before between during through because)

  defmodule QueryCache do
    @table :webrag_query_cache

    def init do
      if :ets.info(@table) == :undefined do
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
      end
    end

    def get(query) do
      case :ets.lookup(@table, query) do
        [{^query, embedding, timestamp}] ->
          now = System.system_time(:millisecond)

          if now - timestamp < 60_000 do
            {:hit, embedding}
          else
            :ets.delete(@table, query)
            :miss
          end

        [] ->
          :miss
      end
    end

    def put(query, embedding) do
      :ets.insert(@table, {query, embedding, System.system_time(:millisecond)})
    end
  end

  def search(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    min_score = Keyword.get(opts, :min_score, @default_min_score)
    max_per_doc = Keyword.get(opts, :max_per_doc, @default_max_per_doc)
    source_filter = Keyword.get(opts, :source, nil)

    if WebRAG.Indexer.VectorStore.loaded?() == false do
      WebRAG.Indexer.VectorStore.load_embeddings()
    end

    qv = get_or_create_embedding(query)

    case qv do
      nil ->
        {:error, :embedding_failed}

      _ ->
        kw = extract_keywords(query)
        idf = load_idf_terms()

        case WebRAG.Indexer.VectorStore.search(qv,
               top_k: top_k * 5,
               min_score: min_score * 0.3,
               source: source_filter
             ) do
          [] ->
            {:ok, []}

          vector_results ->
            chunks = WebRAG.Storage.load_chunks()
            chunk_map = Enum.reduce(chunks, %{}, fn c, acc -> Map.put(acc, c.id, c) end)

            results =
              Enum.map(vector_results, fn vr ->
                chunk = Map.get(chunk_map, vr.chunk_id)

                unless chunk do
                  nil
                else
                  txt = chunk.text
                  doc_id = chunk.document_id
                  ts = tfidf(txt, kw, idf)

                  %{
                    score: (1 - @keyword_weight) * vr.score + @keyword_weight * ts,
                    embed_score: vr.score,
                    keyword_score: ts,
                    text: txt,
                    chunk_id: vr.chunk_id,
                    document_id: doc_id,
                    metadata: chunk.metadata || %{}
                  }
                end
              end)
              |> Enum.reject(&is_nil/1)

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
    if singular && singular != w, do: result = result ++ [singular], else: result
    if stemmed != w && stemmed != singular, do: result = result ++ [stemmed], else: result

    Enum.uniq(result)
  end

  defp fuzzy_match?(text, word, max_dist) do
    tws = String.split(String.downcase(text), ~r/\s+/) |> Enum.map(&String.trim/1)
    target = String.downcase(word)

    Enum.any?(tws, fn tw ->
      dist = levenshtein(target, tw)
      dist <= max_dist
    end)
  end

  defp levenshtein(s1, s2) do
    len1 = String.length(s1)
    len2 = String.length(s2)
    if abs(len1 - len2) > 3, do: 99, else: do_levenshtein(s1, s2, len1, len2)
  end

  defp do_levenshtein(_s1, _s2, 0, len2), do: len2
  defp do_levenshtein(_s1, _s2, len1, 0), do: len1

  defp do_levenshtein(s1, s2, len1, len2) do
    g1 = String.graphemes(s1)
    g2 = String.graphemes(s2)

    prev = Enum.to_list(0..len2)

    result =
      Enum.reduce_while(g1, prev, fn char, prev_row ->
        curr = [1]

        curr =
          Enum.reduce(g2, {curr, 1}, fn c2, {row, j} ->
            cost = if char == c2, do: 0, else: 1

            val =
              min(
                Enum.at(prev_row, j) + 1,
                Enum.at(row, j - 1) + 1,
                Enum.at(prev_row, j - 1) + cost
              )

            {List.insert_at(row, j, val), j + 1}
          end)
          |> elem(0)

        if Enum.max(curr) > 10 do
          {:halt, [99]}
        else
          {:cont, curr}
        end
      end)

    Enum.at(result, len2)
  end

  defp min(a, b, c), do: Enum.min([a, b, c])

  defp load_idf_terms, do: WebRAG.Storage.load_idf_terms()

  defp get_or_create_embedding(query) do
    QueryCache.init()

    case QueryCache.get(query) do
      {:hit, embedding} ->
        embedding

      :miss ->
        case WebRAG.LLM.Ollama.embed(query) do
          {:ok, embedding} ->
            QueryCache.put(query, embedding)
            embedding

          {:error, _} ->
            nil
        end
    end
  end
end
