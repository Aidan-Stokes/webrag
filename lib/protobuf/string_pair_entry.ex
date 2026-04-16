defmodule AONCrawler.Protobuf.StringPairEntry do
  @moduledoc """
  Key-value pair for metadata maps.
  """
  use Protobuf, map: true, syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end
