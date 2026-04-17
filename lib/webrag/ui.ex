defmodule WebRAG.UI do
  @moduledoc """
  Terminal UI helpers with colored output.
  """

  defmodule ANSI do
    def reset, do: "\e[0m"
    def bold, do: "\e[1m"
    def red, do: "\e[31m"
    def green, do: "\e[32m"
    def yellow, do: "\e[33m"
    def blue, do: "\e[34m"
    def cyan, do: "\e[36m"
    def gray, do: "\e[90m"

    def score_color(score) when score >= 0.7, do: green()
    def score_color(score) when score >= 0.5, do: yellow()
    def score_color(_), do: red()
  end

  @doc """
  Writes header with config info.
  """
  def write_header(title, config \\ []) do
    IO.puts("")

    IO.puts(
      "#{ANSI.bold()}#{ANSI.blue()}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━#{ANSI.reset()}"
    )

    IO.puts("#{ANSI.bold()}  #{title}#{ANSI.reset()}")

    for {k, v} <- config do
      IO.puts("  #{ANSI.cyan()}#{k}#{ANSI.reset()}: #{v}")
    end

    IO.puts(
      "#{ANSI.bold()}#{ANSI.blue()}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━#{ANSI.reset()}"
    )
  end

  @doc """
  Writes a separator line.
  """
  def separator do
    IO.puts("")
    IO.puts("  #{ANSI.gray()}#{String.duplicate("─", 60)}#{ANSI.reset()}")
    IO.puts("")
  end

  @doc """
  Writes a section header.
  """
  def section(title) do
    IO.puts("")
    IO.puts("#{ANSI.bold()}#{ANSI.yellow()}== #{title} ==#{ANSI.reset()}")
  end

  @doc """
  Formats a search result with color coding.
  """
  def format_result(result, index, opts \\ []) do
    truncate = Keyword.get(opts, :truncate, true)
    show_breakdown = Keyword.get(opts, :show_breakdown, true)

    score = result.score
    embed_score = result.embed_score
    keyword_score = result.keyword_score

    text =
      if truncate do
        truncate_text(result.text, 500)
      else
        result.text
      end

    color = ANSI.score_color(score)

    output = """
    #{ANSI.bold()}#{color}[#{index}] Score: #{Float.round(score, 3)}#{ANSI.reset()}
    #{ANSI.gray()}#{if show_breakdown, do: "  (embed: #{Float.round(embed_score, 2)} | keyword: #{Float.round(keyword_score, 2)})", else: ""}#{ANSI.reset()}

    #{text}
    """

    IO.puts(output)
  end

  @doc """
  Formats a passage block for context.
  """
  def format_passage(result, index) do
    """
    #{ANSI.cyan()}[Passage #{index} (score: #{Float.round(result.score, 3)})]#{ANSI.reset()}
    #{truncate_text(result.text, 800)}
    """
  end

  @doc """
  Truncates text to max length with ellipsis.
  """
  def truncate_text(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end

  @doc """
  Shows a progress indicator.
  """
  def progress(current, total, label \\ "Progress") do
    percent = if total > 0, do: current / total * 100, else: 0
    bar_width = 40
    filled = round(percent / 100 * bar_width)
    empty = bar_width - filled

    bar = String.duplicate("█", filled) <> String.duplicate("░", empty)

    IO.puts(
      "#{ANSI.cyan()}#{label}: #{ANSI.reset()}[#{ANSI.green()}#{bar}#{ANSI.reset()}] #{Float.round(percent, 1)}% (#{current}/#{total})"
    )
  end

  @doc """
  Shows a success message.
  """
  def success(message) do
    IO.puts("#{ANSI.green()}✓#{ANSI.reset()} #{message}")
  end

  @doc """
  Shows an error message.
  """
  def error(message) do
    IO.puts(:stderr, "#{ANSI.red()}✗#{ANSI.reset()} #{message}")
  end

  @doc """
  Shows a warning message.
  """
  def warn(message) do
    IO.puts("#{ANSI.yellow()}⚠#{ANSI.reset()} #{message}")
  end
end
