defmodule AONCrawler.Protobuf.Chunk do
  @moduledoc """
  Protocol Buffer message for text chunks.
  """
  use Protobuf, syntax: :proto3

  field(:id, 1, type: :string)
  field(:document_id, 2, type: :string)
  field(:text, 3, type: :string)
  field(:index, 4, type: :int32)
  field(:total, 5, type: :int32)
  field(:metadata, 6, type: AONCrawler.Protobuf.StringPairEntry, map: true)
end
