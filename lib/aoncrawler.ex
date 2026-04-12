defmodule Aoncrawler do
  @start_urls [
    "https://2e.aonprd.com/"
  ]

  @max_pages 200_000
  @concurrency 10
  @chunk_size 500

  # ---------- ENTRY ----------
  def run do
    {:ok, visited} = Agent.start_link(fn -> MapSet.new() end)
    {:ok, hashes} = Agent.start_link(fn -> MapSet.new() end)

    File.write!("aon_full.txt", "")
    File.write!("aon_docs.jsonl", "")

    loop(@start_urls, visited, hashes, 0)
  end

  # ---------- MAIN LOOP ----------
  defp loop([], _visited, _hashes, _count) do
    IO.puts("Queue empty. Done.")
  end

  defp loop(_queue, _visited, _hashes, count) when count >= @max_pages do
    IO.puts("Reached max pages. Done.")
  end

  defp loop(queue, visited, hashes, count) do
    {batch, rest} = Enum.split(queue, @concurrency)

    results =
      batch
      |> Task.async_stream(
        fn url -> process_url(url, visited, hashes) end,
        max_concurrency: @concurrency,
        timeout: :infinity
      )
      |> Enum.to_list()

    {new_urls, new_count} =
      Enum.reduce(results, {rest, count}, fn
        {:ok, {:ok, links}}, {acc_urls, acc_count} ->
          {Enum.uniq(acc_urls ++ links), acc_count + 1}

        _, acc ->
          acc
      end)

    loop(new_urls, visited, hashes, new_count)
  end

  # ---------- PROCESS SINGLE URL ----------
  defp process_url(url, visited, hashes) do
    url = normalize_url(url)

    if visited?(visited, url) do
      {:skip, []}
    else
      mark_visited(visited, url)

      case fetch(url) do
        {:ok, html} ->
          {title, text} = extract_content(html)

          cond do
            text == "" ->
              {:skip, []}

            String.length(text) < 200 ->
              {:skip, []}

            duplicate?(hashes, text) ->
              {:skip, []}

            true ->
              save_output(url, title, text)

              links = extract_links(html, url)
              {:ok, links}
          end

        {:skip, _} ->
          {:skip, []}

        _ ->
          {:error, []}
      end
    end
  end

  # ---------- HTTP ----------
  defp fetch(url) do
    IO.puts("Fetching: #{url}")

    case HTTPoison.get(url, [], follow_redirect: true, recv_timeout: 15_000) do
      {:ok, %{status_code: 200, headers: headers, body: body}} ->
        content_type =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
          |> case do
            {_, v} -> v
            _ -> ""
          end

        if String.contains?(content_type, "text/html") do
          {:ok, body}
        else
          {:skip, :non_html}
        end

      _ ->
        {:error, :failed}
    end
  end

  # ---------- EXTRACTION ----------
  defp extract_content(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        main =
          doc
          |> Floki.find("#main, #ctl00_MainContent_DetailedOutput, .main")

        title =
          doc
          |> Floki.find("title")
          |> Floki.text()

        text =
          main
          |> Floki.filter_out("script")
          |> Floki.filter_out("style")
          |> Floki.text(sep: "\n")
          |> clean_text()

        {title, text}

      _ ->
        {"", ""}
    end
  end

  defp clean_text(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line ->
      line == "" or
        String.length(line) < 2 or
        String.match?(line, ~r/^(Home|Search|Toggle|Menu)$/i)
    end)
    |> Enum.join("\n")
  end

  # ---------- CHUNKING ----------
  defp chunk_text(text) do
    words = String.split(text)

    words
    |> Enum.chunk_every(@chunk_size)
    |> Enum.map(&Enum.join(&1, " "))
  end

  # ---------- LINKS ----------
  defp extract_links(html, base_url) do
    {:ok, doc} = Floki.parse_document(html)

    doc
    |> Floki.find("a[href]")
    |> Floki.attribute("href")
    |> Enum.map(&(URI.merge(base_url, &1) |> to_string()))
    |> Enum.map(&normalize_url/1)
    |> Enum.filter(&internal_link?/1)
    |> Enum.filter(&html_page?/1)
  end

  defp html_page?(url) do
    not String.match?(url, ~r/\.(png|jpg|jpeg|gif|svg|webp|pdf|zip)$/i)
  end

  defp internal_link?(url) do
    Enum.any?(@start_urls, fn root ->
      URI.parse(url).host == URI.parse(root).host
    end)
  end

  # ---------- STATE ----------
  defp visited?(agent, url) do
    Agent.get(agent, &MapSet.member?(&1, url))
  end

  defp mark_visited(agent, url) do
    Agent.update(agent, &MapSet.put(&1, url))
  end

  defp duplicate?(agent, text) do
    normalized =
      text
      |> String.downcase()
      |> String.replace(~r/\s+/, " ")

    hash = :crypto.hash(:md5, normalized) |> Base.encode16()

    Agent.get_and_update(agent, fn set ->
      if MapSet.member?(set, hash) do
        {true, set}
      else
        {false, MapSet.put(set, hash)}
      end
    end)
  end

  # ---------- OUTPUT ----------
  defp save_output(url, title, text) do
    formatted = """
    ===== PAGE =====
    URL: #{url}
    TITLE: #{title}

    #{text}
    """

    File.write!("aon_full.txt", formatted, [:append])

    Enum.each(chunk_text(text), fn chunk ->
      json =
        %{
          url: url,
          source: URI.parse(url).host,
          title: title,
          text: chunk
        }
        |> Jason.encode!()

      File.write!("aon_docs.jsonl", json <> "\n", [:append])
    end)
  end

  # ---------- UTILS ----------
  defp normalize_url(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}#{uri.path || ""}"
  end
end
