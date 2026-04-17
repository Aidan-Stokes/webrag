defmodule WebRAG.Protobuf.Embedding do
  @moduledoc """
  Protocol Buffer message for vector embeddings.
  """
  use Protobuf, syntax: :proto3

  field(:id, 1, type: :string)
  field(:chunk_id, 2, type: :string)
  field(:vector, 3, type: :float, repeated: true)
  field(:model, 4, type: :string)
  field(:token_count, 5, type: :int32)
end
