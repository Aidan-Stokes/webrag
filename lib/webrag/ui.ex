defmodule WebRAG.UI do
  @moduledoc """
  Terminal UI helpers.
  """

  @doc """
  Writes header with config info.
  """
  def write_header(title, config \\ []) do
    IO.puts("")
    IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    IO.puts("  #{title}")

    for {k, v} <- config do
      IO.puts("  #{k}: #{v}")
    end

    IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  end

  @doc """
  Writes a separator line.
  """
  def separator do
    IO.puts("")
    IO.puts("  " <> String.duplicate("─", 60))
    IO.puts("")
  end
end
