defmodule WebRAG.Protobuf.Document do
  @moduledoc """
  Protocol Buffer message for documents.
  """
  use Protobuf, syntax: :proto3

  field(:id, 1, type: :string)
  field(:url, 2, type: :string)
  field(:text, 3, type: :string)
  field(:content_type, 4, type: :string)
  field(:metadata, 5, type: WebRAG.Protobuf.StringPairEntry, map: true)
  field(:timestamp, 6, type: :int64)
end
