defmodule WebRAG.Protobuf.DiscoveredUrl do
  @moduledoc """
  Protocol Buffer message for a single discovered URL.
  """
  use Protobuf, syntax: :proto3

  field(:url, 1, type: :string)
  field(:discovered_at, 2, type: :int64)
end
