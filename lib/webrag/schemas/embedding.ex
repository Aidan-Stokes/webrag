
defmodule WebRAG.Embedding do
  @moduledoc """
  Schema for storing vector embeddings with metadata.

  Each embedding corresponds to a chunk of document content and
  stores the vector representation along with model information
  and token counts for billing/tracking purposes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "embeddings" do
    field(:chunk_id, :binary_id)
    field(:content_id, :binary_id)
    field(:vector, {:array, :float})
    field(:model, :string)
    field(:token_count, :integer)
    field(:generated_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          chunk_id: String.t(),
          content_id: String.t(),
          vector: [float()],
          model: String.t(),
          token_count: non_neg_integer(),
          generated_at: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Creates a changeset for inserting a new embedding.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(embedding \\ %__MODULE__{}, attrs) do
    embedding
    |> cast(attrs, [:chunk_id, :content_id, :vector, :model, :token_count, :generated_at])
    |> validate_required([:chunk_id, :content_id, :vector, :model])
  end

  @doc """
  Creates a changeset for updating an existing embedding.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(embedding, attrs) do
    embedding
    |> cast(attrs, [:vector, :model, :token_count, :generated_at])
    |> validate_required([:chunk_id, :content_id, :vector, :model])
  end
end

