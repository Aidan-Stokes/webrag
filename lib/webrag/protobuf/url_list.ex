defmodule WebRAG.Protobuf.UrlList do
  @moduledoc """
  Protocol Buffer message for URL lists.
  """
  use Protobuf, syntax: :proto3

  field(:urls, 1, type: :string, repeated: true)
end
