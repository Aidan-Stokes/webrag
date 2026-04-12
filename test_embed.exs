#!/usr/bin/env elixir
# Quick test script

# Manually define embedding function using curl
defmodule TestOllama do
  def embed(text) do
    model = "mxbai-embed-large"
    url = "http://localhost:11434/api/embeddings"

    body = %{model: model, prompt: text} |> Jason.encode!()

    {[output, 0], _} =
      System.cmd("curl", [
        "-s",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-d",
        body,
        url
      ])

    case Jason.decode(output) do
      {:ok, %{"embedding" => emb}} ->
        IO.puts("Success! Embedding length: #{length(emb)}")
        {:ok, emb}

      {:ok, other} ->
        IO.inspect(other)
        {:error, :unexpected_response}
    end
  end
end

IO.puts("Testing embedding...")
TestOllama.embed("Shove")
