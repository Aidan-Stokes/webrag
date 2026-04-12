defmodule AONCrawler.Chunk do
  @moduledoc """
  Schema for storing chunked document content for embedding.

  Large documents are split into smaller chunks that are suitable for
  vector embedding and retrieval. Each chunk maintains a reference
  to its parent document for context reconstruction.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "chunks" do
    field :content_id, :binary_id
    field :text, :string
    field :chunk_index, :integer
    field :total_chunks, :integer
    field :metadata, :map

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          content_id: String.t(),
          text: String.t(),
          chunk_index: non_neg_integer(),
          total_chunks: pos_integer(),
          metadata: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Creates a changeset for inserting a new chunk.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(chunk \\ %__MODULE__{}, attrs) do
    chunk
    |> cast(attrs, [:content_id, :text, :chunk_index, :total_chunks, :metadata])
    |> validate_required([:content_id, :text, :chunk_index, :total_chunks])
  end

  @doc """
  Creates a changeset for updating an existing chunk.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:text, :metadata])
    |> validate_required([:content_id, :text, :chunk_index, :total_chunks])
  end
end
