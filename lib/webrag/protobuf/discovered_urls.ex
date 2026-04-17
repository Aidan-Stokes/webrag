defmodule WebRAG.Protobuf.DiscoveredUrls do
  @moduledoc """
  Protocol Buffer message for a list of discovered URLs.
  """
  use Protobuf, syntax: :proto3

  field(:urls, 1, type: WebRAG.Protobuf.DiscoveredUrl, repeated: true)
end
