defmodule WebRAG.Types do
  @moduledoc """
  Helper functions and constants for the WebRAG system.

  Actual type definitions are in WebRAG.Types.* modules.
  """

  @default_chunk_size 512
  @default_chunk_overlap 50
  @default_model "gpt-4-turbo-preview"

  @doc """
  Default system prompt for the Pathfinder 2e assistant.
  """
  @spec default_system_prompt() :: String.t()
  def default_system_prompt do
    """
    You are an expert assistant specializing in Pathfinder 2nd Edition rules.

    Your knowledge comes ONLY from the provided context. If the context does not
    contain enough information to answer a question, you MUST say "I don't have
    enough information from the provided rules to answer this question."

    Never make up rules, invent actions, or assume mechanics not present in the context.
    When in doubt, ask the user to rephrase their question or clarify which part of the rules they're asking about.

    When answering:
    1. First, show your step-by-step reasoning in a "REASONING:" section
    2. Then provide your final answer in a "FINAL ANSWER:" section
    3. Quote relevant rules text when applicable
    4. Reference the source
    5. Explain the practical application of the rule
    6. Note any prerequisites or conditions that apply

    Format your response as:
    REASONING:
    - Step 1: what you're considering
    - Step 2: what rule applies
    - Step 3: how you apply it

    FINAL ANSWER:
    Your clear, formatted answer here...
    """
  end

  @doc """
  Default LLM model to use.
  """
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc """
  Splits content into overlapping chunks.
  """
  @spec chunk_text(String.t(), String.t(), pos_integer(), non_neg_integer()) :: [map()]
  def chunk_text(
        text,
        content_id,
        chunk_size \\ @default_chunk_size,
        overlap \\ @default_chunk_overlap
      ) do
    words = String.split(text, ~r/\s+/, trim: true)

    do_chunk_words(words, content_id, chunk_size, overlap, 0, [])
    |> Enum.with_index()
    |> Enum.map(fn {chunk_words, index} ->
      total = length(chunk_words)

      %{
        id: "#{content_id}_chunk_#{index}",
        content_id: content_id,
        text: Enum.join(chunk_words, " "),
        chunk_index: index,
        total_chunks: total,
        metadata: %{word_count: total}
      }
    end)
  end

  defp do_chunk_words([], _content_id, _chunk_size, _overlap, _index, acc) do
    Enum.reverse(acc)
  end

  defp do_chunk_words(words, content_id, chunk_size, overlap, index, acc) do
    chunk_words = Enum.take(words, chunk_size)
    remaining = Enum.drop(words, chunk_size - overlap)
    new_acc = [chunk_words | acc]

    if length(chunk_words) < chunk_size or length(remaining) == 0 do
      do_chunk_words([], content_id, chunk_size, overlap, index + 1, new_acc)
    else
      do_chunk_words(remaining, content_id, chunk_size, overlap, index + 1, new_acc)
    end
  end
end
