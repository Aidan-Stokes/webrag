defmodule Mix.Tasks.Compact do
  @moduledoc """
  Alias for mix transform - exports Protocol Buffer files to JSON.

  ## Usage

      mix compact

  See `mix help transform` for options.
  """
  use Mix.Task

  @shortdoc "Alias for mix transform"

  @impl true
  def run(args) do
    Mix.Tasks.Transform.run(args)
  end
end
